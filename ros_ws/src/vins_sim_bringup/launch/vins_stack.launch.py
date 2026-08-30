from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, LogInfo, TimerAction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    share = Path(get_package_share_directory("vins_sim_bringup"))
    vins_config = str(share / "config" / "vins_smoke.yaml")
    mavros_config = str(share / "config" / "mavros_sim.yaml")
    mavros_plugins = str(share / "config" / "mavros_plugins.yaml")
    external_nav_config = str(share / "config" / "external_nav_sim.yaml")

    fcu_url = LaunchConfiguration("fcu_url")
    enable_ihub = LaunchConfiguration("enable_ihub")
    enable_external_nav = LaunchConfiguration("enable_external_nav")
    enable_wind = LaunchConfiguration("enable_wind")
    client_device = LaunchConfiguration("ihub_client_device")
    server_device = LaunchConfiguration("ihub_server_device")

    return LaunchDescription([
        DeclareLaunchArgument("fcu_url", default_value="tcp://127.0.0.1:5780"),
        DeclareLaunchArgument("enable_ihub", default_value="true"),
        DeclareLaunchArgument("enable_external_nav", default_value="true"),
        DeclareLaunchArgument("enable_wind", default_value="false"),
        DeclareLaunchArgument("ihub_client_device", default_value="/tmp/indra-cosys-ihub/client.tty"),
        DeclareLaunchArgument("ihub_server_device", default_value="/tmp/indra-cosys-ihub/server.tty"),
        DeclareLaunchArgument("ihub_flash_path", default_value="/tmp/indra-cosys-ihub/flash.bin"),
        DeclareLaunchArgument("cosys_host", default_value="127.0.0.1"),
        DeclareLaunchArgument("cosys_port", default_value="41452"),
        DeclareLaunchArgument("cosys_camera", default_value="0"),
        DeclareLaunchArgument("cosys_vehicle", default_value="Copter"),
        DeclareLaunchArgument("wind_mavlink_url", default_value="tcp:127.0.0.1:5784"),
        LogInfo(msg=["Starting Cosys VINS stack; FCU: ", fcu_url]),

        Node(
            package="mavros",
            executable="mavros_node",
            namespace="mavros",
            name="mavros",
            output="screen",
            emulate_tty=True,
            parameters=[
                mavros_plugins,
                mavros_config,
                {
                    "fcu_url": fcu_url,
                    "gcs_url": "",
                    "tgt_system": 1,
                    "tgt_component": 1,
                    "base_link_frame": "base_link",
                    "odom_frame": "odom",
                    "map_frame": "map",
                    "use_sim_time": True,
                },
            ],
        ),
        Node(
            package="vins_sim_bringup",
            executable="imu_qos_adapter",
            output="screen",
            parameters=[{
                "use_sim_time": True,
                "input_topic": "/sim/body/imu",
                "output_topic": "/mavros/imu/data_raw",
            }],
        ),
        Node(
            package="vins_sim_bringup",
            executable="wind_driver",
            name="wind_driver",
            output="screen",
            condition=IfCondition(enable_wind),
            parameters=[{
                "use_sim_time": True,
                "cosys_host": LaunchConfiguration("cosys_host"),
                "cosys_port": ParameterValue(
                    LaunchConfiguration("cosys_port"), value_type=int
                ),
                "mavlink_url": LaunchConfiguration("wind_mavlink_url"),
            }],
        ),

        ExecuteProcess(
            cmd=[
                "ros2", "run", "ihub", "ihub-uart-sim",
                "--client-link", client_device,
                "--server-link", server_device,
                "--baud", "115200",
                "--maximum-chunk", "32",
            ],
            name="ihub_uart_sim",
            output="screen",
            condition=IfCondition(enable_ihub),
        ),
        ExecuteProcess(
            cmd=[
                "ros2", "run", "ihub", "ihub-server-sim",
                "--device", server_device,
                "--flash", LaunchConfiguration("ihub_flash_path"),
                "--no-gazebo",
            ],
            name="ihub_server_sim",
            output="screen",
            additional_env={"PYTHONUNBUFFERED": "1"},
            condition=IfCondition(enable_ihub),
        ),
        TimerAction(
            period=1.0,
            actions=[ExecuteProcess(
                cmd=[
                    "bash", "-c",
                    "until [ -e \"$1\" ] && fuser \"$1\" >/dev/null 2>&1; "
                    "do sleep 0.1; done; shift; exec \"$@\"",
                    "ihub-client-ready",
                    server_device,
                    "ros2", "run", "ihub", "ihub-client", "--ros-args",
                    "-r", "__node:=ihub_client",
                    "-p", "use_sim_time:=true",
                    "-p", ["device:=", client_device],
                    "-p", "setpoint_topic:=/camera/tilt/setpoint",
                    "-p", "status_topic:=/camera/tilt/status",
                    "-p", "joint_state_topic:=/camera/tilt/joint_state",
                    "-p", "body_imu_topic:=/sim/body/imu",
                    "-p", "camera_imu_topic:=/sim/camera/imu",
                ],
                name="ihub_client_ready",
                output="screen",
                condition=IfCondition(enable_ihub),
            )],
        ),

        TimerAction(
            period=3.0,
            actions=[Node(
                package="vins_initializer",
                executable="vins-initializer",
                name="vins_initializer",
                output="screen",
                parameters=[{
                    "use_sim_time": True,
                    "ihub.present": ParameterValue(enable_ihub, value_type=bool),
                    "ihub.setpoint_topic": "/camera/tilt/setpoint",
                    "ihub.status_topic": "/camera/tilt/status",
                    "ihub.recalibrate_service": "/camera/tilt/recalibrate",
                    "ihub.handshake_timeout_s": 180.0,
                    "ihub.calibration_timeout_s": 180.0,
                    # A persisted flash record is useful operationally but is
                    # not evidence of a sweep performed in this immutable run.
                    "ihub.require_session_calibration": True,
                    # The external iHUB calibration proves the complete 0..90
                    # degree range before arming.  Preposition forward at 0
                    # degrees so Blocks keeps stable vertical features,
                    # restart VINS, and then keep the camera/IMU pair rigid while
                    # aircraft translation supplies metric scale.  Moving the
                    # mount during the solve would mix the 25 Hz RPC camera-pose
                    # actuator with the 200 Hz IMU history and is not acceptable
                    # evidence of a calibrated physical sensor pair.
                    "motion.sine_enabled": False,
                    "motion.verification_sine_enabled": False,
                    "motion.require_reference_motion": True,
                    "motion.minimum_reference_motion_m": 0.5,
                    "motion.lower_angle_rad": 0.0,
                    "motion.upper_angle_rad": 1.5707963267948966,
                    "motion.final_angle_rad": 0.0,
                    "motion.initialization_timeout_s": 180.0,
                    "vins.maximum_solver_attempts": 40,
                    "vins.minimum_imu_excitation": 0.08,
                    "vins.maximum_gyroscope_bias_rad_s": 0.05,
                    "vins.odometry_topic": "/vins_estimator/odometry",
                    "vins.reference_odometry_topic": "/sim/ground_truth/odom",
                    "status.topic": "/vio/initialization/status",
                }],
            )],
        ),
        Node(
            package="feature_tracker",
            executable="feature_tracker",
            namespace="feature_tracker",
            output="screen",
            emulate_tty=True,
            parameters=[{
                "config_file": vins_config,
                "vins_folder": str(share) + "/",
                "use_sim_time": True,
            }],
        ),
        Node(
            package="vins_estimator",
            executable="vins_estimator",
            namespace="vins_estimator",
            output="screen",
            emulate_tty=True,
            additional_env={
                "RCUTILS_COLORIZED_OUTPUT": "0",
                "GLOG_minloglevel": "1",
                "GLOG_v": "-1",
            },
            parameters=[{
                "config_file": vins_config,
                "vins_folder": str(share) + "/",
                "logging.level": "INFO",
                "logging.period_ms": 1000,
                "use_sim_time": True,
            }],
        ),

        Node(
            package="tf2_ros",
            executable="static_transform_publisher",
            name="sim_world_to_odom",
            arguments=[
                "--x", "0", "--y", "0", "--z", "0",
                "--roll", "0", "--pitch", "0", "--yaw", "0",
                "--frame-id", "world", "--child-frame-id", "odom",
            ],
            parameters=[{"use_sim_time": True}],
        ),
        Node(
            package="tf2_ros",
            executable="static_transform_publisher",
            name="tf_odom_to_odom_ned",
            arguments=[
                "--x", "0", "--y", "0", "--z", "0",
                "--roll", "3.1415926", "--pitch", "0", "--yaw", "1.5707963",
                "--frame-id", "odom", "--child-frame-id", "odom_ned",
            ],
            parameters=[{"use_sim_time": True}],
        ),
        Node(
            package="tf2_ros",
            executable="static_transform_publisher",
            name="tf_base_to_base_frd",
            arguments=[
                "--x", "0", "--y", "0", "--z", "0",
                "--roll", "3.1415926", "--pitch", "0", "--yaw", "0",
                "--frame-id", "base_link", "--child-frame-id", "base_link_frd",
            ],
            parameters=[{"use_sim_time": True}],
        ),
        Node(
            package="vision_bridge",
            executable="vision_bridge",
            name="vision_bridge",
            output="screen",
            condition=IfCondition(enable_external_nav),
            parameters=[external_nav_config, {"use_sim_time": True}],
        ),
        Node(
            package="vision_bridge",
            executable="external-nav-ready-heartbeat",
            name="external_nav_ready_heartbeat",
            output="screen",
            condition=IfCondition(enable_external_nav),
            parameters=[{"use_sim_time": True}],
        ),
    ])
