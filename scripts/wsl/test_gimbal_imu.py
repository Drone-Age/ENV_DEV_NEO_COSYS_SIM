import math

import pytest

from gimbal_imu import apply_gimbal_to_flu, rotate_y, sample_gimbal_history
from imu_validation import validate_imu_vectors


def test_physical_imu_limits_accept_nominal_flight_sample():
    validate_imu_vectors(
        (0.1, -0.2, 0.3),
        (0.0, 0.0, 9.81),
        max_angular_velocity_rad_s=35.0,
        max_linear_acceleration_m_s2=200.0,
    )


@pytest.mark.parametrize(
    ("angular", "acceleration", "message"),
    [
        ((float("nan"), 0.0, 0.0), (0.0, 0.0, 9.81), "non-finite"),
        ((36.0, 0.0, 0.0), (0.0, 0.0, 9.81), "angular velocity"),
        ((0.0, 0.0, 0.0), (201.0, 0.0, 0.0), "acceleration norm"),
    ],
)
def test_physical_imu_limits_reject_corrupt_samples(angular, acceleration, message):
    with pytest.raises(ValueError, match=message):
        validate_imu_vectors(
            angular,
            acceleration,
            max_angular_velocity_rad_s=35.0,
            max_linear_acceleration_m_s2=200.0,
        )


def test_gimbal_history_interpolates_at_sensor_timestamp():
    history = [
        (1_000_000_000, 0.0, 1.0),
        (1_100_000_000, 0.1, 1.0),
    ]

    assert sample_gimbal_history(history, 1_050_000_000) == pytest.approx((0.05, 1.0))


def test_gimbal_history_bounds_short_extrapolation_and_holds_when_stale():
    history = [(1_000_000_000, 1.5, 1.0)]

    assert sample_gimbal_history(history, 1_100_000_000) == pytest.approx(
        (math.pi / 2.0, 1.0)
    )
    assert sample_gimbal_history(history, 1_300_000_000) == pytest.approx((1.5, 0.0))


def test_down_camera_matches_ihub_calibration_gravity_geometry():
    orientation, angular, acceleration = apply_gimbal_to_flu(
        (0.0, 0.0, 0.0, 1.0),
        (0.0, 0.0, 0.0),
        (0.0, 0.0, 9.81),
        math.pi / 2.0,
        0.0,
    )

    # At rest, FLU specific force is +Z. A camera whose +X optical mount points
    # down observes that vector on its -X axis.
    assert acceleration == pytest.approx((-9.81, 0.0, 0.0), abs=1.0e-9)
    assert angular == pytest.approx((0.0, 0.0, 0.0))
    assert orientation == pytest.approx(
        (0.0, math.sqrt(0.5), 0.0, math.sqrt(0.5))
    )


def test_servo_rate_is_visible_on_camera_y_axis():
    _orientation, angular, _acceleration = apply_gimbal_to_flu(
        (0.0, 0.0, 0.0, 1.0),
        (0.1, 0.2, 0.3),
        (1.0, 2.0, 3.0),
        math.pi / 4.0,
        1.5,
    )

    rotated = rotate_y((0.1, 0.2, 0.3), -math.pi / 4.0)
    assert angular == pytest.approx((rotated[0], rotated[1] + 1.5, rotated[2]))


@pytest.mark.parametrize("angle", [-0.2, math.pi])
def test_unsafe_angle_is_rejected(angle):
    with pytest.raises(ValueError, match="0-90"):
        apply_gimbal_to_flu(
            (0.0, 0.0, 0.0, 1.0),
            (0.0, 0.0, 0.0),
            (0.0, 0.0, 9.81),
            angle,
            0.0,
        )
