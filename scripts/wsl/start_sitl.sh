#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "usage: start_sitl.sh <ardupilot> <run-dir> <location> <instance> <sim-ip> <mp-port>" >&2
    exit 64
fi

ardupilot=$1
run_dir=$2
location=$3
instance=$4
sim_ip=$5
mission_planner_port=$6
defaults="$run_dir/../../config/arducopter-v0.1.parm"

if [[ ! -f "$defaults" ]]; then
    echo "missing SITL defaults: $defaults" >&2
    exit 66
fi

source "$HOME/venv-ardupilot/bin/activate"
cd "$run_dir/sitl"
supervisor="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sitl_supervisor.sh"

nohup "$supervisor" "$ardupilot/build/sitl/bin/arducopter" \
    -w \
    --model airsim-copter \
    --speedup 1 \
    --slave 0 \
    --serial0="tcp:$((5760 + instance * 10))" \
    --serial1="tcp:$mission_planner_port" \
    --defaults="$defaults" \
    --sim-address="$sim_ip" \
    -I"$instance" \
    --home "$location" \
    >"$run_dir/sitl/sitl.log" 2>&1 </dev/null &

pid=$!
printf '%s\n' "$pid" >"$run_dir/sitl/wsl.pid"
sleep 2
kill -0 "$pid"
child_pid=$(pgrep -P "$pid" -x arducopter | head -n 1)
if [[ -z "$child_pid" ]]; then
    echo "ArduCopter child process was not created" >&2
    exit 70
fi
printf '%s\n' "$child_pid" >"$run_dir/sitl/sitl.pid"
