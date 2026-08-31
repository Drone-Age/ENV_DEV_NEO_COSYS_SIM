#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: build_vins_overlay.sh <repo-root> <runtime-root>" >&2
    exit 64
fi

repo_root=$1
runtime_root=$2
overlay_root="$runtime_root/vins-overlay-jazzy"

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
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"

packages=(
    mavros mavros_extras
    feature_tracker vins_estimator
    ihub vins_initializer vision_bridge vins_sim_bringup
)

if [[ -f /opt/imavros/setup.bash \
    && -f /opt/vins/setup.bash \
    && -f /opt/vio_stack/current/local_setup.bash ]]; then
    # NewSIM release qualification must exercise the exact installed product
    # binaries. Build only the simulator adapter as an overlay on that matrix.
    set +u
    source /opt/imavros/setup.bash
    source /opt/vins/setup.bash
    source /opt/vio_stack/current/local_setup.bash
    set -u
    base_paths=("$repo_root/ros_ws/src")
    build_packages=(vins_sim_bringup)
    build_ihub_sim_bridge=true
else
    base_paths=(
        "$repo_root/third_party/iMAVROS"
        "$repo_root/third_party/VINS-NEO"
        "$repo_root/third_party/vio_stack/src"
    )
    if [[ -d "$repo_root/ros_ws/src" ]]; then
        base_paths+=("$repo_root/ros_ws/src")
    fi
    build_packages=("${packages[@]}")
    build_ihub_sim_bridge=false
fi

colcon --log-base "$overlay_root/log" build \
    --base-paths "${base_paths[@]}" \
    --build-base "$overlay_root/build" \
    --install-base "$overlay_root/install" \
    --merge-install --symlink-install \
    --packages-up-to "${build_packages[@]}" \
    --allow-overriding \
        libmavconn mavros_msgs mavros mavros_extras \
        vio_stack_interfaces ihub vins_initializer vision_bridge \
    --executor sequential \
    --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo

if [[ $build_ihub_sim_bridge == true ]]; then
    # The production vio_stack package intentionally carries the runtime iHUB
    # nodes, but the host-only simulator bridge is built from the same pinned
    # source for NewSIM qualification.
    ihub_stm_source="$repo_root/third_party/vio_stack/src/actuators/iHUB/firmware/iHUB-STM"
    ihub_stm_build="$overlay_root/build/ihub_stm_host"
    cmake -S "$ihub_stm_source" -B "$ihub_stm_build" \
        -DIHUB_BUILD_HOST=ON \
        -DBUILD_TESTING=ON \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="$overlay_root/install"
    cmake --build "$ihub_stm_build" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL}"
    ctest --test-dir "$ihub_stm_build" --output-on-failure
    cmake --install "$ihub_stm_build"
fi

set +u
source "$overlay_root/install/setup.bash"
set -u
for package_name in "${packages[@]}"; do
    ros2 pkg prefix "$package_name" >/dev/null
done

printf '%s\n' "$overlay_root/install/setup.bash" >"$overlay_root/setup-path.txt"
echo "VINS_OVERLAY_BUILD_PASS $overlay_root/install"
