import math

import pytest

from gimbal_imu import apply_gimbal_to_flu, rotate_y


def test_down_camera_matches_ihub_calibration_gravity_geometry():
    orientation, angular, acceleration = apply_gimbal_to_flu(
        (0.0, 0.0, 0.0, 1.0),
        (0.0, 0.0, 0.0),
        (0.0, 0.0, 9.81),
        math.pi / 2.0,
        0.0,
    )

    assert acceleration == pytest.approx((9.81, 0.0, 0.0), abs=1.0e-9)
    assert angular == pytest.approx((0.0, 0.0, 0.0))
    assert orientation == pytest.approx(
        (0.0, -math.sqrt(0.5), 0.0, math.sqrt(0.5))
    )


def test_servo_rate_is_visible_on_camera_y_axis():
    _orientation, angular, _acceleration = apply_gimbal_to_flu(
        (0.0, 0.0, 0.0, 1.0),
        (0.1, 0.2, 0.3),
        (1.0, 2.0, 3.0),
        math.pi / 4.0,
        1.5,
    )

    rotated = rotate_y((0.1, 0.2, 0.3), math.pi / 4.0)
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
