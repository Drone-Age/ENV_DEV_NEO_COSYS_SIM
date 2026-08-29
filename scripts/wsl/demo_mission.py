#!/usr/bin/env python3
"""Canonical v0.1 Cosys-AirSim/ArduCopter acceptance mission."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import select
import socket
import sys
import time
import traceback
from datetime import datetime, timezone

from pymavlink import mavutil


def assert_process_alive(pid_file: str | None) -> None:
    """Fail closed when the supervised ArduCopter process disappears."""
    if not pid_file:
        return
    path = pathlib.Path(pid_file)
    try:
        raw = path.read_text(encoding="utf-8").strip()
        if not raw.isdigit() or int(raw) <= 0:
            raise ValueError("PID is not a positive integer")
        os.kill(int(raw), 0)
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"ArduCopter SITL is not alive ({path}): {exc}") from exc


def recv_match_checked(master, **kwargs):
    """Receive MAVLink without busy-spinning after the supervised peer dies."""
    assert_process_alive(getattr(master, "_indra_sitl_pid_file", None))
    port = getattr(master, "port", None)
    if isinstance(port, socket.socket):
        readable, _, _ = select.select([port], [], [], 0.0)
        if readable and port.recv(1, socket.MSG_PEEK) == b"":
            raise RuntimeError("ArduCopter MAVLink TCP socket closed")
    message = master.recv_match(**kwargs)
    if message is None:
        assert_process_alive(getattr(master, "_indra_sitl_pid_file", None))
        # pymavlink can return EOF immediately even for a blocking call.  A
        # short backoff keeps a disconnected test from flooding its evidence
        # bundle before the liveness check observes process termination.
        time.sleep(0.02)
    return message


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def offset_lat_lon(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    earth_radius = 6_378_137.0
    lat_out = lat + math.degrees(north_m / earth_radius)
    lon_out = lon + math.degrees(east_m / (earth_radius * math.cos(math.radians(lat))))
    return lat_out, lon_out


def build_square_mission(
    route_lat: float,
    route_lon: float,
    *,
    takeoff_m: float,
    side_m: float,
    laps: int = 1,
    altitude_step_m: float = 0.0,
    fixed_yaw_deg: float | None = None,
) -> list[dict]:
    """Build a home-relative square mission with optional vertical excitation."""

    if isinstance(laps, bool) or not isinstance(laps, int) or laps < 1:
        raise ValueError("laps must be an integer >= 1")
    altitude_step_m = float(altitude_step_m)
    if not math.isfinite(altitude_step_m) or altitude_step_m < 0.0:
        raise ValueError("altitude_step_m must be finite and >= 0")
    if fixed_yaw_deg is not None:
        fixed_yaw_deg = float(fixed_yaw_deg)
        if not math.isfinite(fixed_yaw_deg) or not 0.0 <= fixed_yaw_deg < 360.0:
            raise ValueError("fixed_yaw_deg must be finite in [0, 360)")
    offsets = [
        (side_m, 0.0),
        (side_m, side_m),
        (0.0, side_m),
        (0.0, 0.0),
    ]
    coordinates = [
        offset_lat_lon(route_lat, route_lon, north, east)
        for north, east in offsets
    ]
    # ArduPilot reserves mission sequence 0 for the home item. If TAKEOFF is
    # uploaded as seq 0 it is accepted by the protocol but AUTO later reports
    # "Missing Takeoff Cmd" because the item is not part of the flown mission.
    mission = [
        {
            "command": mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
            "lat": route_lat,
            "lon": route_lon,
            "rel_alt": 0.0,
            "p1": 0.0,
        },
        {
            "command": mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
            "lat": route_lat,
            "lon": route_lon,
            "rel_alt": takeoff_m,
            "p1": 0.0,
            **({"p4": fixed_yaw_deg} if fixed_yaw_deg is not None else {}),
        },
    ]
    for _ in range(laps):
        mission.extend(
            {
                "command": mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                "lat": lat,
                "lon": lon,
                # Alternating height is opt-in and reserved for VINS
                # qualification. It supplies real translational acceleration
                # to the camera/IMU pair; the canonical v0.1 square remains
                # exactly level when altitude_step_m is zero.
                "rel_alt": takeoff_m + (altitude_step_m if index % 2 == 0 else 0.0),
                "p1": 1.0,
                "p2": 2.0,
                **({"p4": fixed_yaw_deg} if fixed_yaw_deg is not None else {}),
            }
            for index, (lat, lon) in enumerate(coordinates)
        )
    mission.append(
        {
            "command": mavutil.mavlink.MAV_CMD_NAV_LAND,
            "lat": route_lat,
            "lon": route_lon,
            "rel_alt": 0.0,
            **({"p4": fixed_yaw_deg} if fixed_yaw_deg is not None else {}),
        }
    )
    return mission


def wait_message(master, types, deadline: float, condition=None):
    wanted = set(types if isinstance(types, (list, tuple, set)) else [types])
    while time.monotonic() < deadline:
        msg = recv_match_checked(master, type=list(wanted), blocking=True, timeout=min(1.0, max(0.0, deadline - time.monotonic())))
        if msg is not None and (condition is None or condition(msg)):
            return msg
    raise TimeoutError(f"timed out waiting for {sorted(wanted)}")


def send_command(master, command: int, params=None, timeout: float = 15.0):
    values = list(params or []) + [0.0] * 7
    master.mav.command_long_send(master.target_system, master.target_component, command, 0, *values[:7])
    deadline = time.monotonic() + timeout
    status_texts = []
    ack = None
    while time.monotonic() < deadline and ack is None:
        message = recv_match_checked(master, type=["COMMAND_ACK", "STATUSTEXT"], blocking=True, timeout=1.0)
        if message is None:
            continue
        if message.get_type() == "STATUSTEXT":
            status_texts.append(str(message.text))
        elif int(message.command) == command:
            ack = message
    if ack is None:
        raise TimeoutError(f"command {command} was not acknowledged")
    accepted = {mavutil.mavlink.MAV_RESULT_ACCEPTED, mavutil.mavlink.MAV_RESULT_IN_PROGRESS}
    if ack.result not in accepted:
        detail_deadline = time.monotonic() + 2.0
        while time.monotonic() < detail_deadline:
            message = recv_match_checked(master, type="STATUSTEXT", blocking=True, timeout=0.25)
            if message is not None:
                status_texts.append(str(message.text))
        details = "; ".join(status_texts[-5:]) or "no STATUSTEXT received"
        raise RuntimeError(f"command {command} rejected ({ack.to_dict()}): {details}")
    return ack, status_texts


def validate_optional_ground_speed(value: float, name: str) -> float:
    speed = float(value)
    if not math.isfinite(speed) or speed < 0.0:
        raise ValueError(f"{name} must be finite and >= 0")
    return speed


def command_ground_speed(master, speed_m_s: float, timeout: float = 15.0):
    speed = validate_optional_ground_speed(speed_m_s, "ground speed")
    if speed <= 0.0:
        raise ValueError("ground speed command must be > 0")
    return send_command(
        master,
        mavutil.mavlink.MAV_CMD_DO_CHANGE_SPEED,
        [1.0, speed, -1.0, 0.0],
        timeout=timeout,
    )


def request_message_interval(master, message_id: int, interval_us: int) -> None:
    master.mav.command_long_send(
        master.target_system,
        master.target_component,
        mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL,
        0,
        message_id,
        interval_us,
        0,
        0,
        0,
        0,
        0,
    )


def read_parameter(master, name: str, timeout: float = 10.0) -> float:
    encoded = name.encode("ascii")
    master.mav.param_request_read_send(
        master.target_system,
        master.target_component,
        encoded,
        -1,
    )

    def matches(message) -> bool:
        param_id = message.param_id
        if isinstance(param_id, bytes):
            param_id = param_id.decode("ascii", errors="replace")
        return str(param_id).rstrip("\x00") == name

    message = wait_message(
        master,
        "PARAM_VALUE",
        time.monotonic() + timeout,
        matches,
    )
    value = float(message.param_value)
    if not math.isfinite(value):
        raise RuntimeError(f"parameter {name} is not finite")
    return value


def set_mode_verified(master, mode_name: str, timeout: float = 20.0):
    mode_map = master.mode_mapping()
    if mode_map is None or mode_name not in mode_map:
        raise RuntimeError(f"autopilot does not advertise mode {mode_name}")
    custom_mode = int(mode_map[mode_name])
    ack, status_texts = send_command(
        master,
        mavutil.mavlink.MAV_CMD_DO_SET_MODE,
        [mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, custom_mode],
        timeout=timeout,
    )
    heartbeat = wait_message(
        master,
        "HEARTBEAT",
        time.monotonic() + timeout,
        lambda m: int(m.custom_mode) == custom_mode,
    )
    return heartbeat, ack, status_texts


def upload_mission(master, items: list[dict], timeout: float = 30.0) -> None:
    master.mav.mission_clear_all_send(master.target_system, master.target_component)
    master.mav.mission_count_send(master.target_system, master.target_component, len(items), mavutil.mavlink.MAV_MISSION_TYPE_MISSION)
    pending = set(range(len(items)))
    deadline = time.monotonic() + timeout
    while pending:
        request = wait_message(master, ["MISSION_REQUEST_INT", "MISSION_REQUEST"], deadline)
        seq = int(request.seq)
        if seq not in range(len(items)):
            raise RuntimeError(f"flight controller requested invalid mission item {seq}")
        item = items[seq]
        master.mav.mission_item_int_send(
            master.target_system,
            master.target_component,
            seq,
            mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT_INT,
            item["command"],
            1 if seq == 0 else 0,
            1,
            item.get("p1", 0.0),
            item.get("p2", 0.0),
            item.get("p3", 0.0),
            item.get("p4", float("nan")),
            int(round(item["lat"] * 1e7)),
            int(round(item["lon"] * 1e7)),
            float(item["rel_alt"]),
            mavutil.mavlink.MAV_MISSION_TYPE_MISSION,
        )
        pending.discard(seq)
    ack = wait_message(master, "MISSION_ACK", deadline)
    if ack.type != mavutil.mavlink.MAV_MISSION_ACCEPTED:
        raise RuntimeError(f"mission upload rejected with type {ack.type}")


def collect_parameters(master, output_dir: pathlib.Path, seconds: float = 12.0) -> int:
    master.mav.param_request_list_send(master.target_system, master.target_component)
    deadline = time.monotonic() + seconds
    params: dict[str, float] = {}
    expected = None
    while time.monotonic() < deadline:
        msg = recv_match_checked(master, type="PARAM_VALUE", blocking=True, timeout=0.5)
        if msg is None:
            continue
        name = msg.param_id
        if isinstance(name, bytes):
            name = name.decode("ascii", errors="replace")
        params[str(name).rstrip("\x00")] = float(msg.param_value)
        expected = int(msg.param_count)
        if expected > 0 and len(params) >= expected:
            break
    (output_dir / "parameters.json").write_text(json.dumps({"received": len(params), "expected": expected, "values": params}, indent=2, sort_keys=True), encoding="utf-8")
    return len(params)


def run(args) -> dict:
    started = time.monotonic()
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    events = []
    initial_ground_speed = validate_optional_ground_speed(
        args.initial_ground_speed, "initial_ground_speed"
    )
    cruise_ground_speed = validate_optional_ground_speed(
        args.cruise_ground_speed, "cruise_ground_speed"
    )
    if bool(initial_ground_speed) != bool(cruise_ground_speed):
        raise ValueError(
            "initial_ground_speed and cruise_ground_speed must be enabled together"
        )
    gates = {
        "mavlink_heartbeat": False,
        "sensor_exchange": False,
        "ekf_healthy": False,
        "prearm_ready": False,
        "home_ready": False,
        "position_ready": False,
        "armed": False,
        "all_waypoints_reached": False,
        "landed": False,
        "disarmed": False,
    }

    assert_process_alive(args.sitl_pid_file)

    def event(name: str, **details):
        record = {"time": utc_now(), "elapsed_s": round(time.monotonic() - started, 3), "event": name, **details}
        events.append(record)
        print(json.dumps(record), flush=True)

    connection_deadline = time.monotonic() + 60
    master = None
    while time.monotonic() < connection_deadline and master is None:
        try:
            master = mavutil.mavlink_connection(args.connect, source_system=250, autoreconnect=False)
            master._indra_sitl_pid_file = args.sitl_pid_file
        except (ConnectionRefusedError, OSError):
            if master is not None:
                try:
                    master.close()
                except Exception:
                    pass
            master = None
            time.sleep(1)
    if master is None:
        raise TimeoutError("MAVLink TCP connection not established")
    heartbeat = master.wait_heartbeat(timeout=max(1, connection_deadline - time.monotonic()))
    if heartbeat is None:
        raise TimeoutError("MAVLink heartbeat not received")
    gates["mavlink_heartbeat"] = True
    event("heartbeat", system=master.target_system, component=master.target_component)

    master.mav.request_data_stream_send(master.target_system, master.target_component, mavutil.mavlink.MAV_DATA_STREAM_ALL, 10, 1)
    wait_message(master, ["HIL_STATE", "GLOBAL_POSITION_INT", "ATTITUDE"], time.monotonic() + 30)
    gates["sensor_exchange"] = True
    event("sensor_exchange")

    required_estimator = (
        mavutil.mavlink.EKF_ATTITUDE
        | mavutil.mavlink.EKF_VELOCITY_HORIZ
        | mavutil.mavlink.EKF_POS_HORIZ_ABS
        | mavutil.mavlink.EKF_POS_VERT_ABS
    )
    required_health = (
        mavutil.mavlink.MAV_SYS_STATUS_SENSOR_3D_GYRO
        | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_3D_ACCEL
        | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_3D_MAG
        | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_GPS
        | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_ATTITUDE_STABILIZATION
    )

    def estimator_is_healthy(message) -> bool:
        message_type = message.get_type()
        if message_type in {"EKF_STATUS_REPORT", "ESTIMATOR_STATUS"}:
            return (int(message.flags) & required_estimator) == required_estimator
        if message_type == "SYS_STATUS":
            present = int(message.onboard_control_sensors_present)
            enabled = int(message.onboard_control_sensors_enabled)
            healthy = int(message.onboard_control_sensors_health)
            return all((bits & required_health) == required_health for bits in (present, enabled, healthy))
        return False

    request_message_interval(master, mavutil.mavlink.MAVLINK_MSG_ID_EKF_STATUS_REPORT, 200000)
    request_message_interval(master, mavutil.mavlink.MAVLINK_MSG_ID_SYS_STATUS, 200000)
    ekf = wait_message(
        master,
        ["EKF_STATUS_REPORT", "SYS_STATUS"],
        time.monotonic() + 60,
        estimator_is_healthy,
    )
    gates["ekf_healthy"] = True
    event("ekf_healthy", source=ekf.get_type(), flags=int(getattr(ekf, "flags", getattr(ekf, "onboard_control_sensors_health", 0))))

    prearm = wait_message(
        master,
        "SYS_STATUS",
        time.monotonic() + 60,
        lambda m: bool(int(m.onboard_control_sensors_health) & mavutil.mavlink.MAV_SYS_STATUS_PREARM_CHECK),
    )
    gates["prearm_ready"] = True
    event("prearm_ready", health=int(prearm.onboard_control_sensors_health))

    request_message_interval(master, mavutil.mavlink.MAVLINK_MSG_ID_HOME_POSITION, 500000)
    home = wait_message(
        master,
        "HOME_POSITION",
        time.monotonic() + 60,
        lambda m: int(m.latitude) != 0 and int(m.longitude) != 0,
    )
    gates["home_ready"] = True
    event("home_ready", latitude=int(home.latitude), longitude=int(home.longitude), altitude_mm=int(home.altitude))

    request_message_interval(master, mavutil.mavlink.MAVLINK_MSG_ID_GPS_RAW_INT, 200000)
    gps = wait_message(
        master,
        "GPS_RAW_INT",
        time.monotonic() + 60,
        lambda m: int(m.fix_type) >= 3 and int(m.satellites_visible) >= 6,
    )
    event("gps_ready", fix_type=int(gps.fix_type), satellites=int(gps.satellites_visible))

    if args.required_wp_yaw_behavior is not None:
        yaw_behavior = read_parameter(master, "WP_YAW_BEHAVIOR")
        if abs(yaw_behavior - args.required_wp_yaw_behavior) > 1.0e-6:
            raise RuntimeError(
                "WP_YAW_BEHAVIOR does not match the required qualification value: "
                f"actual={yaw_behavior} required={args.required_wp_yaw_behavior}"
            )
        event("wp_yaw_behavior_verified", value=yaw_behavior)

    prearm = wait_message(
        master,
        "SYS_STATUS",
        time.monotonic() + 30,
        lambda m: bool(int(m.onboard_control_sensors_health) & mavutil.mavlink.MAV_SYS_STATUS_PREARM_CHECK),
    )
    event("prearm_revalidated", health=int(prearm.onboard_control_sensors_health))

    # The profile origin georeferences the Unreal world; it is not necessarily
    # the vehicle's PlayerStart.  Build local qualification routes around the
    # HOME_POSITION reported by ArduPilot so TAKEOFF and LAND use the same flat
    # patch of terrain.  Using the profile origin here can silently move LAND
    # tens of metres away from the actual launch point in another UE map.
    route_lat = int(home.latitude) / 1.0e7
    route_lon = int(home.longitude) / 1.0e7
    event(
        "mission_origin",
        source="HOME_POSITION",
        latitude=route_lat,
        longitude=route_lon,
        profile_latitude=args.lat,
        profile_longitude=args.lon,
    )

    mission = build_square_mission(
        route_lat,
        route_lon,
        takeoff_m=args.takeoff,
        side_m=args.side,
        laps=args.laps,
        altitude_step_m=args.altitude_step,
        fixed_yaw_deg=args.fixed_yaw_deg,
    )
    required_reached = set(range(1, len(mission) - 1))
    (output_path.parent / "mission.json").write_text(json.dumps(mission, indent=2), encoding="utf-8")
    upload_mission(master, mission)
    event(
        "mission_uploaded",
        items=len(mission),
        laps=args.laps,
        altitude_step_m=args.altitude_step,
        fixed_yaw_deg=args.fixed_yaw_deg,
    )

    _, prearm_messages = send_command(master, mavutil.mavlink.MAV_CMD_RUN_PREARM_CHECKS)
    event("prearm_checks", messages=prearm_messages)

    _, _, guided_messages = set_mode_verified(master, "GUIDED")
    event("guided_ready", messages=guided_messages)
    arm_deadline = time.monotonic() + 120
    arm_attempt = 0
    while True:
        arm_attempt += 1
        try:
            _, arm_messages = send_command(
                master,
                mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
                [1.0],
                timeout=10.0,
            )
            event("arm_accepted", attempt=arm_attempt, messages=arm_messages)
            break
        except RuntimeError as exc:
            detail = str(exc)
            transient = any(
                text in detail
                for text in (
                    "Need Position Estimate",
                    "Gyros still settling",
                    "EKF3 still initialising",
                    "GPS 1: not healthy",
                )
            )
            if not transient or time.monotonic() >= arm_deadline:
                raise
            event("arm_retry", attempt=arm_attempt, reason=detail)
            time.sleep(5)
    wait_message(
        master,
        "HEARTBEAT",
        time.monotonic() + 30,
        lambda m: bool(m.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED),
    )
    gates["armed"] = True
    gates["position_ready"] = True
    event("armed")

    speed_restore_pending = False
    if initial_ground_speed > 0.0:
        _, speed_messages = command_ground_speed(master, initial_ground_speed)
        speed_restore_pending = True
        event(
            "initial_ground_speed_commanded",
            speed_m_s=initial_ground_speed,
            messages=speed_messages,
        )

    _, _, auto_messages = set_mode_verified(master, "AUTO")
    event("auto_started", messages=auto_messages)
    # In a GCS-only launch the RC throttle remains at minimum. Explicitly start
    # the mission so ArduCopter releases its normal ground takeoff interlock;
    # this is the MAVLink equivalent of Mission Planner's Start Mission action.
    _, mission_start_messages = send_command(
        master,
        mavutil.mavlink.MAV_CMD_MISSION_START,
        [0.0, 0.0],
    )
    event("mission_started", messages=mission_start_messages)

    reached = set()
    deadline = time.monotonic() + args.timeout
    max_alt_m = 0.0
    last_position_time = time.monotonic()
    while time.monotonic() < deadline:
        msg = recv_match_checked(master, type=["MISSION_ITEM_REACHED", "GLOBAL_POSITION_INT", "HEARTBEAT", "STATUSTEXT"], blocking=True, timeout=1.0)
        if msg is None:
            if time.monotonic() - last_position_time > 10:
                raise TimeoutError("telemetry position stream stalled")
            continue
        msg_type = msg.get_type()
        if msg_type == "GLOBAL_POSITION_INT":
            last_position_time = time.monotonic()
            max_alt_m = max(max_alt_m, msg.relative_alt / 1000.0)
        elif msg_type == "MISSION_ITEM_REACHED":
            reached.add(int(msg.seq))
            event("mission_item_reached", seq=int(msg.seq))
            if speed_restore_pending and int(msg.seq) >= 2:
                _, speed_messages = command_ground_speed(master, cruise_ground_speed)
                speed_restore_pending = False
                event(
                    "cruise_ground_speed_restored",
                    speed_m_s=cruise_ground_speed,
                    messages=speed_messages,
                )
        elif msg_type == "STATUSTEXT":
            event("statustext", severity=int(msg.severity), text=str(msg.text))
        elif msg_type == "HEARTBEAT" and not (msg.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED):
            if required_reached.issubset(reached):
                gates["all_waypoints_reached"] = True
                gates["landed"] = True
                gates["disarmed"] = True
                event("landed_disarmed", max_alt_m=round(max_alt_m, 2))
                break
    if not gates["disarmed"]:
        raise TimeoutError(f"mission did not land and disarm within {args.timeout}s; reached={sorted(reached)}")

    count = collect_parameters(master, output_path.parent)
    event("parameters_captured", count=count)

    return {
        "schema": 1,
        "verdict": "PASS" if all(gates.values()) else "FAIL",
        "started_at": events[0]["time"],
        "completed_at": utc_now(),
        "duration_s": round(time.monotonic() - started, 3),
        "connection": args.connect,
        "gates": gates,
        "mission_items": len(mission),
        "reached": sorted(reached),
        "events": events,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--connect", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--sitl-pid-file")
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    parser.add_argument("--alt", type=float, required=True)
    parser.add_argument("--takeoff", type=float, default=5.0)
    parser.add_argument("--side", type=float, default=15.0)
    parser.add_argument("--laps", type=int, default=1)
    parser.add_argument("--altitude-step", type=float, default=0.0)
    parser.add_argument("--fixed-yaw-deg", type=float)
    parser.add_argument("--required-wp-yaw-behavior", type=float)
    parser.add_argument("--initial-ground-speed", type=float, default=0.0)
    parser.add_argument("--cruise-ground-speed", type=float, default=0.0)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    output = pathlib.Path(args.output)
    try:
        result = run(args)
        output.write_text(json.dumps(result, indent=2), encoding="utf-8")
        return 0 if result["verdict"] == "PASS" else 1
    except Exception as exc:
        failure = {"schema": 1, "verdict": "FAIL", "completed_at": utc_now(), "error": f"{type(exc).__name__}: {exc}"}
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(failure, indent=2), encoding="utf-8")
        traceback.print_exc(file=sys.stderr)
        print(json.dumps(failure), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
