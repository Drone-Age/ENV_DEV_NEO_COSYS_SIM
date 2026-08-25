"""Apply checkpoint-synchronised wind to both ArduPilot SITL and Cosys physics."""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor
import json
import math

import cosysairsim
from mavros_msgs.srv import ParamSetV2
import rclpy
from rcl_interfaces.msg import ParameterType, ParameterValue
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
        self.cosys_host = str(self.get_parameter("cosys_host").value)
        self.cosys_port = int(self.get_parameter("cosys_port").value)
        self.cosys_timeout_s = float(self.get_parameter("cosys_timeout_s").value)
        self.client = self.create_client(ParamSetV2, "/mavros/param/set")
        self.publisher = self.create_publisher(String, self.TRUTH_TOPIC, 10)
        self.create_subscription(String, self.COMMAND_TOPIC, self._command, 10)
        self.pending_command_id: str | None = None
        self.last_ack: dict[str, object] | None = None
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cosys-wind")
        self._cosys_future: Future[tuple[float, float, float]] | None = None
        self._cosys_context: tuple[dict[str, object], float, float] | None = None
        self.create_timer(0.05, self._poll_cosys)

    @staticmethod
    def _request(name: str, value: float) -> ParamSetV2.Request:
        request = ParamSetV2.Request()
        request.force_set = True
        request.param_id = name
        request.value = ParameterValue(
            type=ParameterType.PARAMETER_DOUBLE,
            double_value=float(value),
        )
        return request

    @classmethod
    def _decode(cls, message: String) -> dict[str, object]:
        return decode_wind_command(json.loads(message.data))

    def _set_and_read_cosys(self, wind: tuple[float, float, float]) -> tuple[float, float, float]:
        client = cosysairsim.MultirotorClient(
            ip=self.cosys_host,
            port=self.cosys_port,
            timeout_value=self.cosys_timeout_s,
        )
        requested = cosysairsim.Vector3r(*wind)
        client.simSetWind(requested)
        applied = client.simGetWind()
        return float(applied.x_val), float(applied.y_val), float(applied.z_val)

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
        wind = speed_direction_to_ned(applied_speed_mps, applied_direction_deg)
        self._cosys_context = (payload, applied_speed_mps, applied_direction_deg)
        self._cosys_future = self._executor.submit(self._set_and_read_cosys, wind)

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
        requested = speed_direction_to_ned(speed_mps, direction_deg)
        try:
            applied = future.result()
        except Exception as exc:
            self.pending_command_id = None
            self.get_logger().error(f"Cosys rejected wind command or readback: {exc}")
            return
        if not vector_matches(requested, applied):
            self.pending_command_id = None
            self.get_logger().error(
                f"Cosys wind readback mismatch: requested={requested}, applied={applied}"
            )
            return
        self._publish_ack(
            payload,
            applied_speed_mps=math.hypot(applied[0], applied[1]),
            applied_direction_deg=math.degrees(math.atan2(applied[1], applied[0])),
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
        if not self.client.service_is_ready():
            self.get_logger().warning("SITL parameter service is not ready for wind command")
            return

        self.pending_command_id = command_id
        speed_future = self.client.call_async(
            self._request("SIM_WIND_SPD", float(payload["speed_mps"]))
        )
        direction_future = self.client.call_async(
            self._request("SIM_WIND_DIR", float(payload["direction_deg"]))
        )
        started = False

        def apply_to_cosys_when_sitl_acknowledges(_future) -> None:
            nonlocal started
            if started or not speed_future.done() or not direction_future.done():
                return
            try:
                speed_result = speed_future.result()
                direction_result = direction_future.result()
            except Exception as exc:
                self.pending_command_id = None
                self.get_logger().error(f"Wind parameter request failed: {exc}")
                return
            if not speed_result.success or not direction_result.success:
                self.pending_command_id = None
                self.get_logger().error("SITL rejected checkpoint wind command")
                return
            started = True
            self._begin_cosys_apply(
                payload,
                float(speed_result.value.double_value),
                float(direction_result.value.double_value),
            )

        speed_future.add_done_callback(apply_to_cosys_when_sitl_acknowledges)
        direction_future.add_done_callback(apply_to_cosys_when_sitl_acknowledges)

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
