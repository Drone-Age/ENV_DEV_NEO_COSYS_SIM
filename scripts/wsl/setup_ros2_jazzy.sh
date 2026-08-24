#!/usr/bin/env bash
set -euo pipefail

if [[ -f /opt/iros2j/setup.bash || -f /opt/ros/jazzy/setup.bash ]]; then
    exit 0
fi

source /etc/os-release
codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
if [[ ${ID:-} != ubuntu || $codename != noble ]]; then
    echo "ROS 2 Jazzy bootstrap requires Ubuntu 24.04 (noble), found ${PRETTY_NAME:-unknown}" >&2
    exit 65
fi

sudo apt-get update
sudo apt-get install -y ca-certificates curl software-properties-common
sudo add-apt-repository -y universe

ros_source_version=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
source_deb="/tmp/ros2-apt-source_${ros_source_version}.${codename}_all.deb"
curl -fL -o "$source_deb" \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ros_source_version}/ros2-apt-source_${ros_source_version}.${codename}_all.deb"
sudo dpkg -i "$source_deb"
sudo apt-get update
sudo apt-get install -y \
    ros-jazzy-ros-base \
    ros-jazzy-nav-msgs \
    ros-jazzy-rosgraph-msgs \
    ros-jazzy-sensor-msgs

set +u
source /opt/ros/jazzy/setup.bash
set -u
python3 -c 'import rclpy; from nav_msgs.msg import Odometry; from rosgraph_msgs.msg import Clock; from sensor_msgs.msg import CameraInfo, Image, Imu'
