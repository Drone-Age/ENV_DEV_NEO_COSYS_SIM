#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: assert_sitl_alive.sh <run-dir> [stability-seconds]" >&2
    exit 64
fi

run_dir=$1
stability_seconds=${2:-0}
supervisor_pid_file="$run_dir/sitl/wsl.pid"
vehicle_pid_file="$run_dir/sitl/sitl.pid"
sitl_log="$run_dir/sitl/sitl.log"

fail() {
    echo "SITL_LIVENESS_FAIL $1" >&2
    [[ -f $sitl_log ]] && tail -n 40 "$sitl_log" >&2 || true
    exit 70
}

read_pid() {
    local path=$1
    [[ -s $path ]] || fail "missing PID file: $path"
    local value
    value=$(tr -d '[:space:]' <"$path")
    [[ $value =~ ^[1-9][0-9]*$ ]] || fail "invalid PID file: $path"
    printf '%s' "$value"
}

supervisor_pid=$(read_pid "$supervisor_pid_file")
vehicle_pid=$(read_pid "$vehicle_pid_file")
deadline=$((SECONDS + stability_seconds))

while true; do
    kill -0 "$supervisor_pid" 2>/dev/null || fail "supervisor $supervisor_pid exited"
    kill -0 "$vehicle_pid" 2>/dev/null || fail "ArduCopter $vehicle_pid exited"
    if (( SECONDS >= deadline )); then
        break
    fi
    sleep 0.25
done

echo "SITL_LIVENESS_PASS supervisor=$supervisor_pid arducopter=$vehicle_pid stable_s=$stability_seconds"
