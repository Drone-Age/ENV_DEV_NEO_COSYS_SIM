#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 13 ]]; then
    echo "usage: vins_flight_qualification.sh <repo-root> <run-dir> <domain-id> <controller-port> <lat> <lon> <origin-alt> <takeoff-m> <side-m> <mission-timeout-s> <probe-timeout-s> <ready-timeout-s> <installed|source>" >&2
    exit 64
fi

repo_root=$1
run_dir=$2
domain_id=$3
controller_port=$4
latitude=$5
longitude=$6
origin_altitude=$7
takeoff_m=$8
side_m=$9
mission_timeout_s=${10}
probe_timeout_s=${11}
ready_timeout_s=${12}
runtime_mode=${13}
vins_dir="$run_dir/vins"
probe_result="$vins_dir/runtime-probe.json"
probe_process_log="$vins_dir/runtime-probe.process.log"
mission_result="$vins_dir/qualification-mission.json"
mission_log="$vins_dir/qualification-mission.log"
recovery_result="$vins_dir/qualification-recovery-mission.json"
recovery_log="$vins_dir/qualification-recovery-mission.log"

mkdir -p "$vins_dir"
if [[ -f /opt/iros2j/setup.bash ]]; then
    set +u
    source /opt/iros2j/setup.bash
    set -u
elif [[ -f /opt/ros/jazzy/setup.bash ]]; then
    set +u
    source /opt/ros/jazzy/setup.bash
    set -u
else
    echo "ROS 2 Jazzy setup was not found" >&2
    exit 66
fi
runtime_root="${INDRA_VINS_RUNTIME_ROOT:-$HOME/.local/share/indra-cosys}"
case "$runtime_mode" in
    installed) overlay_root="$runtime_root/ivins-adapter-overlay-jazzy" ;;
    source) overlay_root="$runtime_root/vins-overlay-jazzy" ;;
    *) echo "invalid IVINS runtime mode: $runtime_mode" >&2; exit 64 ;;
esac
set +u
source "$overlay_root/install/setup.bash"
set -u
export ROS_DOMAIN_ID="$domain_id"

python_bin="$HOME/venv-ardupilot/bin/python3"
probe="$repo_root/scripts/wsl/vins_runtime_probe.py"
controller="$repo_root/scripts/wsl/demo_mission.py"

"$python_bin" "$probe" \
    --timeout "$probe_timeout_s" \
    --output "$probe_result" \
    --completion-file "$mission_result" \
    >"$probe_process_log" 2>&1 &
probe_pid=$!

cleanup() {
    if kill -0 "$probe_pid" 2>/dev/null; then
        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Calibration must happen while the vehicle is stationary.  Start the flight
# only after the probe has observed both a healthy calibrated iHUB and the
# complete 0..90 degree sweep.  The flight then supplies the translational
# parallax that monocular metric-scale initialization cannot obtain from a
# gimbal-only rotation.
ready_deadline=$((SECONDS + ready_timeout_s))
ready=0
while (( SECONDS < ready_deadline )); do
    if [[ -s $probe_result ]] && "$python_bin" - "$probe_result" <<'PY'
import json
import sys

try:
    gates = json.load(open(sys.argv[1], encoding="utf-8"))["gates"]
except (OSError, KeyError, TypeError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if gates.get("ihub_ready") and gates.get("gimbal_sweep") else 1)
PY
    then
        ready=1
        break
    fi
    if ! kill -0 "$probe_pid" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if (( ready == 0 )); then
    echo "VINS_PREFLIGHT_GATE_FAIL iHUB calibration/full sweep was not observed" >&2
    [[ -s $probe_result ]] && cat "$probe_result"
    exit 70
fi

echo "VINS_PREFLIGHT_GATE_PASS calibrated iHUB and full sweep observed"
# ArduPilot treats an exact zero waypoint yaw as an unspecified sentinel.
# One degree is an explicit, effectively north-facing fixed heading.
set +e
timeout --signal=TERM --kill-after=10 "$((mission_timeout_s + 30))" \
    "$python_bin" "$controller" \
    --connect "tcp:127.0.0.1:$controller_port" \
    --output "$mission_result" \
    --sitl-pid-file "$run_dir/sitl/sitl.pid" \
    --lat "$latitude" --lon "$longitude" --alt "$origin_altitude" \
    --takeoff "$takeoff_m" --side "$side_m" --laps 2 --altitude-step 3 \
    --fixed-yaw-deg 1.0 \
    --required-wp-yaw-behavior 0.0 \
    --initial-ground-speed 0.75 --cruise-ground-speed 2.0 \
    --timeout "$mission_timeout_s" \
    >"$mission_log" 2>&1
mission_rc=$?
set -e

if (( mission_rc != 0 )); then
    cat "$mission_log"
    echo "VINS_TRANSLATION_MISSION_FAIL code=$mission_rc" >&2
    exit "$mission_rc"
fi
echo "VINS_TRANSLATION_MISSION_PASS"

# A monocular cold start is deliberately fail-closed and may reject every
# candidate from the first route.  Do not spend the rest of the bounded probe
# timeout stationary: provide one additional, independently landed/disarmed
# translation route while retaining both immutable mission records.
needs_recovery=1
if [[ -s $probe_result ]] && "$python_bin" - "$probe_result" <<'PY'
import json
import sys

try:
    gates = json.load(open(sys.argv[1], encoding="utf-8"))["gates"]
except (OSError, KeyError, TypeError, ValueError):
    raise SystemExit(1)
required = ("vins_tracking", "external_nav_ready", "external_nav_ground_truth")
raise SystemExit(0 if all(gates.get(name) for name in required) else 1)
PY
then
    needs_recovery=0
fi

if (( needs_recovery == 1 )); then
    echo "VINS_RECOVERY_TRANSLATION_BEGIN first route did not complete all VINS gates"
    set +e
    timeout --signal=TERM --kill-after=10 "$((mission_timeout_s + 30))" \
        "$python_bin" "$controller" \
        --connect "tcp:127.0.0.1:$controller_port" \
        --output "$recovery_result" \
        --sitl-pid-file "$run_dir/sitl/sitl.pid" \
        --lat "$latitude" --lon "$longitude" --alt "$origin_altitude" \
        --takeoff "$takeoff_m" --side "$side_m" --laps 2 --altitude-step 3 \
        --fixed-yaw-deg 1.0 \
        --required-wp-yaw-behavior 0.0 \
        --initial-ground-speed 0.75 --cruise-ground-speed 2.0 \
        --timeout "$mission_timeout_s" \
        >"$recovery_log" 2>&1
    recovery_rc=$?
    set -e
    if (( recovery_rc != 0 )); then
        cat "$recovery_log"
        echo "VINS_RECOVERY_TRANSLATION_FAIL code=$recovery_rc" >&2
        exit "$recovery_rc"
    fi
    echo "VINS_RECOVERY_TRANSLATION_PASS"
fi

set +e
wait "$probe_pid"
probe_rc=$?
set -e
trap - EXIT INT TERM
[[ -s $probe_process_log ]] && cat "$probe_process_log"
if (( probe_rc != 0 )); then
    echo "VINS_RUNTIME_GATE_FAIL code=$probe_rc" >&2
    exit "$probe_rc"
fi
echo "VINS_FLIGHT_QUALIFICATION_PASS"
