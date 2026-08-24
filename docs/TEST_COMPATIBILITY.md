# Backend-neutral SIM qualification contract

## Compatibility goal

Existing repositories such as `Drone-Age/ENV_DEV_NEO_SIM_TEST_VINS_CLIMB` and `Drone-Age/ENV_DEV_NEO_SIM_TEST_VINS_10KM` must run against SIM2/Gazebo and this Cosys/Unreal backend without separate permanent test forks. Their entrypoints, profile schema, ROS topic contract and JSON/PDF verdict meanings remain stable. Backend-specific launch details belong in each parent simulator.

Before launch, a test calls:

```powershell
.\dev.ps1 capabilities -Environment sim2-rural -Json
```

It must fail early with a clear missing-capability list. It must never silently skip a required wind, VINS, timing or evidence gate.

## Preserved test-facing interface

The compatibility adapter will preserve the existing argument names used by the test repositories: `RunId`, `FlightLogDirectory`, `Rosbag`, `FlightQualification`, `FlightQualificationLimitM`, `FlightQualificationProfile`, `FlightQualificationNoWind`, `FlightQualificationNoVisualUi`, `RouteQualification`, `RouteQualificationProfile`, `Headless`, `VinsConfigFile` and `Distro`. Automated test launches default to no Mission Planner; an observer UI requires an explicit `WithMissionPlanner` request.

The ROS 2 Jazzy compatibility layer preserves `/clock`, `/sim/ground_truth/odom`, `/sim/body/imu`, `/sim/camera/imu`, `/sim/camera/image_raw` and `/sim/camera/camera_info`, including coordinate frames and simulation timestamps. iMAVROS/VINS endpoint separation and Source Set 2 primary / Source Set 1 emergency behaviour remain test-visible invariants.

## Capability milestones

Current v0.1 capabilities correctly report ROS 2, VINS, fixed-rate camera production, batched camera IMU and wind command/ack as false.

Before the 25 m climb smoke, the Cosys fork and wrapper must provide:

- fixed-rate 640 x 480 RGB producer at 20 Hz with a ring buffer and asynchronous `FRHIGPUTextureReadback` (consumer RPC rate must not define sensor cadence);
- timestamped batched camera IMU at 200 Hz, with original simulation timestamps; body IMU and camera-nearest-IMU p95 delta no more than 5 ms;
- gimbal 0-90 degrees, VINS initializer, vision bridge and ArduPilot ExternalNav;
- wind set/get-applied API carrying command id, requested vector, applied simulation timestamp and acknowledgement;
- MCAP, DataFlash, parameters, routes and immutable JSON/PDF evidence bundle.

Acceptance order is: ROS/topic conformance -> camera/IMU rate and timestamp tests -> VINS TRACKING/ExternalNav READY -> 25 m climb -> full 1000 m climb -> 10 km Gerono route -> remaining registry suites. Full climb retains 25 m steps, 1000 m ceiling, staged wind, Source Set 2 primary and GNSS standby. Mission Planner remains absent from automation.

## Parent/test responsibility split

The parent simulator owns UE/Gazebo startup, SITL, ROS bridge, network endpoints, environment selection and process cleanup. A test repository owns its profile, mission/controller, acceptance logic and verdict. A test may select a backend by capabilities but may not inspect Unreal/Gazebo process names or hard-code a parent directory layout.

The first update to each test repository must add capability negotiation while keeping the existing `run-test.cmd` entrypoint. Both SIM2 and Cosys parents must execute the same test commit in CI/manual qualification; parity is proven only when evidence schemas and gate results compare successfully.
