"""Fail-closed validation helpers for simulator IMU samples."""

from __future__ import annotations

import math


def validate_imu_vectors(
    angular_velocity: tuple[float, float, float],
    linear_acceleration: tuple[float, float, float],
    *,
    max_angular_velocity_rad_s: float,
    max_linear_acceleration_m_s2: float,
) -> None:
    """Reject non-finite or physically implausible source samples."""
    values = (*angular_velocity, *linear_acceleration)
    if not all(math.isfinite(value) for value in values):
        raise ValueError("IMU vector contains a non-finite value")
    angular_norm = math.sqrt(sum(value * value for value in angular_velocity))
    acceleration_norm = math.sqrt(sum(value * value for value in linear_acceleration))
    if angular_norm > max_angular_velocity_rad_s:
        raise ValueError(
            f"IMU angular velocity norm {angular_norm:.3f} exceeds "
            f"{max_angular_velocity_rad_s:.3f} rad/s"
        )
    if acceleration_norm > max_linear_acceleration_m_s2:
        raise ValueError(
            f"IMU acceleration norm {acceleration_norm:.3f} exceeds "
            f"{max_linear_acceleration_m_s2:.3f} m/s^2"
        )
