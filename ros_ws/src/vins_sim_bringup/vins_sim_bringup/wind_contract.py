"""Pure helpers for the checkpoint-synchronised wind contract."""

from __future__ import annotations

import math
from typing import Any, Mapping


STAGE_KINDS = {"baseline", "gust", "recovery"}


def decode_wind_command(payload: Mapping[str, Any]) -> dict[str, object]:
    command_id = str(payload["command_id"])
    checkpoint = int(payload["checkpoint"])
    altitude_m = float(payload["altitude_m"])
    stage = str(payload["stage"])
    stage_kind = str(payload.get("stage_kind", stage))
    speed_mps = float(payload["speed_mps"])
    direction_deg = float(payload["direction_deg"])
    if not command_id or len(command_id) > 96:
        raise ValueError("command_id must be non-empty and at most 96 characters")
    if checkpoint < 0 or not math.isfinite(altitude_m):
        raise ValueError("checkpoint and altitude must be valid")
    if (
        not stage
        or len(stage) > 48
        or any(not (character.isalnum() or character in "_-.") for character in stage)
    ):
        raise ValueError("wind stage ID must use 1..48 safe characters")
    if stage_kind not in STAGE_KINDS:
        raise ValueError(f"unsupported wind stage kind: {stage_kind}")
    if speed_mps < 0.0 or not math.isfinite(speed_mps):
        raise ValueError("wind speed must be finite and non-negative")
    if not math.isfinite(direction_deg):
        raise ValueError("wind direction must be finite")
    return {
        "command_id": command_id,
        "checkpoint": checkpoint,
        "altitude_m": altitude_m,
        "stage": stage,
        "stage_kind": stage_kind,
        "speed_mps": speed_mps,
        "direction_deg": direction_deg % 360.0,
    }


def speed_direction_to_ned(speed_mps: float, direction_deg: float) -> tuple[float, float, float]:
    radians = math.radians(direction_deg)
    return speed_mps * math.cos(radians), speed_mps * math.sin(radians), 0.0


def vector_matches(
    requested: tuple[float, float, float],
    applied: tuple[float, float, float],
    tolerance_mps: float = 0.02,
) -> bool:
    return all(abs(expected - actual) <= tolerance_mps for expected, actual in zip(requested, applied))
