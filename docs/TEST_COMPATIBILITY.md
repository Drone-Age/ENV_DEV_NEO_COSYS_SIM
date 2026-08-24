# Backend-neutral SIM qualification contract

## Compatibility goal

Existing repositories such as `Drone-Age/ENV_DEV_NEO_SIM_TEST_VINS_CLIMB` and `Drone-Age/ENV_DEV_NEO_SIM_TEST_VINS_10KM` must run against SIM2/Gazebo and this Cosys/Unreal backend without separate permanent test forks. Their entrypoints, profile schema, ROS topic contract and JSON/PDF verdict meanings remain stable. Backend-specific launch details belong in each parent simulator.

The parent pins those exact test repositories as Git submodules under `tests/`. The same test commit must be used for the SIM2 reference run and the Cosys run. Compatibility does not mean copying mission logic into this repository: it means providing the backend-neutral capability and launch contract expected by the existing test repository.

The initial pinned compatibility matrix is:

| Suite | Version / commit | Parent path | Current status |
|---|---|---|---|
| VINS climb | v2.0.0 / `10b3f4717ee599b99a4bfdba4fca29869661ca37` | `tests/vins_climb_unit` | registered; blocked on ROS/VINS/wind capabilities |
| VINS 10 km | v1.0.0 / `a11707a4281d84f304817a6547eac4108d5819de` | `tests/vins_10km_unit` | registered; blocked on ROS/VINS/wind capabilities |

Before launch, a test calls:

```powershell
.\dev.ps1 capabilities -Environment sim2-rural -Json
```

It must fail early with a clear missing-capability list. It must never silently skip a required wind, VINS, timing or evidence gate.

## Preserved test-facing interface

The compatibility adapter will preserve the existing argument names used by the test repositories: `RunId`, `FlightLogDirectory`, `Rosbag`, `FlightQualification`, `FlightQualificationLimitM`, `FlightQualificationProfile`, `FlightQualificationNoWind`, `FlightQualificationNoVisualUi`, `RouteQualification`, `RouteQualificationProfile`, `Headless`, `VinsConfigFile` and `Distro`. Automated test launches default to no Mission Planner; an observer UI requires an explicit `WithMissionPlanner` request.

The existing profile field `launch_gazebo` means “launch the selected simulator backend” after capability negotiation; it must not force a Gazebo process when the backend is `cosys-unreal`. The test keeps calling its unchanged `run-test.cmd`; the Cosys parent adapter translates the existing `dev.ps1 run` arguments into UE, SITL, ROS bridge and evidence processes. Backend selection must be explicit in the generated run manifest, never inferred from executable names.

The ROS 2 Jazzy compatibility layer preserves `/clock`, `/sim/ground_truth/odom`, `/sim/body/imu`, `/sim/camera/imu`, `/sim/camera/image_raw` and `/sim/camera/camera_info`, including coordinate frames and simulation timestamps. iMAVROS/VINS endpoint separation and Source Set 2 primary / Source Set 1 emergency behaviour remain test-visible invariants.

## Capability milestones

Current capabilities report the fixed-rate asynchronous camera and the initial ROS 2 Jazzy topic bridge as true. The bridge passed topic/frame/timestamp/payload conformance and a complete Blocks flight with no Mission Planner. VINS, batched 200 Hz camera IMU and wind command/ack remain false until their own runtime acceptance gates pass; `ros2=true` must not be interpreted as VINS readiness.

Before the 25 m climb smoke, the Cosys fork and wrapper must provide:

- fixed-rate 640 x 480 RGB producer at 20 Hz with a ring buffer and asynchronous `FRHIGPUTextureReadback` (consumer RPC rate must not define sensor cadence);
- timestamped batched camera IMU at 200 Hz, with original simulation timestamps; body IMU and camera-nearest-IMU p95 delta no more than 5 ms;
- gimbal 0-90 degrees, VINS initializer, vision bridge and ArduPilot ExternalNav;
- wind set/get-applied API carrying command id, requested vector, applied simulation timestamp and acknowledgement;
- MCAP, DataFlash, parameters, routes and immutable JSON/PDF evidence bundle.

Acceptance order is: ROS/topic conformance -> camera/IMU rate and timestamp tests -> VINS TRACKING/ExternalNav READY -> 25 m climb -> full 1000 m climb -> 10 km Gerono route -> remaining registry suites. Full climb retains 25 m steps, 1000 m ceiling, staged wind, Source Set 2 primary and GNSS standby. Mission Planner remains absent from automation.

For the climb v2.0.0 profile, ground admission additionally requires finite VINS odometry >=4 Hz, at least 15 tracked features, fresh continuous vision bridge output and `/mavros/odometry/out` READY for 2 s, an FCU-confirmed Source Set 2, fresh FCU local position, LOITER and a 10 s settle before ARM. Wind acknowledgements are correlated by command ID and must arrive within 5 s. The 25 m smoke uses a 5->10->5 m/s sequence; the full profile adds four 18 m/s N/S/N/S gusts at every checkpoint from 100 m and tier-specific extra gusts above 300 m. PASS is not emitted until LAND and DISARM while Source Set 2 remains active.

For every registered suite, compatibility requires three results: its unmodified public entrypoint starts through the adapter, all required capabilities are reported before launch, and the produced verdict/evidence schema is comparable with SIM2. A backend-specific configuration file is allowed; a backend-specific rewrite of the controller or acceptance logic is not.

## Parent/test responsibility split

The parent simulator owns UE/Gazebo startup, SITL, ROS bridge, network endpoints, environment selection and process cleanup. A test repository owns its profile, mission/controller, acceptance logic and verdict. A test may select a backend by capabilities but may not inspect Unreal/Gazebo process names or hard-code a parent directory layout.

The first update to each test repository must add capability negotiation while keeping the existing `run-test.cmd` entrypoint. Both SIM2 and Cosys parents must execute the same test commit in CI/manual qualification; parity is proven only when evidence schemas and gate results compare successfully.
