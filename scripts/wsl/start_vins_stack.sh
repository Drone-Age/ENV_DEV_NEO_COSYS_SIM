#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 8 ]]; then
    echo "usage: start_vins_stack.sh <repo-root> <run-dir> <host> <rpc-port> <mavlink-port> <domain-id> <timeout-s> <installed|source>" >&2
    exit 64
fi

repo_root=$1
run_dir=$2
host=$3
rpc_port=$4
mavlink_port=$5
domain_id=$6
timeout_s=$7
runtime_mode=$8
vins_dir="$run_dir/vins"
case "$runtime_mode" in
    installed) overlay="$HOME/.local/share/indra-cosys/ivins-adapter-overlay-jazzy/install/setup.bash" ;;
    source) overlay="$HOME/.local/share/indra-cosys/vins-overlay-jazzy/install/setup.bash" ;;
    *) echo "invalid IVINS runtime mode: $runtime_mode" >&2; exit 64 ;;
esac
mkdir -p "$vins_dir" /tmp/indra-cosys-ihub

if [[ -f /opt/ros/jazzy/setup.bash ]]; then
    set +u
    source /opt/ros/jazzy/setup.bash
    set -u
elif [[ -f /opt/iros2j/setup.bash ]]; then
    set +u
    source /opt/iros2j/setup.bash
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
if [[ "$runtime_mode" == source ]]; then
    export IHUB_SIM_BRIDGE="$HOME/.local/share/indra-cosys/vins-overlay-jazzy/install/lib/libihub_sim_bridge.so"
    [[ -f "$IHUB_SIM_BRIDGE" ]] || { echo "iHUB simulation bridge is missing: $IHUB_SIM_BRIDGE" >&2; exit 67; }
else
    # iHUB 0.3.2 owns the Cosys RPC backend. Do not allow a workstation or a
    # source overlay to inject the legacy compatibility shared object into the
    # official installed runtime.
    unset IHUB_SIM_BRIDGE
fi

nohup setsid timeout --signal=TERM --kill-after=10 "$timeout_s" \
    ros2 launch vins_sim_bringup vins_stack.launch.py \
    fcu_url:="tcp://127.0.0.1:$mavlink_port" \
    cosys_host:="$host" \
    cosys_port:="$rpc_port" \
    cosys_camera:="0" \
    cosys_vehicle:="Copter" \
    cosys_pitch_sign:="1.0" \
    ihub_flash_path:="$vins_dir/ihub-flash.bin" \
    >"$vins_dir/stack.log" 2>&1 </dev/null &

pid=$!
printf '%s\n' "$pid" >"$vins_dir/wsl.pid"
sleep 2
kill -0 "$pid"
