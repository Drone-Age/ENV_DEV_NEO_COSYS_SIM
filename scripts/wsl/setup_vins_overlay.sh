#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: setup_vins_overlay.sh <repo-root>" >&2
    exit 64
fi

repo_root=$1
if [[ -f /opt/iros2j/setup.bash ]]; then
    ros_provider=iros2j
    set +u
    source /opt/iros2j/setup.bash
    set -u
elif [[ -f /opt/ros/jazzy/setup.bash ]]; then
    ros_provider=ros2
    set +u
    source /opt/ros/jazzy/setup.bash
    set -u
else
    echo "ROS 2 Jazzy setup was not found" >&2
    exit 66
fi

missing=()
for command_name in colcon rosdep cmake g++; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
for package_name in libeigen3-dev libceres-dev libopencv-dev python3-serial geographiclib-tools; do
    dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null \
        | grep -qx 'install ok installed' || missing+=("$package_name")
done

if ((${#missing[@]})); then
    echo "Installing VINS overlay prerequisites: ${missing[*]}" >&2
    apt-get update
    transition_dir=
    transition_ros_python_wrapper() {
        local wrapper=$1
        local module=$2
        local owned_file=$3
        if dpkg-query -W -f='${Status}' "$module" 2>/dev/null \
                | grep -qx 'install ok installed'; then
            return
        fi
        if [[ $(dpkg-query -S "$owned_file" 2>/dev/null | cut -d: -f1) != "$wrapper" ]]; then
            return
        fi
        local candidate
        candidate=$(apt-cache policy "$wrapper" | sed -n 's/^  Candidate: //p')
        [[ -n $candidate && $candidate != '(none)' ]]
        if [[ -z $transition_dir ]]; then
            transition_dir=$(mktemp -d /var/tmp/indra-ros-python-transition.XXXXXX)
        fi
        (
            cd "$transition_dir"
            apt-get download "$wrapper=$candidate"
        )
        local packages=("$transition_dir/${wrapper}_"*.deb)
        ((${#packages[@]} == 1)) && [[ -f ${packages[0]} ]]
        dpkg --unpack "${packages[0]}"
    }
    transition_ros_python_wrapper \
        python3-catkin-pkg python3-catkin-pkg-modules \
        /usr/lib/python3/dist-packages/catkin_pkg/__init__.py
    transition_ros_python_wrapper \
        python3-rospkg python3-rospkg-modules \
        /usr/lib/python3/dist-packages/rospkg/__init__.py
    apt-get install -y \
        build-essential cmake ninja-build pkg-config \
        python3-colcon-common-extensions python3-rosdep python3-serial \
        geographiclib-tools libeigen3-dev libceres-dev libopencv-dev
    if [[ -n $transition_dir ]]; then
        case $transition_dir in
            /var/tmp/indra-ros-python-transition.*) rm -rf -- "$transition_dir" ;;
            *) echo "refusing to remove unexpected transition directory: $transition_dir" >&2; exit 1 ;;
        esac
    fi
fi

if [[ ! -r /usr/share/GeographicLib/geoids/egm96-5.pgm ]]; then
    geographiclib-get-geoids egm96-5
fi
test -r /usr/share/GeographicLib/geoids/egm96-5.pgm

if [[ ! -e /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    rosdep init
fi
rosdep update --rosdistro jazzy

if [[ $ros_provider == ros2 ]]; then
    rosdep install --from-paths \
        "$repo_root/third_party/iMAVROS" \
        "$repo_root/third_party/VINS-NEO" \
        "$repo_root/third_party/vio_stack/src" \
        --ignore-src --rosdistro jazzy -r -y \
        --skip-keys 'python3-gz-msgs10 python3-gz-transport13'
fi

python3 - <<'PY'
import serial  # noqa: F401
PY
colcon list --help >/dev/null
echo "VINS_OVERLAY_SETUP_PASS provider=$ros_provider"
