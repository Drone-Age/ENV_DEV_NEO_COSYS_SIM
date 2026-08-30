import importlib.util
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).with_name("wind_probe.py")
SPEC = importlib.util.spec_from_file_location("wind_probe", MODULE_PATH)
wind_probe = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(wind_probe)


def command(speed=5.0, direction=0.0):
    return {
        "command_id": "probe-baseline",
        "speed_mps": speed,
        "direction_deg": direction,
    }


def ack(**overrides):
    payload = {
        "command_id": "probe-baseline",
        "sitl_applied": True,
        "cosys_applied": True,
        "cosys_readback": True,
        "applied_speed_mps": 5.0,
        "applied_direction_deg": 0.0,
    }
    payload.update(overrides)
    return payload


def test_accepts_correlated_dual_backend_readback():
    wind_probe.validate_ack(command(), ack())


@pytest.mark.parametrize("field", ["sitl_applied", "cosys_applied", "cosys_readback"])
def test_rejects_missing_backend_proof(field):
    with pytest.raises(ValueError):
        wind_probe.validate_ack(command(), ack(**{field: False}))


def test_direction_comparison_wraps_at_north():
    wind_probe.validate_ack(command(direction=359.9), ack(applied_direction_deg=0.1))


def test_rejects_wrong_command_id():
    with pytest.raises(ValueError):
        wind_probe.validate_ack(command(), ack(command_id="different"))
