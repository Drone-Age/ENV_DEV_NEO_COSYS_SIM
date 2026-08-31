import math
from pathlib import Path

import pytest

from vins_sim_bringup.wind_contract import (
    decode_wind_command,
    speed_direction_to_ned,
    vector_matches,
)


def test_wind_runtime_uses_an_isolated_mavlink_port_without_mavros_param_collision():
    package = Path(__file__).parents[1]
    plugins = (package / "config" / "mavros_plugins.yaml").read_text(encoding="utf-8")
    launch = (package / "launch" / "vins_stack.launch.py").read_text(encoding="utf-8")
    driver = (package / "vins_sim_bringup" / "wind_driver.py").read_text(
        encoding="utf-8"
    )
    assert "      - param\n" not in plugins
    assert 'DeclareLaunchArgument("wind_mavlink_url"' in launch
    assert '"mavlink_url": LaunchConfiguration("wind_mavlink_url")' in launch
    assert "from pymavlink import mavutil" in driver
    assert "param_set_send(" in driver
    assert 'type="PARAM_VALUE"' in driver
    assert "create_client(ParamSetV2" not in driver


def test_news_sim_initializer_requires_a_near_metric_solution():
    package = Path(__file__).parents[1]
    launch = (package / "launch" / "vins_stack.launch.py").read_text(
        encoding="utf-8"
    )
    assert '"vins.minimum_metric_scale": 0.5' in launch
    assert '"vins.minimum_feature_depth_mean_m": 100.0' in launch
    assert '"vins.maximum_feature_depth_mean_m": 500.0' in launch


def test_camera_benchmark_passes_the_isolated_wind_port_to_sitl():
    repository = Path(__file__).parents[4]
    launcher = (repository / "scripts" / "camera-benchmark.ps1").read_text(
        encoding="utf-8"
    )
    assert "'$($script:Config.ports.wind_mavlink_tcp)'" in launcher


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
