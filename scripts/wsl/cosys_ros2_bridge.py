#!/usr/bin/env python3
"""Publish the SIM2-compatible ROS 2 sensor contract from Cosys-AirSim."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import signal
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

import cosysairsim as airsim
import rclpy
from builtin_interfaces.msg import Time
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from sensor_msgs.msg import CameraInfo, Image, Imu
from sensor_msgs.msg import JointState
from std_msgs.msg import String

from gimbal_imu import apply_gimbal_to_flu, sample_gimbal_history
from imu_validation import validate_imu_vectors


def ros_time(timestamp_ns: int) -> Time:
    timestamp_ns = max(0, int(timestamp_ns))
    return Time(sec=timestamp_ns // 1_000_000_000, nanosec=timestamp_ns % 1_000_000_000)


def ned_to_enu(vector) -> tuple[float, float, float]:
    return float(vector.y_val), float(vector.x_val), -float(vector.z_val)


def frd_to_flu(vector) -> tuple[float, float, float]:
    return float(vector.x_val), -float(vector.y_val), -float(vector.z_val)


def ned_frd_to_enu_flu(quaternion, previous: tuple[float, float, float, float] | None = None):
    """Convert R_NED_FRD to R_ENU_FLU and preserve quaternion sign continuity."""
    a = math.sqrt(0.5)
    w = -a * (float(quaternion.w_val) + float(quaternion.z_val))
    x = -a * (float(quaternion.x_val) + float(quaternion.y_val))
    y = a * (float(quaternion.y_val) - float(quaternion.x_val))
    z = a * (float(quaternion.z_val) - float(quaternion.w_val))
    norm = math.sqrt(w * w + x * x + y * y + z * z)
    if norm <= 0.0 or not math.isfinite(norm):
        raise ValueError("invalid source quaternion")
    current = (x / norm, y / norm, z / norm, w / norm)
    if previous is not None and sum(left * right for left, right in zip(current, previous)) < 0.0:
        current = tuple(-value for value in current)
    return current


def assign_vector(target, values: tuple[float, float, float]) -> None:
    target.x, target.y, target.z = values


def assign_quaternion(target, values: tuple[float, float, float, float]) -> None:
    target.x, target.y, target.z, target.w = values


@dataclass
class TopicStats:
    count: int = 0
    first_wall: float = 0.0
    last_wall: float = 0.0
    last_stamp_ns: int = 0
    duplicates_dropped: int = 0
    backward_dropped: int = 0
    errors: int = 0
    batch_overflows: int = 0
    physical_rejected: int = 0


@dataclass
class BridgeStats:
    topics: dict[str, TopicStats] = field(default_factory=dict)
    lock: threading.Lock = field(default_factory=threading.Lock)
    last_error: str = ""

    def accepted(self, topic: str, stamp_ns: int) -> bool:
        with self.lock:
            stats = self.topics.setdefault(topic, TopicStats())
            if stamp_ns <= 0:
                stats.backward_dropped += 1
                return False
            if stamp_ns == stats.last_stamp_ns and stats.last_stamp_ns != 0:
                stats.duplicates_dropped += 1
                return False
            if stamp_ns < stats.last_stamp_ns:
                stats.backward_dropped += 1
                return False
            now = time.monotonic()
            if stats.count == 0:
                stats.first_wall = now
            stats.last_wall = now
            stats.last_stamp_ns = stamp_ns
            stats.count += 1
            return True

    def error(self, topic: str, exception: BaseException) -> None:
        with self.lock:
            self.topics.setdefault(topic, TopicStats()).errors += 1
            self.last_error = f"{topic}: {type(exception).__name__}: {exception}"

    def reject_physical(self, topic: str, exception: BaseException) -> None:
        with self.lock:
            self.topics.setdefault(topic, TopicStats()).physical_rejected += 1
            # Sticky for the immutable run: a later plausible sample must not
            # erase evidence of catastrophic physics or transport corruption.
            self.last_error = f"{topic}: physically invalid sample: {exception}"

    def snapshot(self) -> dict:
        with self.lock:
            topics = {}
            for name, stats in self.topics.items():
                span = stats.last_wall - stats.first_wall
                topics[name] = {
                    "count": stats.count,
                    "wall_hz": (stats.count - 1) / span if stats.count > 1 and span > 0 else 0.0,
                    "last_stamp_ns": stats.last_stamp_ns,
                    "duplicates_dropped": stats.duplicates_dropped,
                    "backward_dropped": stats.backward_dropped,
                    "errors": stats.errors,
                    "batch_overflows": stats.batch_overflows,
                    "physical_rejected": stats.physical_rejected,
                }
            return {"schema": 1, "topics": topics, "last_error": self.last_error}


@dataclass
class GimbalState:
    angle_rad: float
    rate_rad_s: float = 0.0
    updated_wall: float = 0.0
    accepted: int = 0
    rejected: int = 0
    pose_applied: int = 0
    pose_errors: int = 0
    history: list[tuple[int, float, float]] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def update(self, message: JointState) -> None:
        try:
            index = message.name.index("camera_tilt_joint")
            angle = float(message.position[index])
            rate = float(message.velocity[index]) if index < len(message.velocity) else 0.0
            if (
                not math.isfinite(angle)
                or not math.isfinite(rate)
                or not -0.05 <= angle <= math.pi / 2.0 + 0.05
            ):
                raise ValueError("invalid camera tilt joint state")
        except (ValueError, IndexError):
            with self.lock:
                self.rejected += 1
            return
        with self.lock:
            self.angle_rad = angle
            self.rate_rad_s = rate
            self.updated_wall = time.monotonic()
            self.accepted += 1
            stamp_ns = (
                int(message.header.stamp.sec) * 1_000_000_000
                + int(message.header.stamp.nanosec)
            )
            if stamp_ns > 0:
                if self.history and stamp_ns == self.history[-1][0]:
                    self.history[-1] = (stamp_ns, angle, rate)
                elif not self.history or stamp_ns > self.history[-1][0]:
                    self.history.append((stamp_ns, angle, rate))
                    cutoff_ns = stamp_ns - 10_000_000_000
                    first_current = 0
                    while (
                        first_current + 1 < len(self.history)
                        and self.history[first_current + 1][0] < cutoff_ns
                    ):
                        first_current += 1
                    if first_current:
                        del self.history[:first_current]

    def sample(self) -> tuple[float, float]:
        with self.lock:
            # A stale angle remains the physical held position; only the servo
            # velocity fails closed to zero after status transport stops.
            rate = self.rate_rad_s if time.monotonic() - self.updated_wall <= 0.5 else 0.0
            return self.angle_rad, rate

    def has_authoritative_sample(self) -> bool:
        with self.lock:
            return self.accepted > 0

    def sample_at(self, timestamp_ns: int) -> tuple[float, float]:
        with self.lock:
            if not self.history:
                rate = (
                    self.rate_rad_s
                    if time.monotonic() - self.updated_wall <= 0.5
                    else 0.0
                )
                return self.angle_rad, rate
            return sample_gimbal_history(self.history, int(timestamp_ns))

    def record_pose(self, success: bool) -> None:
        with self.lock:
            if success:
                self.pose_applied += 1
            else:
                self.pose_errors += 1

    def snapshot(self) -> dict:
        with self.lock:
            age = None if self.updated_wall == 0.0 else time.monotonic() - self.updated_wall
            return {
                "angle_rad": self.angle_rad,
                "rate_rad_s": self.rate_rad_s,
                "status_age_s": age,
                "accepted": self.accepted,
                "rejected": self.rejected,
                "pose_applied": self.pose_applied,
                "pose_errors": self.pose_errors,
            }


class CosysRosBridge(Node):
    def __init__(self, host: str, port: int, profile: dict, status_path: pathlib.Path) -> None:
        super().__init__("indra_cosys_ros2_bridge")
        self.host = host
        self.port = port
        self.profile = profile
        self.status_path = status_path
        self.stop_event = threading.Event()
        self.stats = BridgeStats()
        self.threads: list[threading.Thread] = []
        self.gimbal = GimbalState(
            angle_rad=float(profile["camera_imu"].get("gimbal_default_angle_rad", 0.0))
        )

        sensor_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.VOLATILE,
        )
        image_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            # A raw 640x480 RGB sample is large enough that Windows/WSL DDS
            # transport occasionally delivers a short burst.  Ten samples
            # absorb that burst without allowing an unbounded image backlog.
            depth=10,
            # Fragmented 0.9 MB RGB samples were selectively lost across the
            # Windows/WSL DDS boundary while tiny CameraInfo samples survived.
            # A bounded reliable queue provides complete VINS frames without
            # creating an unbounded recorder-style backlog.
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
        )
        reliable_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
        )
        self.clock_publisher = self.create_publisher(Clock, "/clock", reliable_qos)
        self.odom_publisher = self.create_publisher(Odometry, "/sim/ground_truth/odom", sensor_qos)
        self.body_imu_publisher = self.create_publisher(Imu, "/sim/body/imu", sensor_qos)
        self.camera_imu_publisher = self.create_publisher(Imu, "/sim/camera/imu", sensor_qos)
        self.image_publisher = self.create_publisher(Image, "/sim/camera/image_raw", image_qos)
        self.camera_info_publisher = self.create_publisher(CameraInfo, "/sim/camera/camera_info", image_qos)
        self.status_publisher = self.create_publisher(String, "/sim/cosys_bridge/status", reliable_qos)
        self.create_subscription(
            JointState, "/camera/tilt/joint_state", self.gimbal.update, reliable_qos
        )
        self.create_timer(1.0, self.publish_status)

    def client(self):
        client = airsim.MultirotorClient(ip=self.host, port=self.port, timeout_value=5)
        if not client.ping():
            raise ConnectionError(f"Cosys RPC did not answer at {self.host}:{self.port}")
        return client

    def start_workers(self) -> None:
        workers: tuple[tuple[str, Callable[[], None]], ...] = (
            ("truth", self.truth_worker),
            ("body_imu", lambda: self.imu_worker("body_imu", self.body_imu_publisher)),
            ("camera_imu", lambda: self.imu_worker("camera_imu", self.camera_imu_publisher)),
            ("camera", self.camera_worker),
        )
        for name, target in workers:
            thread = threading.Thread(target=self.worker_guard, args=(name, target), name=name, daemon=True)
            thread.start()
            self.threads.append(thread)

    def worker_guard(self, name: str, target: Callable[[], None]) -> None:
        while not self.stop_event.is_set():
            try:
                target()
            except Exception as exception:  # RPC reconnect boundary
                if self.stop_event.is_set():
                    return
                self.stats.error(name, exception)
                self.get_logger().error(self.stats.last_error)
                self.stop_event.wait(1.0)

    def truth_worker(self) -> None:
        client = self.client()
        vehicle = self.profile["vehicle"]
        truth = self.profile["ground_truth"]
        clock_imu_name = self.profile["body_imu"]["name"]
        period = 1.0 / float(truth["published_hz"])
        previous_orientation = None
        while not self.stop_event.is_set():
            started = time.monotonic()
            kinematics = client.simGetGroundTruthKinematics(vehicle_name=vehicle)
            # ArduCopterApi's generic multirotor state accessors are stubs and
            # log three "Not Implemented" lines per request. At 50 Hz that
            # disk I/O can stall Unreal's game thread and GPU capture. The
            # authoritative body IMU carries the same simulation clock.
            stamp_ns = int(
                client.getImuData(
                    imu_name=clock_imu_name, vehicle_name=vehicle
                ).time_stamp
            )
            if self.stats.accepted("/sim/ground_truth/odom", stamp_ns):
                stamp = ros_time(stamp_ns)
                clock = Clock()
                clock.clock = stamp
                self.clock_publisher.publish(clock)

                message = Odometry()
                message.header.stamp = stamp
                message.header.frame_id = truth["frame_id"]
                message.child_frame_id = truth["child_frame_id"]
                assign_vector(message.pose.pose.position, ned_to_enu(kinematics.position))
                previous_orientation = ned_frd_to_enu_flu(kinematics.orientation, previous_orientation)
                assign_quaternion(message.pose.pose.orientation, previous_orientation)
                assign_vector(message.twist.twist.linear, ned_to_enu(kinematics.linear_velocity))
                assign_vector(message.twist.twist.angular, frd_to_flu(kinematics.angular_velocity))
                self.odom_publisher.publish(message)
            self.stop_event.wait(max(0.0, period - (time.monotonic() - started)))

    def imu_worker(self, profile_key: str, publisher) -> None:
        client = self.client()
        vehicle = self.profile["vehicle"]
        sensor = self.profile[profile_key]
        previous_orientation = None
        published_hz = float(sensor["wall_budget_hz"])
        poll_period = 1.0 / float(sensor.get("batch_poll_hz", 100.0))
        cursor_ns = int(client.getImuData(imu_name=sensor["name"], vehicle_name=vehicle).time_stamp)
        next_poll = time.monotonic()
        quota_updated = next_poll
        publish_quota = 0.0
        while not self.stop_event.is_set():
            next_poll += poll_period
            topic = "/sim/body/imu" if profile_key == "body_imu" else "/sim/camera/imu"
            batch = client.getImuDataBatch(
                imu_name=sensor["name"], vehicle_name=vehicle,
                after_timestamp=cursor_ns, max_samples=512)
            if batch.overflow:
                with self.stats.lock:
                    self.stats.topics.setdefault(topic, TopicStats()).batch_overflows += 1
            if not batch.samples:
                self.stop_event.wait(max(0.0, next_poll - time.monotonic()))
                continue
            cursor_ns = max(cursor_ns, int(batch.samples[-1].time_stamp))
            now = time.monotonic()
            publish_quota += max(0.0, now - quota_updated) * published_hz
            quota_updated = now
            emit_count = min(len(batch.samples), int(publish_quota))
            if emit_count <= 0:
                self.stop_event.wait(max(0.0, next_poll - time.monotonic()))
                continue
            publish_quota -= emit_count
            # Select samples across the complete source interval instead of
            # taking a prefix. This preserves the newest timestamp and bounds
            # camera-nearest-IMU error while amortizing RPC/msgpack overhead.
            selected = [
                batch.samples[math.ceil((index + 1) * len(batch.samples) / emit_count) - 1]
                for index in range(emit_count)
            ]
            for data in selected:
                stamp_ns = int(data.time_stamp)
                try:
                    orientation = ned_frd_to_enu_flu(data.orientation, previous_orientation)
                    angular_velocity = frd_to_flu(data.angular_velocity)
                    linear_acceleration = frd_to_flu(data.linear_acceleration)
                    if profile_key == "camera_imu" and sensor.get("mounting") == "ihub-pitched":
                        angle_rad, rate_rad_s = self.gimbal.sample_at(stamp_ns)
                        orientation, angular_velocity, linear_acceleration = apply_gimbal_to_flu(
                            orientation, angular_velocity, linear_acceleration,
                            angle_rad, rate_rad_s,
                        )
                    validate_imu_vectors(
                        angular_velocity,
                        linear_acceleration,
                        max_angular_velocity_rad_s=float(sensor["max_angular_velocity_rad_s"]),
                        max_linear_acceleration_m_s2=float(sensor["max_linear_acceleration_m_s2"]),
                    )
                except (TypeError, ValueError) as exception:
                    self.stats.reject_physical(topic, exception)
                    continue
                previous_orientation = orientation
                if not self.stats.accepted(topic, stamp_ns):
                    continue
                message = Imu()
                message.header.stamp = ros_time(stamp_ns)
                message.header.frame_id = sensor["frame_id"]
                assign_quaternion(message.orientation, orientation)
                assign_vector(message.angular_velocity, angular_velocity)
                assign_vector(message.linear_acceleration, linear_acceleration)
                publisher.publish(message)
            self.stop_event.wait(max(0.0, next_poll - time.monotonic()))

    def camera_worker(self) -> None:
        client = self.client()
        vehicle = self.profile["vehicle"]
        camera = self.profile["camera"]
        request = [airsim.ImageRequest(camera["name"], airsim.ImageType.Scene, False, False)]
        period = 1.0 / float(camera["published_hz"])
        position = tuple(float(value) for value in camera.get("mount_position_ned_m", (0.0, 0.0, 0.0)))
        if len(position) != 3 or not all(math.isfinite(value) for value in position):
            raise ValueError("camera.mount_position_ned_m must contain three finite values")
        pitch_sign = float(camera.get("gimbal_pitch_sign", 1.0))
        if pitch_sign not in (-1.0, 1.0):
            raise ValueError("camera.gimbal_pitch_sign must be -1 or 1")
        last_pose_angle = None
        last_pose_wall = 0.0
        while not self.stop_event.is_set():
            started = time.monotonic()
            # Keep camera actuation and image capture on one established RPC
            # connection. Cosys can starve a late independent msgpack client
            # while the four sensor workers are active. The production iHUB
            # remains authoritative for plant/calibration state and publishes
            # the applied joint angle; this worker only mirrors that physical
            # angle into UE before capturing the next frame.
            angle_rad, _ = self.gimbal.sample()
            pose_due = self.gimbal.has_authoritative_sample() and (
                last_pose_angle is None
                or abs(angle_rad - last_pose_angle) >= 1.0e-4
                or started - last_pose_wall >= 1.0
            )
            if pose_due:
                pose = airsim.Pose(
                    airsim.Vector3r(*position),
                    airsim.euler_to_quaternion(0.0, pitch_sign * angle_rad, 0.0),
                )
                try:
                    client.simSetCameraPose(
                        camera["name"], pose, vehicle_name=vehicle
                    )
                    self.gimbal.record_pose(True)
                    last_pose_angle = angle_rad
                    last_pose_wall = started
                except Exception:
                    self.gimbal.record_pose(False)
                    raise
            response = client.simGetImages(request, vehicle_name=vehicle)[0]
            stamp_ns = int(response.time_stamp)
            if not self.stats.accepted("/sim/camera/image_raw", stamp_ns):
                self.stop_event.wait(0.001)
                continue
            width, height = int(response.width), int(response.height)
            payload = bytes(response.image_data_uint8)
            if width <= 0 or height <= 0 or len(payload) != width * height * 3:
                raise ValueError(f"invalid RGB frame {width}x{height}, bytes={len(payload)}")
            stamp = ros_time(stamp_ns)
            image = Image()
            image.header.stamp = stamp
            image.header.frame_id = camera["frame_id"]
            image.height = height
            image.width = width
            image.encoding = camera["encoding"]
            image.is_bigendian = False
            image.step = width * 3
            image.data = payload
            self.image_publisher.publish(image)

            scale_x = width / float(camera["width"])
            scale_y = height / float(camera["height"])
            source_k = [float(value) for value in camera["k"]]
            k = list(source_k)
            k[0], k[2], k[4], k[5] = k[0] * scale_x, k[2] * scale_x, k[4] * scale_y, k[5] * scale_y
            info = CameraInfo()
            info.header.stamp = stamp
            info.header.frame_id = camera["frame_id"]
            info.height = height
            info.width = width
            info.distortion_model = camera["distortion_model"]
            info.d = [float(value) for value in camera["d"]]
            info.k = k
            info.r = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
            info.p = [k[0], 0.0, k[2], 0.0, 0.0, k[4], k[5], 0.0, 0.0, 0.0, 1.0, 0.0]
            self.camera_info_publisher.publish(info)
            self.stop_event.wait(max(0.0, period - (time.monotonic() - started)))

    def publish_status(self) -> None:
        snapshot = self.stats.snapshot()
        snapshot["gimbal"] = self.gimbal.snapshot()
        message = String()
        message.data = json.dumps(snapshot, separators=(",", ":"), sort_keys=True)
        self.status_publisher.publish(message)
        temporary = self.status_path.with_suffix(self.status_path.suffix + ".tmp")
        temporary.write_text(json.dumps(snapshot, indent=2, sort_keys=True), encoding="utf-8")
        temporary.replace(self.status_path)

    def stop(self) -> None:
        self.stop_event.set()
        for thread in self.threads:
            thread.join(timeout=6.0)
        try:
            self.publish_status()
        except Exception:
            # SIGTERM can shut the rclpy context down before the final snapshot.
            # The periodic status file is already durable, so shutdown must not
            # become a false runtime failure.
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--profile", type=pathlib.Path, required=True)
    parser.add_argument("--status", type=pathlib.Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text(encoding="utf-8"))
    args.status.parent.mkdir(parents=True, exist_ok=True)

    rclpy.init()
    node = CosysRosBridge(args.host, args.port, profile, args.status)
    node.start_workers()

    def terminate(*_) -> None:
        node.stop_event.set()
        rclpy.try_shutdown()

    signal.signal(signal.SIGTERM, terminate)
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.stop()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
