#!/usr/bin/env python3
"""Acceptance probe for the initial SIM2-compatible Cosys ROS graph."""

from __future__ import annotations

import argparse
import bisect
import json
import math
import pathlib
import subprocess
import sys
import threading
import time

import rclpy
from nav_msgs.msg import Odometry
from rclpy.callback_groups import MutuallyExclusiveCallbackGroup
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from sensor_msgs.msg import CameraInfo, Image, Imu


def stamp_ns(message) -> int:
    stamp = message.header.stamp
    return int(stamp.sec) * 1_000_000_000 + int(stamp.nanosec)


class TopicProbe(Node):
    def __init__(self, topic_set: str = "all") -> None:
        super().__init__("indra_cosys_topic_probe")
        sensor_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.VOLATILE,
        )
        imu_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            # Each IMU now has its own callback group. A deeper receive queue
            # absorbs short Python/DDS scheduling bursts without competing
            # with the deliberately shallow 0.9 MB RGB queue.
            depth=100,
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.VOLATILE,
        )
        clock_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=100,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
        )
        image_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            # Match the bridge queue so the qualification probe measures
            # transport throughput rather than dropping a brief DDS burst.
            depth=10,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
        )
        truth_group = MutuallyExclusiveCallbackGroup()
        body_imu_group = MutuallyExclusiveCallbackGroup()
        camera_imu_group = MutuallyExclusiveCallbackGroup()
        image_group = MutuallyExclusiveCallbackGroup()
        info_group = MutuallyExclusiveCallbackGroup()
        self.stamps: dict[str, list[int]] = {name: [] for name in ("clock", "odom", "body_imu", "camera_imu", "image", "camera_info")}
        self.arrivals: dict[str, list[float]] = {name: [] for name in self.stamps}
        self.frames: dict[str, set[str]] = {name: set() for name in ("odom", "odom_child", "body_imu", "camera_imu", "image", "camera_info")}
        self.image_shapes: set[tuple[int, int, str, int]] = set()
        self.camera_models: list[tuple[list[float], list[float], str]] = []
        if topic_set in ("all", "core"):
            self.create_subscription(Clock, "/clock", self.clock_callback, clock_qos, callback_group=truth_group)
            self.create_subscription(Odometry, "/sim/ground_truth/odom", self.odom_callback, sensor_qos, callback_group=truth_group)
            # The two 200 Hz streams must be measured independently. Putting both
            # subscriptions in one mutually-exclusive callback group serializes
            # 400 callbacks/s and makes the probe, rather than the bridge, the
            # bottleneck while large RGB samples are being deserialized.
            self.create_subscription(Imu, "/sim/body/imu", lambda msg: self.imu_callback("body_imu", msg), imu_qos, callback_group=body_imu_group)
            self.create_subscription(Imu, "/sim/camera/imu", lambda msg: self.imu_callback("camera_imu", msg), imu_qos, callback_group=camera_imu_group)
        if topic_set in ("all", "image"):
            # Raw RGB deserialization has its own process during qualification.
            # That mirrors the production graph and prevents Python's GIL from
            # making the probe itself drop IMU or image traffic.
            self.create_subscription(Image, "/sim/camera/image_raw", self.image_callback, image_qos, callback_group=image_group)
            self.create_subscription(CameraInfo, "/sim/camera/camera_info", self.info_callback, image_qos, callback_group=info_group)

    def clock_callback(self, message: Clock) -> None:
        self.arrivals["clock"].append(time.monotonic())
        self.stamps["clock"].append(int(message.clock.sec) * 1_000_000_000 + int(message.clock.nanosec))

    def odom_callback(self, message: Odometry) -> None:
        self.arrivals["odom"].append(time.monotonic())
        self.stamps["odom"].append(stamp_ns(message))
        self.frames["odom"].add(message.header.frame_id)
        self.frames["odom_child"].add(message.child_frame_id)

    def imu_callback(self, name: str, message: Imu) -> None:
        self.arrivals[name].append(time.monotonic())
        self.stamps[name].append(stamp_ns(message))
        self.frames[name].add(message.header.frame_id)

    def image_callback(self, message: Image) -> None:
        self.arrivals["image"].append(time.monotonic())
        self.stamps["image"].append(stamp_ns(message))
        self.frames["image"].add(message.header.frame_id)
        self.image_shapes.add((int(message.width), int(message.height), message.encoding, len(message.data)))

    def info_callback(self, message: CameraInfo) -> None:
        self.arrivals["camera_info"].append(time.monotonic())
        self.stamps["camera_info"].append(stamp_ns(message))
        self.frames["camera_info"].add(message.header.frame_id)
        self.camera_models.append((list(message.k), list(message.d), message.distortion_model))


def rate(stamps: list[int]) -> float:
    if len(stamps) < 2 or stamps[-1] <= stamps[0]:
        return 0.0
    return (len(stamps) - 1) * 1_000_000_000.0 / (stamps[-1] - stamps[0])


def wall_rate(arrivals: list[float]) -> float:
    if len(arrivals) < 2 or arrivals[-1] <= arrivals[0]:
        return 0.0
    return (len(arrivals) - 1) / (arrivals[-1] - arrivals[0])


def worst_full_window_rate(arrivals: list[float], window_s: float = 2.0) -> float:
    if len(arrivals) < 2 or arrivals[-1] - arrivals[0] < window_s:
        return 0.0
    worst = math.inf
    right = 0
    for left, start in enumerate(arrivals):
        end = start + window_s
        if end > arrivals[-1]:
            break
        right = max(right, left)
        while right < len(arrivals) and arrivals[right] < end:
            right += 1
        worst = min(worst, (right - left) / window_s)
    return 0.0 if not math.isfinite(worst) else worst


def monotonic(stamps: list[int]) -> bool:
    return len(stamps) > 1 and all(right > left for left, right in zip(stamps, stamps[1:]))


def nearest_timestamp_p95_ms(reference: list[int], candidates: list[int]) -> float:
    if not reference or not candidates:
        return math.inf
    ordered = sorted(candidates)
    deltas = []
    for stamp in reference:
        index = bisect.bisect_left(ordered, stamp)
        neighbors = []
        if index < len(ordered):
            neighbors.append(abs(ordered[index] - stamp))
        if index > 0:
            neighbors.append(abs(ordered[index - 1] - stamp))
        deltas.append(min(neighbors))
    deltas.sort()
    rank = max(0, math.ceil(0.95 * len(deltas)) - 1)
    return deltas[rank] / 1_000_000.0


def collect(node: TopicProbe, duration_s: float, executor_threads: int, start_wall: float | None = None) -> None:
    executor = MultiThreadedExecutor(num_threads=executor_threads)
    executor.add_node(node)
    spin_thread = threading.Thread(target=executor.spin, name="ros-topic-probe", daemon=False)
    if start_wall is not None:
        time.sleep(max(0.0, start_wall - time.monotonic()))
    spin_thread.start()
    try:
        time.sleep(duration_s)
    finally:
        if not executor.shutdown(timeout_sec=5.0):
            raise RuntimeError("ROS topic probe executor shutdown timed out")
        spin_thread.join(timeout=5.0)
        if spin_thread.is_alive():
            raise RuntimeError("ROS topic probe executor did not stop cleanly")
        completed_futures = list(executor._futures)
        executor._futures.clear()
        for future in completed_futures:
            try:
                future.result()
            except Exception:
                pass
        executor.remove_node(node)
        node.destroy_node()
        rclpy.shutdown()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--profile", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--image-only", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--start-wall", type=float, help=argparse.SUPPRESS)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text(encoding="utf-8"))

    if args.image_only:
        rclpy.init()
        image_node = TopicProbe("image")
        collect(image_node, args.duration, 2, args.start_wall)
        samples = {
            "stamps": {name: image_node.stamps[name] for name in ("image", "camera_info")},
            "arrivals": {name: image_node.arrivals[name] for name in ("image", "camera_info")},
            "frames": {name: sorted(image_node.frames[name]) for name in ("image", "camera_info")},
            "image_shapes": [list(shape) for shape in sorted(image_node.image_shapes)],
            "camera_models": image_node.camera_models,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(samples), encoding="utf-8")
        return 0

    image_samples_path = args.output.with_suffix(args.output.suffix + ".image-samples")
    synchronized_start = time.monotonic() + 2.0
    image_process = subprocess.Popen(
        [
            sys.executable,
            str(pathlib.Path(__file__).resolve()),
            "--duration", str(args.duration),
            "--profile", str(args.profile),
            "--output", str(image_samples_path),
            "--image-only",
            "--start-wall", str(synchronized_start),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    rclpy.init()
    node = TopicProbe("core")
    try:
        collect(node, args.duration, 5, synchronized_start)
        try:
            _, image_stderr = image_process.communicate(timeout=args.duration + 10.0)
        except subprocess.TimeoutExpired:
            image_process.kill()
            image_process.communicate()
            raise RuntimeError("independent ROS image probe timed out")
        if image_process.returncode != 0 or not image_samples_path.is_file():
            raise RuntimeError(
                f"independent ROS image probe failed with code {image_process.returncode}: {image_stderr.strip()}"
            )
        image_samples = json.loads(image_samples_path.read_text(encoding="utf-8"))
        for name in ("image", "camera_info"):
            node.stamps[name] = [int(value) for value in image_samples["stamps"][name]]
            node.arrivals[name] = [float(value) for value in image_samples["arrivals"][name]]
            node.frames[name] = set(image_samples["frames"][name])
        node.image_shapes = {tuple(shape) for shape in image_samples["image_shapes"]}
        node.camera_models = [tuple(model) for model in image_samples["camera_models"]]
    finally:
        if image_process.poll() is None:
            image_process.kill()
            image_process.communicate()
        image_samples_path.unlink(missing_ok=True)

    rates = {name: rate(stamps) for name, stamps in node.stamps.items()}
    wall_rates = {name: wall_rate(arrivals) for name, arrivals in node.arrivals.items()}
    image_worst_2s_hz = worst_full_window_rate(node.arrivals["image"])
    monotonicity = {name: monotonic(stamps) for name, stamps in node.stamps.items()}
    expected_frames = {
        "odom": {profile["ground_truth"]["frame_id"]},
        "odom_child": {profile["ground_truth"]["child_frame_id"]},
        "body_imu": {profile["body_imu"]["frame_id"]},
        "camera_imu": {profile["camera_imu"]["frame_id"]},
        "image": {profile["camera"]["frame_id"]},
        "camera_info": {profile["camera"]["frame_id"]},
    }
    frame_contract = all(node.frames[name] == expected for name, expected in expected_frames.items())
    expected_shape = (
        int(profile["camera"]["width"]),
        int(profile["camera"]["height"]),
        profile["camera"]["encoding"],
        int(profile["camera"]["width"]) * int(profile["camera"]["height"]) * 3,
    )
    camera_model_valid = bool(node.camera_models) and all(
        model == profile["camera"]["distortion_model"]
        and len(k) == 9
        and len(d) == len(profile["camera"]["d"])
        and all(math.isfinite(value) for value in k + d)
        for k, d, model in node.camera_models
    )
    image_info_overlap = len(set(node.stamps["image"]) & set(node.stamps["camera_info"]))
    minimum_rates = {"clock": 20.0, "odom": 20.0, "body_imu": 190.0, "camera_imu": 190.0, "image": 10.0, "camera_info": 10.0}
    maximum_rates = {"body_imu": 210.0, "camera_imu": 210.0}
    image_to_camera_imu_p95_ms = nearest_timestamp_p95_ms(node.stamps["image"], node.stamps["camera_imu"])
    checks = {
        "all_topics_present": all(node.stamps[name] for name in node.stamps),
        "strictly_monotonic_timestamps": all(monotonicity.values()),
        "minimum_initial_rates": all(wall_rates[name] >= minimum for name, minimum in minimum_rates.items()),
        "imu_rates_at_most_210_hz": all(wall_rates[name] <= maximum for name, maximum in maximum_rates.items()),
        "imu_simulation_rates_between_190_and_210_hz": all(
            190.0 <= rates[name] <= 210.0 for name in maximum_rates),
        "camera_nearest_imu_p95_at_most_5_ms": image_to_camera_imu_p95_ms <= 5.0,
        "image_worst_full_2s_at_least_10_hz": image_worst_2s_hz >= 10.0,
        "frame_contract": frame_contract,
        "image_contract": node.image_shapes == {expected_shape},
        "camera_model": camera_model_valid,
        "image_info_timestamp_overlap": image_info_overlap >= max(1, int(len(node.stamps["image"]) * 0.9)),
    }
    passed = all(checks.values())
    result = {
        "schema": 1,
        "verdict": "PASS" if passed else "FAIL",
        "duration_s": args.duration,
        "checks": checks,
        "counts": {name: len(stamps) for name, stamps in node.stamps.items()},
        "rates_hz": rates,
        "wall_rates_hz": wall_rates,
        "image_worst_full_2s_hz": image_worst_2s_hz,
        "image_to_camera_imu_p95_ms": image_to_camera_imu_p95_ms,
        "monotonic": monotonicity,
        "frames": {name: sorted(values) for name, values in node.frames.items()},
        "image_shapes": [list(shape) for shape in sorted(node.image_shapes)],
        "image_info_timestamp_overlap": image_info_overlap,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
