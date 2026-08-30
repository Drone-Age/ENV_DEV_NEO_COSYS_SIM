#!/usr/bin/env python3
"""Fail-closed live probe for correlated ArduPilot/Cosys wind acknowledgements."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import time

import rclpy
from rclpy.node import Node
from std_msgs.msg import String


COMMAND_TOPIC = "/sim/wind/command"
TRUTH_TOPIC = "/sim/wind/truth"
STAGES = (
    ("baseline", 5.0, 0.0),
    ("gust", 10.0, 90.0),
    ("recovery", 5.0, 180.0),
)


def direction_error_deg(expected: float, actual: float) -> float:
    return abs((actual - expected + 180.0) % 360.0 - 180.0)


def validate_ack(command: dict[str, object], ack: dict[str, object]) -> None:
    if ack.get("command_id") != command["command_id"]:
        raise ValueError("ack command_id does not match the staged command")
    for field in ("sitl_applied", "cosys_applied", "cosys_readback"):
        if ack.get(field) is not True:
            raise ValueError(f"ack does not prove {field}")
    if not math.isclose(
        float(ack["applied_speed_mps"]), float(command["speed_mps"]), abs_tol=0.05
    ):
        raise ValueError("applied wind speed differs from the command")
    if direction_error_deg(
        float(command["direction_deg"]), float(ack["applied_direction_deg"])
    ) > 0.5:
        raise ValueError("applied wind direction differs from the command")


class WindProbe(Node):
    def __init__(self) -> None:
        super().__init__("ivins_wind_ack_probe")
        self.publisher = self.create_publisher(String, COMMAND_TOPIC, 10)
        self.acks: dict[str, dict[str, object]] = {}
        self.create_subscription(String, TRUTH_TOPIC, self._receive, 10)

    def _receive(self, message: String) -> None:
        try:
            payload = json.loads(message.data)
            command_id = str(payload["command_id"])
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return
        self.acks[command_id] = payload


def write_result(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_probe(output: Path, timeout_per_stage: float) -> dict[str, object]:
    rclpy.init()
    node = WindProbe()
    results: list[dict[str, object]] = []
    started = time.monotonic()
    try:
        for checkpoint, (stage, speed_mps, direction_deg) in enumerate(STAGES):
            command = {
                "command_id": f"wind-probe-{time.time_ns()}-{stage}",
                "checkpoint": checkpoint,
                "altitude_m": 0.0,
                "stage": stage,
                "stage_kind": stage,
                "speed_mps": speed_mps,
                "direction_deg": direction_deg,
            }
            deadline = time.monotonic() + timeout_per_stage
            last_publish = 0.0
            while time.monotonic() < deadline:
                now = time.monotonic()
                if now - last_publish >= 0.5:
                    node.publisher.publish(String(data=json.dumps(command, sort_keys=True)))
                    last_publish = now
                rclpy.spin_once(node, timeout_sec=0.1)
                ack = node.acks.get(str(command["command_id"]))
                if ack is None:
                    continue
                validate_ack(command, ack)
                results.append({"command": command, "ack": ack, "latency_s": now - (deadline - timeout_per_stage)})
                break
            else:
                raise TimeoutError(f"no correlated acknowledgement for wind stage {stage}")
    finally:
        node.destroy_node()
        rclpy.shutdown()
    return {
        "schema": 1,
        "status": "PASS",
        "topics": {"command": COMMAND_TOPIC, "truth": TRUTH_TOPIC},
        "duration_s": time.monotonic() - started,
        "stages": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-per-stage", type=float, default=15.0)
    args = parser.parse_args()
    try:
        result = run_probe(args.output, args.timeout_per_stage)
    except Exception as exc:
        result = {"schema": 1, "status": "FAIL", "error": str(exc)}
        write_result(args.output, result)
        print(json.dumps(result, sort_keys=True))
        return 1
    write_result(args.output, result)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
