"""Apply checkpoint-synchronised wind to both ArduPilot SITL and Cosys physics."""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor
import json
import time

import cosysairsim
from pymavlink import mavutil
import rclpy
from rclpy.node import Node
from std_msgs.msg import String

from .wind_contract import decode_wind_command, speed_direction_to_ned, vector_matches


class WindDriver(Node):
    """Publish WindTruth only after SITL and Unreal read back the applied values."""

    COMMAND_TOPIC = "/sim/wind/command"
    TRUTH_TOPIC = "/sim/wind/truth"
    STAGE_KINDS = {"baseline", "gust", "recovery"}

    def __init__(self) -> None:
        super().__init__("ivins_wind_driver")
        self.declare_parameter("cosys_host", "127.0.0.1")
        self.declare_parameter("cosys_port", 41452)
        self.declare_parameter("cosys_timeout_s", 5.0)
        self.declare_parameter("mavlink_url", "tcp:127.0.0.1:5784")
        self.declare_parameter("mavlink_timeout_s", 8.0)
        self.cosys_host = str(self.get_parameter("cosys_host").value)
        self.cosys_port = int(self.get_parameter("cosys_port").value)
        self.cosys_timeout_s = float(self.get_parameter("cosys_timeout_s").value)
        self.mavlink_url = str(self.get_parameter("mavlink_url").value)
        self.mavlink_timeout_s = float(self.get_parameter("mavlink_timeout_s").value)
        self.publisher = self.create_publisher(String, self.TRUTH_TOPIC, 10)
        self.create_subscription(String, self.COMMAND_TOPIC, self._command, 10)
        self.pending_command_id: str | None = None
        self.last_ack: dict[str, object] | None = None
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ivins-wind")
        self._cosys_future: Future[
            tuple[float, float, tuple[float, float, float]]
        ] | None = None
        self._cosys_context: tuple[dict[str, object], float, float] | None = None
        self.create_timer(0.05, self._poll_cosys)

    @classmethod
    def _decode(cls, message: String) -> dict[str, object]:
        return decode_wind_command(json.loads(message.data))

    @staticmethod
    def _parameter_name(message) -> str:
        value = message.param_id
        if isinstance(value, bytes):
            return value.decode("ascii", errors="ignore").rstrip("\x00")
        return str(value).rstrip("\x00")

    def _set_sitl_parameter(self, connection, name: str, value: float) -> float:
        deadline = time.monotonic() + self.mavlink_timeout_s
        while time.monotonic() < deadline:
            connection.mav.param_set_send(
                connection.target_system,
                connection.target_component,
                name.encode("ascii"),
                float(value),
                mavutil.mavlink.MAV_PARAM_TYPE_REAL32,
            )
            response_deadline = min(deadline, time.monotonic() + 1.0)
            while time.monotonic() < response_deadline:
                response = connection.recv_match(
                    type="PARAM_VALUE", blocking=True, timeout=0.25
                )
                if response is not None and self._parameter_name(response) == name:
                    return float(response.param_value)
        raise TimeoutError(f"SITL did not acknowledge parameter {name}")

    def _set_and_read_backends(
        self, speed_mps: float, direction_deg: float
    ) -> tuple[float, float, tuple[float, float, float]]:
        connection = mavutil.mavlink_connection(
            self.mavlink_url,
            source_system=250,
            source_component=191,
            autoreconnect=False,
        )
        try:
            heartbeat = connection.wait_heartbeat(timeout=self.mavlink_timeout_s)
            if heartbeat is None:
                raise TimeoutError("SITL wind MAVLink heartbeat timed out")
            applied_speed = self._set_sitl_parameter(connection, "SIM_WIND_SPD", speed_mps)
            applied_direction = self._set_sitl_parameter(
                connection, "SIM_WIND_DIR", direction_deg
            )
        finally:
            connection.close()

        wind = speed_direction_to_ned(applied_speed, applied_direction)
        client = cosysairsim.MultirotorClient(
            ip=self.cosys_host,
            port=self.cosys_port,
            timeout_value=self.cosys_timeout_s,
        )
        requested = cosysairsim.Vector3r(*wind)
        client.simSetWind(requested)
        applied = client.simGetWind()
        return (
            applied_speed,
            applied_direction,
            (float(applied.x_val), float(applied.y_val), float(applied.z_val)),
        )

    def _publish_ack(
        self,
        payload: dict[str, object],
        *,
        applied_speed_mps: float,
        applied_direction_deg: float,
        applied_vector: tuple[float, float, float],
    ) -> None:
        requested_speed = float(payload["speed_mps"])
        requested_direction = float(payload["direction_deg"])
        requested_north, requested_east, requested_down = speed_direction_to_ned(
            requested_speed, requested_direction
        )
        applied_north, applied_east, applied_down = applied_vector
        ack = {
            **payload,
            "requested_speed_mps": requested_speed,
            "requested_direction_deg": requested_direction,
            "requested_north_mps": requested_north,
            "requested_east_mps": requested_east,
            "requested_down_mps": requested_down,
            "applied_speed_mps": applied_speed_mps,
            "applied_direction_deg": applied_direction_deg % 360.0,
            "applied_north_mps": applied_north,
            "applied_east_mps": applied_east,
            "applied_down_mps": applied_down,
            "sitl_applied": True,
            "cosys_applied": True,
            "cosys_readback": True,
            "applied_at_s": self.get_clock().now().nanoseconds / 1.0e9,
        }
        self.last_ack = ack
        self.pending_command_id = None
        self.publisher.publish(String(data=json.dumps(ack, sort_keys=True)))

    def _begin_cosys_apply(
        self,
        payload: dict[str, object],
        applied_speed_mps: float,
        applied_direction_deg: float,
    ) -> None:
        self._cosys_context = (payload, applied_speed_mps, applied_direction_deg)
        self._cosys_future = self._executor.submit(
            self._set_and_read_backends, applied_speed_mps, applied_direction_deg
        )

    def _poll_cosys(self) -> None:
        future = self._cosys_future
        if future is None or not future.done():
            return
        context = self._cosys_context
        self._cosys_future = None
        self._cosys_context = None
        if context is None:
            self.pending_command_id = None
            return
        payload, speed_mps, direction_deg = context
        try:
            applied_speed, applied_direction, applied = future.result()
        except Exception as exc:
            self.pending_command_id = None
            self.get_logger().error(f"Wind backend rejected command or readback: {exc}")
            return
        requested = speed_direction_to_ned(speed_mps, direction_deg)
        direction_error = abs(
            (applied_direction - direction_deg + 180.0) % 360.0 - 180.0
        )
        if (
            abs(applied_speed - speed_mps) > 0.02
            or direction_error > 0.5
            or not vector_matches(requested, applied)
        ):
            self.pending_command_id = None
            self.get_logger().error(
                "Wind readback mismatch: "
                f"requested={requested}, sitl=({applied_speed}, {applied_direction}), "
                f"cosys={applied}"
            )
            return
        self._publish_ack(
            payload,
            applied_speed_mps=applied_speed,
            applied_direction_deg=applied_direction,
            applied_vector=applied,
        )

    def _command(self, message: String) -> None:
        try:
            payload = self._decode(message)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            self.get_logger().error(f"Rejected malformed wind command: {exc}")
            return
        command_id = str(payload["command_id"])
        if self.last_ack and self.last_ack.get("command_id") == command_id:
            self.publisher.publish(String(data=json.dumps(self.last_ack, sort_keys=True)))
            return
        if self.pending_command_id is not None:
            if self.pending_command_id != command_id:
                self.get_logger().warning(
                    f"Wind command {command_id} waits for {self.pending_command_id}"
                )
            return
        self.pending_command_id = command_id
        self._begin_cosys_apply(
            payload,
            float(payload["speed_mps"]),
            float(payload["direction_deg"]),
        )

    def destroy_node(self) -> bool:
        self._executor.shutdown(wait=False, cancel_futures=True)
        return super().destroy_node()


def main() -> None:
    rclpy.init()
    node = WindDriver()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()
