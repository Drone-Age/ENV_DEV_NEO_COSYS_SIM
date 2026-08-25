#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: build_vins_overlay.sh <repo-root> <runtime-root>" >&2
    exit 64
fi

repo_root=$1
runtime_root=$2
overlay_root="$runtime_root/vins-overlay"

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

command -v colcon >/dev/null
mkdir -p "$overlay_root/build" "$overlay_root/install" "$overlay_root/log"

base_paths=(
    "$repo_root/third_party/iMAVROS"
    "$repo_root/third_party/VINS-NEO"
    "$repo_root/third_party/vio_stack/src"
)
if [[ -d "$repo_root/ros_ws/src" ]]; then
    base_paths+=("$repo_root/ros_ws/src")
fi

packages=(
    mavros mavros_extras
    feature_tracker vins_estimator
    ihub vins_initializer vision_bridge
)

colcon --log-base "$overlay_root/log" build \
    --base-paths "${base_paths[@]}" \
    --build-base "$overlay_root/build" \
    --install-base "$overlay_root/install" \
    --merge-install --symlink-install \
    --packages-up-to "${packages[@]}" \
    --allow-overriding \
        libmavconn mavros_msgs mavros mavros_extras \
        vio_stack_interfaces ihub vins_initializer vision_bridge \
    --executor sequential \
    --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo

set +u
source "$overlay_root/install/setup.bash"
set -u
for package_name in "${packages[@]}"; do
    ros2 pkg prefix "$package_name" >/dev/null
done

printf '%s\n' "$overlay_root/install/setup.bash" >"$overlay_root/setup-path.txt"
echo "VINS_OVERLAY_BUILD_PASS $overlay_root/install"
