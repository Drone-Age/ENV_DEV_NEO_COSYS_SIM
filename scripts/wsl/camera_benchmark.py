#!/usr/bin/env python3
"""Measure end-to-end Cosys-AirSim RGB capture throughput over RPC."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import statistics
import time
from datetime import datetime, timezone

import cosysairsim as airsim
import numpy as np


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    index = min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def run_case(
    client,
    camera: str,
    vehicle: str,
    compress: bool,
    duration: float,
    warmup: int,
    validate_content: bool = False,
    sample_path: pathlib.Path | None = None,
) -> dict:
    request = [airsim.ImageRequest(camera, airsim.ImageType.Scene, False, compress)]
    for _ in range(warmup):
        response = client.simGetImages(request, vehicle_name=vehicle)[0]
        if response.width <= 0 or response.height <= 0:
            raise RuntimeError("camera returned an empty warm-up frame")

    samples = []
    started = time.perf_counter()
    deadline = started + duration
    while time.perf_counter() < deadline:
        before = time.perf_counter()
        response = client.simGetImages(request, vehicle_name=vehicle)[0]
        after = time.perf_counter()
        payload = len(response.image_data_uint8)
        if response.width <= 0 or response.height <= 0 or payload == 0:
            raise RuntimeError("camera returned an empty frame")
        if validate_content and "first_sample" not in locals():
            first_sample = bytes(response.image_data_uint8)
            first_dimensions = (response.width, response.height)
        if validate_content and after >= started + duration * 0.8 and "last_sample" not in locals():
            last_sample = bytes(response.image_data_uint8)
            last_dimensions = (response.width, response.height)
        samples.append(
            {
                "timestamp_ns": int(response.time_stamp),
                "received_s": after,
                "latency_ms": (after - before) * 1000.0,
                "bytes": payload,
                "width": int(response.width),
                "height": int(response.height),
            }
        )
    elapsed = time.perf_counter() - started
    timestamps = [sample["timestamp_ns"] for sample in samples]
    unique_timestamps = len(set(timestamps))
    unique_samples = []
    seen_timestamps = set()
    for sample in samples:
        if sample["timestamp_ns"] not in seen_timestamps:
            seen_timestamps.add(sample["timestamp_ns"])
            unique_samples.append(sample)
    delivery_span_s = (
        unique_samples[-1]["received_s"] - unique_samples[0]["received_s"]
        if len(unique_samples) > 1
        else 0.0
    )
    simulation_span_s = (
        (unique_samples[-1]["timestamp_ns"] - unique_samples[0]["timestamp_ns"]) / 1_000_000_000.0
        if len(unique_samples) > 1
        else 0.0
    )
    delivery_cadence_fps = (len(unique_samples) - 1) / delivery_span_s if delivery_span_s > 0 else 0.0
    simulation_cadence_fps = (len(unique_samples) - 1) / simulation_span_s if simulation_span_s > 0 else 0.0
    latencies = [sample["latency_ms"] for sample in samples]
    sizes = [sample["bytes"] for sample in samples]
    dimensions = sorted({(sample["width"], sample["height"]) for sample in samples})
    sample_artifacts = {}
    sample_stats = {}
    if validate_content and "first_sample" in locals() and "last_sample" in locals():
        for label, sample, sample_dimensions in (
            ("first", first_sample, first_dimensions),
            ("last", last_sample, last_dimensions),
        ):
            pixels = np.frombuffer(sample, dtype=np.uint8)
            sample_stats[label] = {
                "minimum": int(pixels.min()),
                "maximum": int(pixels.max()),
                "mean": float(pixels.mean()),
                "standard_deviation": float(pixels.std()),
            }
            if sample_path is not None:
                path = sample_path.with_name(f"{sample_path.stem}-{label}{sample_path.suffix}")
                path.write_bytes(f"P6\n{sample_dimensions[0]} {sample_dimensions[1]}\n255\n".encode("ascii") + sample)
                sample_artifacts[label] = str(path)

    return {
        "format": "png" if compress else "raw_rgb",
        "duration_s": elapsed,
        "frames": len(samples),
        "unique_timestamps": unique_timestamps,
        "duplicate_timestamps": len(samples) - unique_timestamps,
        "request_fps": len(samples) / elapsed,
        "unique_fps": unique_timestamps / elapsed,
        "delivery_cadence_fps": delivery_cadence_fps,
        "simulation_cadence_fps": simulation_cadence_fps,
        "latency_ms": {
            "mean": statistics.fmean(latencies),
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "max": max(latencies),
        },
        "payload_bytes": {
            "mean": statistics.fmean(sizes),
            "max": max(sizes),
        },
        "dimensions": [{"width": width, "height": height} for width, height in dimensions],
        "sample_artifacts": sample_artifacts,
        "sample_stats": sample_stats,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=41452)
    parser.add_argument("--camera", default="0")
    parser.add_argument("--vehicle", default="Copter")
    parser.add_argument("--duration", type=float, default=20.0)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--min-raw-fps", type=float, default=0.0)
    parser.add_argument("--save-samples", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    client = airsim.VehicleClient(ip=args.host, port=args.port, timeout_value=180)
    client.confirmConnection()
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    raw_sample = output.parent / "camera-sample-raw.ppm" if args.save_samples else None
    cases = [
        run_case(client, args.camera, args.vehicle, False, args.duration, args.warmup, True, raw_sample),
        # Compression is a diagnostic fallback, not part of the acceptance
        # path. Run it after raw capture so synchronous PNG work cannot warm or
        # contend with the fixed-rate real-time producer being qualified.
        run_case(client, args.camera, args.vehicle, True, args.duration, args.warmup),
    ]
    raw_case = next(case for case in cases if case["format"] == "raw_rgb")
    image_content_valid = all(
        stats["maximum"] - stats["minimum"] > 1
        and stats["standard_deviation"] > 1.0
        for stats in raw_case["sample_stats"].values()
    ) and len(raw_case["sample_stats"]) == 2
    passed = (
        raw_case["delivery_cadence_fps"] >= args.min_raw_fps
        and raw_case["duplicate_timestamps"] == 0
        and image_content_valid
    )
    result = {
        "schema": 1,
        "verdict": "PASS" if passed else "FAIL",
        "acceptance": {
            "minimum_raw_unique_fps": args.min_raw_fps,
            "metric": "delivery_cadence_fps",
            "requires_zero_duplicate_timestamps": True,
            "requires_nonuniform_samples": True,
            "image_content_valid": image_content_valid,
        },
        "measured_at": datetime.now(timezone.utc).isoformat(),
        "host": args.host,
        "port": args.port,
        "camera": args.camera,
        "vehicle": args.vehicle,
        "cases": cases,
    }
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
