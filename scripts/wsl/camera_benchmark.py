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


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    index = min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def run_case(client, camera: str, vehicle: str, compress: bool, duration: float, warmup: int) -> dict:
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
        samples.append(
            {
                "timestamp_ns": int(response.time_stamp),
                "latency_ms": (after - before) * 1000.0,
                "bytes": payload,
                "width": int(response.width),
                "height": int(response.height),
            }
        )
    elapsed = time.perf_counter() - started
    timestamps = [sample["timestamp_ns"] for sample in samples]
    unique_timestamps = len(set(timestamps))
    latencies = [sample["latency_ms"] for sample in samples]
    sizes = [sample["bytes"] for sample in samples]
    dimensions = sorted({(sample["width"], sample["height"]) for sample in samples})
    return {
        "format": "png" if compress else "raw_rgb",
        "duration_s": elapsed,
        "frames": len(samples),
        "unique_timestamps": unique_timestamps,
        "duplicate_timestamps": len(samples) - unique_timestamps,
        "request_fps": len(samples) / elapsed,
        "unique_fps": unique_timestamps / elapsed,
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
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    client = airsim.VehicleClient(ip=args.host, port=args.port, timeout_value=180)
    client.confirmConnection()
    cases = [
        run_case(client, args.camera, args.vehicle, True, args.duration, args.warmup),
        run_case(client, args.camera, args.vehicle, False, args.duration, args.warmup),
    ]
    raw_case = next(case for case in cases if case["format"] == "raw_rgb")
    passed = raw_case["unique_fps"] >= args.min_raw_fps and raw_case["duplicate_timestamps"] == 0
    result = {
        "schema": 1,
        "verdict": "PASS" if passed else "FAIL",
        "acceptance": {
            "minimum_raw_unique_fps": args.min_raw_fps,
            "requires_zero_duplicate_timestamps": True,
        },
        "measured_at": datetime.now(timezone.utc).isoformat(),
        "host": args.host,
        "port": args.port,
        "camera": args.camera,
        "vehicle": args.vehicle,
        "cases": cases,
    }
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
