import math

import pytest

from vins_sim_bringup.wind_contract import (
    decode_wind_command,
    speed_direction_to_ned,
    vector_matches,
)


def command(**overrides):
    value = {
        "command_id": "climb-01-gust",
        "checkpoint": 1,
        "altitude_m": 10.0,
        "stage": "gust",
        "stage_kind": "gust",
        "speed_mps": 10.0,
        "direction_deg": 90.0,
    }
    value.update(overrides)
    return value


def test_decode_normalizes_direction():
    assert decode_wind_command(command(direction_deg=450.0))["direction_deg"] == 90.0


@pytest.mark.parametrize("speed", [-1.0, math.inf, math.nan])
def test_decode_rejects_invalid_speed(speed):
    with pytest.raises(ValueError):
        decode_wind_command(command(speed_mps=speed))


def test_ned_vector_uses_north_zero_and_east_ninety():
    north = speed_direction_to_ned(5.0, 0.0)
    east = speed_direction_to_ned(5.0, 90.0)
    assert north == pytest.approx((5.0, 0.0, 0.0), abs=1e-9)
    assert east == pytest.approx((0.0, 5.0, 0.0), abs=1e-9)


def test_readback_tolerance_is_fail_closed():
    assert vector_matches((1.0, 2.0, 0.0), (1.01, 1.99, 0.0))
    assert not vector_matches((1.0, 2.0, 0.0), (1.03, 2.0, 0.0))
