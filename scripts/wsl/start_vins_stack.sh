#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 10 ]]; then
    echo "usage: start_vins_stack.sh <repo-root> <run-dir> <host> <rpc-port> <mavlink-port> <wind-mavlink-port> <domain-id> <timeout-s> <enable-wind> <installed|source>" >&2
    exit 64
fi

repo_root=$1
run_dir=$2
host=$3
rpc_port=$4
mavlink_port=$5
wind_mavlink_port=$6
domain_id=$7
timeout_s=$8
enable_wind=$9
runtime_mode=${10}
if [[ $enable_wind != true && $enable_wind != false ]]; then
    echo "enable-wind must be true or false" >&2
    exit 64
fi
vins_dir="$run_dir/vins"
runtime_root="${INDRA_VINS_RUNTIME_ROOT:-$HOME/.local/share/indra-cosys}"
case "$runtime_mode" in
    installed) overlay_root="$runtime_root/ivins-adapter-overlay-jazzy" ;;
    source) overlay_root="$runtime_root/vins-overlay-jazzy" ;;
    *) echo "invalid IVINS runtime mode: $runtime_mode" >&2; exit 64 ;;
esac
overlay="$overlay_root/install/setup.bash"
mkdir -p "$vins_dir" /tmp/indra-cosys-ihub

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
if [[ "$runtime_mode" == installed ]]; then
    for setup in \
        /opt/imavros/setup.bash \
        /opt/vins/setup.bash \
        /opt/vio_stack/current/local_setup.bash; do
        [[ -r "$setup" ]] || { echo "official IVINS setup is missing: $setup" >&2; exit 67; }
        set +u
        source "$setup"
        set -u
    done
fi
if [[ ! -f $overlay ]]; then
    echo "Pinned VINS overlay was not built: $overlay" >&2
    exit 67
fi
set +u
source "$overlay"
set -u

export ROS_DOMAIN_ID="$domain_id"
rpc_site="$($HOME/venv-ardupilot/bin/python3 -c 'import site; print(site.getsitepackages()[0])')"
export PYTHONPATH="$repo_root/third_party/Cosys-AirSim/PythonClient:$rpc_site${PYTHONPATH:+:$PYTHONPATH}"
if [[ -f "$overlay_root/install/lib/libihub_sim_bridge.so" ]]; then
    export IHUB_SIM_BRIDGE="$overlay_root/install/lib/libihub_sim_bridge.so"
elif [[ -f /opt/vio_stack/current/lib/libihub_sim_bridge.so ]]; then
    export IHUB_SIM_BRIDGE=/opt/vio_stack/current/lib/libihub_sim_bridge.so
else
    echo "Pinned iHUB simulation bridge was not found" >&2
    exit 68
fi

nohup setsid timeout --signal=TERM --kill-after=10 "$timeout_s" \
    ros2 launch vins_sim_bringup vins_stack.launch.py \
    fcu_url:="tcp://127.0.0.1:$mavlink_port" \
    cosys_host:="$host" \
    cosys_port:="$rpc_port" \
    cosys_camera:="0" \
    cosys_vehicle:="Copter" \
    enable_wind:="$enable_wind" \
    wind_mavlink_url:="tcp:127.0.0.1:$wind_mavlink_port" \
    ihub_flash_path:="$vins_dir/ihub-flash.bin" \
    >"$vins_dir/stack.log" 2>&1 </dev/null &

pid=$!
printf '%s\n' "$pid" >"$vins_dir/wsl.pid"
sleep 2
kill -0 "$pid"
