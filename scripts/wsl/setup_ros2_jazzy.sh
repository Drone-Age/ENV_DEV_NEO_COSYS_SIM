#!/usr/bin/env bash
set -euo pipefail

if [[ -f /opt/ros/jazzy/setup.bash ]]; then
    exit 0
fi

source /etc/os-release
codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
if [[ ${ID:-} != ubuntu || $codename != noble ]]; then
    echo "ROS 2 Jazzy bootstrap requires Ubuntu 24.04 (noble), found ${PRETTY_NAME:-unknown}" >&2
    exit 65
fi

apt-get update
apt-get install -y ca-certificates curl software-properties-common
add-apt-repository -y universe

ros_source_version=1.2.0
ros_source_sha256=0804d9b13db770eb87019be414cd78378835228ad5fa801fc88758596dd8f7e5
source_deb="/tmp/ros2-apt-source_${ros_source_version}.${codename}_all.deb"
curl -fL -o "$source_deb" \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ros_source_version}/ros2-apt-source_${ros_source_version}.${codename}_all.deb"
printf '%s  %s\n' "$ros_source_sha256" "$source_deb" | sha256sum --check --strict
dpkg -i "$source_deb"
apt-get update
apt-get install -y \
    ros-jazzy-ros-base \
    ros-jazzy-nav-msgs \
    ros-jazzy-rosgraph-msgs \
    ros-jazzy-sensor-msgs

set +u
source /opt/ros/jazzy/setup.bash
set -u
python3 -c 'import rclpy; from nav_msgs.msg import Odometry; from rosgraph_msgs.msg import Clock; from sensor_msgs.msg import CameraInfo, Image, Imu'
