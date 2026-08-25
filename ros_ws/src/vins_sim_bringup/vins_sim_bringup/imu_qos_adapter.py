"""Expose a sensor-data IMU with the reliable QoS VINS-NEO expects."""

from __future__ import annotations

from dataclasses import dataclass
import json

import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import Imu
from std_msgs.msg import String


@dataclass
class MonotonicImuGate:
    received: int = 0
    published: int = 0
    rejected_duplicate: int = 0
    rejected_regressive: int = 0
    last_stamp_ns: int | None = None

    def accept(self, stamp_ns: int) -> bool:
        self.received += 1
        if self.last_stamp_ns is not None and stamp_ns <= self.last_stamp_ns:
            if stamp_ns == self.last_stamp_ns:
                self.rejected_duplicate += 1
            else:
                self.rejected_regressive += 1
            return False
        self.last_stamp_ns = stamp_ns
        self.published += 1
        return True


class ImuQosAdapter(Node):
    def __init__(self) -> None:
        super().__init__("imu_qos_adapter")
        self.declare_parameter("input_topic", "/sim/body/imu")
        self.declare_parameter("output_topic", "/mavros/imu/data_raw")
        reliable = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=2000,
            reliability=ReliabilityPolicy.RELIABLE,
        )
        sensor_data = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=200,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        self.publisher = self.create_publisher(
            Imu, str(self.get_parameter("output_topic").value), reliable
        )
        self.diagnostics = self.create_publisher(
            String, "/vins/imu_adapter/diagnostics", 10
        )
        self.gate = MonotonicImuGate()
        self.create_subscription(
            Imu,
            str(self.get_parameter("input_topic").value),
            self._forward,
            sensor_data,
        )
        self.create_timer(1.0, self._publish_diagnostics)

    def _forward(self, message: Imu) -> None:
        stamp_ns = (
            int(message.header.stamp.sec) * 1_000_000_000
            + int(message.header.stamp.nanosec)
        )
        if self.gate.accept(stamp_ns):
            self.publisher.publish(message)

    def _publish_diagnostics(self) -> None:
        self.diagnostics.publish(String(data=json.dumps({
            "received": self.gate.received,
            "published": self.gate.published,
            "rejected_duplicate": self.gate.rejected_duplicate,
            "rejected_regressive": self.gate.rejected_regressive,
            "last_stamp_ns": self.gate.last_stamp_ns,
        }, sort_keys=True)))


def main() -> None:
    rclpy.init()
    node = ImuQosAdapter()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()
