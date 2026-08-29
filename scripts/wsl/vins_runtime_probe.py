#!/usr/bin/env python3
"""Fail-closed runtime gate for iHUB, VINS and ArduPilot ExternalNav."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import time

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import Imu, JointState, PointCloud
from std_msgs.msg import Bool
from vio_stack_interfaces.msg import CameraTiltStatus, ExternalNavHealth, IVINSStatus


class VinsRuntimeProbe(Node):
    def __init__(self) -> None:
        super().__init__("indra_vins_runtime_probe")
        self.started = time.monotonic()
        self.joint_count = 0
        self.joint_min = math.inf
        self.joint_max = -math.inf
        self.joint_max_rate = 0.0
        self.camera_imu_count = 0
        self.camera_imu_max_y_rate = 0.0
        self.camera_imu_min_x_accel = math.inf
        self.camera_imu_max_x_accel = -math.inf
        self.features_max = 0
        self.features_min = math.inf
        self.features_last = 0
        self.feature_messages = 0
        self.feature_messages_below_gate = 0
        self.vins_odometry_count = 0
        self.mavros_odometry_count = 0
        self.ground_truth_position = None
        self.ground_truth_receive_s = 0.0
        self.external_nav_error_count = 0
        self.external_nav_current_error_m = math.inf
        self.external_nav_max_error_m = 0.0
        self.external_nav_max_error_limit_m = 5.0
        self.ihub = None
        self.ihub_reason_history: list[str] = []
        self.initialization = None
        self.external_nav = None

        self.enable_publisher = self.create_publisher(
            Bool, "/sim/qualification/external_nav_alignment_enable", 10
        )
        self.admission_publisher = self.create_publisher(
            Bool, "/sim/qualification/external_nav_alignment_admission", 10
        )
        self.create_subscription(
            JointState, "/camera/tilt/joint_state", self._joint, 10
        )
        self.create_subscription(
            CameraTiltStatus, "/camera/tilt/status", self._ihub, 10
        )
        self.create_subscription(
            IVINSStatus, "/vio/initialization/status", self._initialization, 10
        )
        self.create_subscription(
            ExternalNavHealth, "/vio/external_nav/health", self._external_nav, 10
        )
        self.create_subscription(
            Imu, "/sim/camera/imu", self._camera_imu, qos_profile_sensor_data
        )
        self.create_subscription(
            PointCloud, "/feature_tracker/feature", self._features, qos_profile_sensor_data
        )
        self.create_subscription(
            Odometry, "/vins_estimator/odometry", self._vins_odometry, qos_profile_sensor_data
        )
        self.create_subscription(
            Odometry, "/mavros/odometry/out", self._mavros_odometry, qos_profile_sensor_data
        )
        self.create_subscription(
            Odometry, "/sim/ground_truth/odom", self._ground_truth, qos_profile_sensor_data
        )
        self.create_timer(0.5, self._request_alignment)

    def _request_alignment(self) -> None:
        self.enable_publisher.publish(Bool(data=True))
        self.admission_publisher.publish(Bool(data=True))

    def _joint(self, message: JointState) -> None:
        try:
            index = message.name.index("camera_tilt_joint")
            angle = float(message.position[index])
            rate = float(message.velocity[index]) if index < len(message.velocity) else 0.0
        except (ValueError, IndexError):
            return
        if math.isfinite(angle) and math.isfinite(rate):
            self.joint_count += 1
            self.joint_min = min(self.joint_min, angle)
            self.joint_max = max(self.joint_max, angle)
            self.joint_max_rate = max(self.joint_max_rate, abs(rate))

    def _ihub(self, message: CameraTiltStatus) -> None:
        self.ihub = message
        reason = str(message.reason).strip()
        if reason and (not self.ihub_reason_history or self.ihub_reason_history[-1] != reason):
            self.ihub_reason_history.append(reason)
            self.ihub_reason_history = self.ihub_reason_history[-32:]

    def _initialization(self, message: IVINSStatus) -> None:
        self.initialization = message

    def _external_nav(self, message: ExternalNavHealth) -> None:
        self.external_nav = message

    def _camera_imu(self, message: Imu) -> None:
        self.camera_imu_count += 1
        self.camera_imu_max_y_rate = max(
            self.camera_imu_max_y_rate, abs(float(message.angular_velocity.y))
        )
        x_accel = float(message.linear_acceleration.x)
        self.camera_imu_min_x_accel = min(self.camera_imu_min_x_accel, x_accel)
        self.camera_imu_max_x_accel = max(self.camera_imu_max_x_accel, x_accel)

    def _features(self, message: PointCloud) -> None:
        count = len(message.points)
        self.feature_messages += 1
        self.features_last = count
        self.features_min = min(self.features_min, count)
        self.features_max = max(self.features_max, count)
        if count < 15:
            self.feature_messages_below_gate += 1

    def _vins_odometry(self, _message: Odometry) -> None:
        self.vins_odometry_count += 1

    def _ground_truth(self, message: Odometry) -> None:
        position = message.pose.pose.position
        values = (float(position.x), float(position.y), float(position.z))
        if all(math.isfinite(value) for value in values):
            self.ground_truth_position = values
            self.ground_truth_receive_s = time.monotonic()

    def _mavros_odometry(self, message: Odometry) -> None:
        self.mavros_odometry_count += 1
        if (
            self.ground_truth_position is None
            or time.monotonic() - self.ground_truth_receive_s > 0.25
        ):
            return
        position = message.pose.pose.position
        values = (float(position.x), float(position.y), float(position.z))
        if not all(math.isfinite(value) for value in values):
            return
        error_m = math.sqrt(sum(
            (values[index] - self.ground_truth_position[index]) ** 2
            for index in range(3)
        ))
        self.external_nav_error_count += 1
        self.external_nav_current_error_m = error_m
        self.external_nav_max_error_m = max(self.external_nav_max_error_m, error_m)

    def result(self) -> dict:
        joint_span = (
            self.joint_max - self.joint_min if self.joint_count > 1 else 0.0
        )
        acceleration_span = (
            self.camera_imu_max_x_accel - self.camera_imu_min_x_accel
            if self.camera_imu_count > 1 else 0.0
        )
        gates = {
            "ihub_ready": bool(
                self.ihub
                and self.ihub.state == CameraTiltStatus.READY
                and self.ihub.uart_connected
                and self.ihub.server_healthy
                and self.ihub.session_calibrated
                and self.ihub.applied_angle_valid
            ),
            "gimbal_sweep": self.joint_count >= 10 and joint_span >= 0.70,
            "camera_imu_motion": (
                self.camera_imu_count >= 100
                and (
                    self.camera_imu_max_y_rate >= 0.20
                    or acceleration_span >= 5.0
                )
            ),
            "vins_tracking": bool(
                self.initialization
                and self.initialization.state == IVINSStatus.READY
                and self.initialization.allow_navigation_output
                and self.vins_odometry_count >= 10
                and self.features_max >= 15
            ),
            "external_nav_ready": bool(
                self.external_nav
                and self.external_nav.state == ExternalNavHealth.READY
                and self.external_nav.ready
                and self.external_nav.input_fresh
                and self.external_nav.alignment_valid
                and self.external_nav.camera_mount_valid
                and self.mavros_odometry_count >= 5
            ),
            "external_nav_ground_truth": bool(
                self.external_nav_error_count >= 5
                and time.monotonic() - self.ground_truth_receive_s <= 0.25
                and self.external_nav_current_error_m
                <= self.external_nav_max_error_limit_m
                and self.external_nav_max_error_m
                <= self.external_nav_max_error_limit_m
            ),
        }
        return {
            "schema": 1,
            "status": "PASS" if all(gates.values()) else "WAITING",
            "elapsed_s": time.monotonic() - self.started,
            "gates": gates,
            "measurements": {
                "joint_count": self.joint_count,
                "joint_min_rad": None if self.joint_count == 0 else self.joint_min,
                "joint_max_rad": None if self.joint_count == 0 else self.joint_max,
                "joint_span_rad": joint_span,
                "joint_max_rate_rad_s": self.joint_max_rate,
                "camera_imu_count": self.camera_imu_count,
                "camera_imu_max_y_rate_rad_s": self.camera_imu_max_y_rate,
                "camera_imu_x_acceleration_span_m_s2": acceleration_span,
                "features_max": self.features_max,
                "features_min": (
                    None if self.feature_messages == 0 else self.features_min
                ),
                "features_last": self.features_last,
                "feature_messages": self.feature_messages,
                "feature_messages_below_gate": self.feature_messages_below_gate,
                "vins_odometry_count": self.vins_odometry_count,
                "mavros_odometry_count": self.mavros_odometry_count,
                "external_nav_ground_truth_error_count": self.external_nav_error_count,
                "external_nav_current_ground_truth_error_m": (
                    None
                    if self.external_nav_error_count == 0
                    else self.external_nav_current_error_m
                ),
                "external_nav_maximum_ground_truth_error_m": self.external_nav_max_error_m,
                "external_nav_ground_truth_error_limit_m": self.external_nav_max_error_limit_m,
                "ihub_reason": "" if self.ihub is None else self.ihub.reason,
                "ihub_reason_history": self.ihub_reason_history,
                "ihub_calibration_valid": bool(
                    self.ihub and self.ihub.calibration_valid
                ),
                "ihub_session_calibrated": bool(
                    self.ihub and self.ihub.session_calibrated
                ),
                "initialization_reason": (
                    "" if self.initialization is None else self.initialization.reason
                ),
                "initialization_state": (
                    None if self.initialization is None else int(self.initialization.state)
                ),
                "initialization_elapsed_s": (
                    None
                    if self.initialization is None
                    else float(self.initialization.initialization_elapsed_s)
                ),
                "initialization_odometry_count": (
                    0 if self.initialization is None else int(self.initialization.odometry_count)
                ),
                "initialization_reset_count": (
                    0 if self.initialization is None else int(self.initialization.reset_count)
                ),
                "initialization_current_drift_m": (
                    None
                    if self.initialization is None
                    else float(self.initialization.current_drift_m)
                ),
                "initialization_maximum_drift_m": (
                    None
                    if self.initialization is None
                    else float(self.initialization.maximum_drift_m)
                ),
                "external_nav_reason": (
                    "" if self.external_nav is None else self.external_nav.reason
                ),
            },
        }


def write_result(path: Path, result: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # The evidence bundle is on a Windows DrvFS mount. Windows indexers can
    # briefly hold the destination open, which makes POSIX atomic replace fail
    # with EACCES even though a normal write remains valid.
    path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")


def apply_completion_gate(result: dict, completion_file: Path | None) -> dict:
    """Require a completed PASS mission before a qualification probe may pass."""
    if completion_file is None:
        return result
    verdict = ""
    try:
        payload = json.loads(completion_file.read_text(encoding="utf-8"))
        verdict = str(payload.get("verdict", ""))
    except (OSError, TypeError, ValueError):
        pass
    complete = verdict == "PASS"
    result["gates"]["mission_complete"] = complete
    result["measurements"]["mission_verdict"] = verdict
    if not complete:
        result["status"] = "WAITING"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--completion-file", type=Path)
    args = parser.parse_args()

    rclpy.init()
    node = VinsRuntimeProbe()
    deadline = time.monotonic() + args.timeout
    result = node.result()
    try:
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
            result = apply_completion_gate(node.result(), args.completion_file)
            write_result(args.output, result)
            if result["status"] == "PASS":
                print(json.dumps(result, indent=2, sort_keys=True))
                return 0
        result["status"] = "FAIL"
        result["error"] = "VINS runtime gates did not pass before timeout"
        write_result(args.output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 1
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
