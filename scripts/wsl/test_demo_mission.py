"""Unit tests for canonical and VINS translation mission construction."""

import os
import socket

from demo_mission import assert_process_alive, build_square_mission, recv_match_checked
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
