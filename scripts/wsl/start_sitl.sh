#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "usage: start_sitl.sh <ardupilot> <run-dir> <location> <instance> <sim-ip> <mp-port> <wind-port>" >&2
    exit 64
fi

ardupilot=$1
run_dir=$2
location=$3
instance=$4
sim_ip=$5
mission_planner_port=$6
wind_port=$7
defaults="$run_dir/../../config/arducopter-v0.1.parm"

if [[ ! -f "$defaults" ]]; then
    echo "missing SITL defaults: $defaults" >&2
    exit 66
fi

source "$HOME/venv-ardupilot/bin/activate"
cd "$run_dir/sitl"
supervisor="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sitl_supervisor.sh"

# AP_HAL_SITL uses a fixed 60-byte buffer while locating dumpstack/dumpcore.
# The repository path can exceed it, so expose the pinned helpers through a
# deterministic short symlink. Crash output still lands in this run directory.
diagnostic_link="/tmp/indra-ap-scripts"
ln -sfn "$ardupilot/Tools/scripts" "$diagnostic_link"
export AP_SCRIPTS_DIR_PATH="$diagnostic_link"

nohup setsid "$supervisor" "$ardupilot/build/sitl/bin/arducopter" \
    -w \
    --model airsim-copter \
    --speedup 1 \
    --slave 0 \
    --serial0="tcp:$((5760 + instance * 10))" \
    --serial1="tcp:$mission_planner_port" \
    --serial2="tcp:$wind_port" \
    --defaults="$defaults" \
    --sim-address="$sim_ip" \
    -I"$instance" \
    --home "$location" \
    >"$run_dir/sitl/sitl.log" 2>&1 </dev/null &

pid=$!
printf '%s\n' "$pid" >"$run_dir/sitl/wsl.pid"
child_pid=""
for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ArduCopter supervisor exited during startup" >&2
        tail -n 20 "$run_dir/sitl/sitl.log" >&2 || true
        exit 70
    fi
    child_pid=$(pgrep -P "$pid" -x arducopter | head -n 1 || true)
    if [[ -n "$child_pid" ]]; then
        printf '%s\n' "$child_pid" >"$run_dir/sitl/sitl.pid"
        exit 0
    fi
    sleep 0.1
done
echo "ArduCopter child process was not created within 10 seconds" >&2
tail -n 20 "$run_dir/sitl/sitl.log" >&2 || true
exit 70
