#!/usr/bin/env bash
set -eo pipefail

if [[ $# -ne 6 ]]; then
    echo "usage: start_ros_bridge.sh <repo-root> <run-dir> <host> <port> <profile> <domain-id>" >&2
    exit 64
fi

repo_root=$1
run_dir=$2
host=$3
port=$4
profile=$5
domain_id=$6
ros_dir="$run_dir/ros2"
mkdir -p "$ros_dir"

if [[ -f /opt/iros2j/setup.bash ]]; then
    source /opt/iros2j/setup.bash
elif [[ -f /opt/ros/jazzy/setup.bash ]]; then
    source /opt/ros/jazzy/setup.bash
else
    echo "ROS 2 Jazzy setup was not found" >&2
    exit 66
fi

# The custom /opt/iros2j setup probes optional variables such as COLCON_TRACE.
# Enable nounset only after the generated ROS environment has been sourced.
set -u

export ROS_DOMAIN_ID="$domain_id"
export PYTHONPATH="$repo_root/third_party/Cosys-AirSim/PythonClient${PYTHONPATH:+:$PYTHONPATH}"
python_bin="$HOME/venv-ardupilot/bin/python3"
if [[ ! -x "$python_bin" ]]; then
    echo "ArduPilot Python environment is missing: $python_bin" >&2
    exit 67
fi
nohup setsid "$python_bin" "$repo_root/scripts/wsl/cosys_ros2_bridge.py" \
    --host "$host" \
    --port "$port" \
    --profile "$profile" \
    --status "$ros_dir/status.json" \
    >"$ros_dir/bridge.log" 2>&1 </dev/null &

pid=$!
printf '%s\n' "$pid" >"$ros_dir/wsl.pid"
sleep 2
kill -0 "$pid"
