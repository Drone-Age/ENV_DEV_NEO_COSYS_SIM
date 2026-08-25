#!/usr/bin/env python3
"""Pure camera-gimbal IMU frame transforms used by the Cosys ROS bridge."""

from __future__ import annotations

import math


def rotate_y(vector: tuple[float, float, float], angle_rad: float) -> tuple[float, float, float]:
    """Express an FLU body vector in a camera frame tilted down by angle_rad."""
    x, y, z = (float(value) for value in vector)
    cosine = math.cos(angle_rad)
    sine = math.sin(angle_rad)
    return cosine * x + sine * z, y, -sine * x + cosine * z


def quaternion_multiply(
    left: tuple[float, float, float, float],
    right: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    """Hamilton product for ROS-order (x, y, z, w) quaternions."""
    lx, ly, lz, lw = left
    rx, ry, rz, rw = right
    result = (
        lw * rx + lx * rw + ly * rz - lz * ry,
        lw * ry - lx * rz + ly * rw + lz * rx,
        lw * rz + lx * ry - ly * rx + lz * rw,
        lw * rw - lx * rx - ly * ry - lz * rz,
    )
    norm = math.sqrt(sum(value * value for value in result))
    if norm <= 0.0 or not math.isfinite(norm):
        raise ValueError("invalid gimbal quaternion")
    return tuple(value / norm for value in result)


def apply_gimbal_to_flu(
    body_orientation: tuple[float, float, float, float],
    body_angular_velocity: tuple[float, float, float],
    body_linear_acceleration: tuple[float, float, float],
    angle_rad: float,
    rate_rad_s: float,
) -> tuple[
    tuple[float, float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]:
    """Create a moving camera-IMU sample from the rigid body sample.

    iHUB angles are positive from forward to down. ROS FLU orientation therefore
    uses a negative pitch, while vectors expressed in that moving frame use the
    inverse positive-Y rotation. The servo rate is added about the camera Y axis.
    """
    values = (*body_orientation, *body_angular_velocity, *body_linear_acceleration,
              float(angle_rad), float(rate_rad_s))
    if not all(math.isfinite(value) for value in values):
        raise ValueError("gimbal IMU input must be finite")
    if not -0.05 <= angle_rad <= math.pi / 2.0 + 0.05:
        raise ValueError("gimbal angle is outside the supported 0-90 degree range")

    half = -0.5 * angle_rad
    body_to_camera = (0.0, math.sin(half), 0.0, math.cos(half))
    orientation = quaternion_multiply(body_orientation, body_to_camera)
    angular_velocity = rotate_y(body_angular_velocity, angle_rad)
    angular_velocity = (
        angular_velocity[0], angular_velocity[1] + rate_rad_s, angular_velocity[2]
    )
    acceleration = rotate_y(body_linear_acceleration, angle_rad)
    return orientation, angular_velocity, acceleration
