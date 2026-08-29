"""Unit tests for canonical and VINS translation mission construction."""

import os
import socket

from demo_mission import (
    assert_process_alive,
    build_square_mission,
    command_ground_speed,
    read_parameter,
    recv_match_checked,
    validate_optional_ground_speed,
)
from pymavlink import mavutil
import pytest


def test_canonical_square_retains_seven_item_contract() -> None:
    mission = build_square_mission(
        50.318239,
        31.1372453,
        takeoff_m=5.0,
        side_m=15.0,
    )
    assert len(mission) == 7
    assert mission[1]["command"] == mavutil.mavlink.MAV_CMD_NAV_TAKEOFF
    assert mission[-1]["command"] == mavutil.mavlink.MAV_CMD_NAV_LAND


def test_vins_route_repeats_four_complete_laps_before_land() -> None:
    mission = build_square_mission(
        50.318239,
        31.1372453,
        takeoff_m=5.0,
        side_m=15.0,
        laps=4,
    )
    assert len(mission) == 19
    assert mission[2:6] == mission[6:10] == mission[10:14] == mission[14:18]
    assert mission[-1]["command"] == mavutil.mavlink.MAV_CMD_NAV_LAND


def test_vins_vertical_excitation_alternates_real_waypoint_altitudes() -> None:
    mission = build_square_mission(
        50.318239,
        31.1372453,
        takeoff_m=5.0,
        side_m=15.0,
        laps=2,
        altitude_step_m=3.0,
    )
    assert [item["rel_alt"] for item in mission[2:-1]] == [
        8.0, 5.0, 8.0, 5.0,
        8.0, 5.0, 8.0, 5.0,
    ]


def test_vins_fixed_yaw_keeps_all_flown_items_north_facing() -> None:
    mission = build_square_mission(
        50.318239,
        31.1372453,
        takeoff_m=5.0,
        side_m=15.0,
        laps=2,
        fixed_yaw_deg=1.0,
    )
    assert all(item["p4"] == 1.0 for item in mission[1:])


@pytest.mark.parametrize("fixed_yaw_deg", [-0.1, 360.0, float("nan"), float("inf")])
def test_invalid_fixed_yaw_is_rejected(fixed_yaw_deg) -> None:
    with pytest.raises(ValueError, match="fixed_yaw_deg"):
        build_square_mission(
            50.318239,
            31.1372453,
            takeoff_m=5.0,
            side_m=15.0,
            fixed_yaw_deg=fixed_yaw_deg,
        )


@pytest.mark.parametrize("laps", [0, -1, True, 1.5])
def test_invalid_lap_count_is_rejected(laps) -> None:
    with pytest.raises(ValueError, match="laps"):
        build_square_mission(
            50.318239,
            31.1372453,
            takeoff_m=5.0,
            side_m=15.0,
            laps=laps,
        )


@pytest.mark.parametrize("altitude_step_m", [-0.1, float("nan"), float("inf")])
def test_invalid_altitude_step_is_rejected(altitude_step_m) -> None:
    with pytest.raises(ValueError, match="altitude_step_m"):
        build_square_mission(
            50.318239,
            31.1372453,
            takeoff_m=5.0,
            side_m=15.0,
            altitude_step_m=altitude_step_m,
        )


@pytest.mark.parametrize("speed", [0.0, 0.75, 2.0])
def test_optional_ground_speed_accepts_disabled_or_positive_values(speed) -> None:
    assert validate_optional_ground_speed(speed, "test_speed") == speed


@pytest.mark.parametrize("speed", [-0.1, float("nan"), float("inf")])
def test_optional_ground_speed_rejects_invalid_values(speed) -> None:
    with pytest.raises(ValueError, match="test_speed"):
        validate_optional_ground_speed(speed, "test_speed")


def test_ground_speed_command_uses_mavlink_ground_speed_semantics(monkeypatch) -> None:
    calls = []

    def fake_send(master, command, params, timeout):
        calls.append((master, command, params, timeout))
        return object(), []

    monkeypatch.setattr("demo_mission.send_command", fake_send)
    command_ground_speed("master", 0.75, timeout=9.0)
    assert calls == [(
        "master",
        mavutil.mavlink.MAV_CMD_DO_CHANGE_SPEED,
        [1.0, 0.75, -1.0, 0.0],
        9.0,
    )]


def test_parameter_read_is_name_checked(monkeypatch) -> None:
    requests = []

    class FakeMav:
        def param_request_read_send(self, system, component, name, index):
            requests.append((system, component, name, index))

    class FakeMaster:
        target_system = 1
        target_component = 2
        mav = FakeMav()

    class Message:
        param_id = "WP_YAW_BEHAVIOR"
        param_value = 0.0

    monkeypatch.setattr("demo_mission.wait_message", lambda *args: Message())
    assert read_parameter(FakeMaster(), "WP_YAW_BEHAVIOR") == 0.0
    assert requests == [(1, 2, b"WP_YAW_BEHAVIOR", -1)]


def test_current_process_is_accepted_as_live(tmp_path) -> None:
    pid_file = tmp_path / "sitl.pid"
    pid_file.write_text(str(os.getpid()), encoding="utf-8")
    assert_process_alive(str(pid_file))


@pytest.mark.parametrize("contents", ["", "not-a-pid", "0", "999999999"])
def test_missing_or_dead_sitl_fails_closed(tmp_path, contents) -> None:
    pid_file = tmp_path / "sitl.pid"
    pid_file.write_text(contents, encoding="utf-8")
    with pytest.raises(RuntimeError, match="SITL is not alive"):
        assert_process_alive(str(pid_file))


def test_closed_mavlink_socket_fails_before_pymavlink_read() -> None:
    local, peer = socket.socketpair()
    peer.close()

    class FakeMaster:
        port = local

        def recv_match(self, **_kwargs):
            raise AssertionError("recv_match must not run on a closed socket")

    try:
        with pytest.raises(RuntimeError, match="TCP socket closed"):
            recv_match_checked(FakeMaster(), blocking=True, timeout=1.0)
    finally:
        local.close()
