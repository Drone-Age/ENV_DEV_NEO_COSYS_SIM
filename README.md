# ENV_DEV_NEO_COSYS_SIM

An Unreal Engine 5.8.1 and Cosys-AirSim flight environment for INDRA. The first acceptance target is deliberately small: the Cosys Blocks scene, ArduCopter SITL in WSL2, Mission Planner on Windows, and an automatic `TAKEOFF -> 15 m square -> LAND` smoke mission.

## Pinned stack

- Unreal Engine 5.8.1
- Cosys-AirSim 3.4.1 (`5.8-v3.4.1`) from `Drone-Age/Cosys-AirSim:indra-ue5.8`
- ArduPilot at the same commit used by `ENV_DEV_NEO_SIM2`
- isolated Ubuntu 24.04.4 WSL2 distribution `INDRA-COSYS-SIM`
- Mission Planner 1.3.83 portable

## First use

Run these commands from a regular PowerShell window. `doctor` reports any prerequisite that still needs installation.

```powershell
.\dev.ps1 doctor
.\dev.ps1 setup
.\dev.ps1 build
.\dev.ps1 run
```

For the canonical automatic mission:

```powershell
.\dev.ps1 test
```

For the initial SIM2-compatible ROS 2 Jazzy sensor contract, without Mission Planner:

```powershell
.\dev.ps1 ros-test
.\dev.ps1 vins-test
.\dev.ps1 test -WithRos2
```

Normal VINS runs use the officially installed IVINS DEV package matrix. Source
overlays remain available only as an explicit component-development fallback:

```powershell
.\dev.ps1 ivins -IvinsCommand doctor
.\dev.ps1 vins-test -IvinsRuntime installed
# development fallback only
.\dev.ps1 vins-test -IvinsRuntime source
```

Official enrollment and the stage-automatically/apply-manually update flow are
documented in [docs/IVINS_DEV.md](docs/IVINS_DEV.md). Enrollment secrets are
never accepted as command-line values or written to a NewSIM evidence bundle.

`ros-test` verifies `/clock`, ground-truth odometry, body/camera IMU, raw RGB and camera calibration using strict simulation timestamps, expected frames and wall-clock delivery-rate floors. `vins-test` then exercises the production iHUB UART sweep, moving CameraImu, VINS initializer, feature tracking and ExternalNav READY without Mission Planner. The flight variant proves that the base bridge does not regress heartbeat, EKF, ARM, route, LAND or DISARM.

## Environment packages

The UE host project is intentionally small. Maps and reusable asset sets are versioned independently and mounted as content-only plugins:

```powershell
.\dev.ps1 env list
.\dev.ps1 env doctor blocks
.\dev.ps1 setup -Environment sim2-rural
.\dev.ps1 env build-map sim2-rural
.\dev.ps1 test -Environment sim2-rural -Preview -SkipBuild
.\dev.ps1 run -Environment blocks -RenderProfile qualification
```

`blocks` is the ready offline baseline. `sim2-rural` is the private 4 x 4 km qualification environment at the exact SIM2 origin, and `cesium-global` is an optional global visual environment. SIM2 Rural has a generated UE World Partition Landscape over real Copernicus GLO-30 height and Sentinel-2 imagery. Runtime DEM collision and a pad-free square flight pass. The opt-in asynchronous raw Scene path now passes 20-second tests at 20.50 FPS for 640 x 480 and 20.49 FPS for 1280 x 720, with zero duplicate timestamps; every benchmark also rejects uniform/black buffers. It remains `preview` until full-extent terrain probes, vegetation and the remaining SIM2-equivalence gates pass. Preview runs therefore require explicit `-Preview` and cannot promote readiness. Access to private `Drone-Age` repositories and Git LFS is required to initialise them.

Environment architecture, real-map data policy and milestones are documented in [docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md). Backend-neutral compatibility with the existing VINS climb/route repositories is specified in [docs/TEST_COMPATIBILITY.md](docs/TEST_COMPATIBILITY.md).

The ordered path from the small Blocks demo to full SIM2 test parity is the normative [implementation roadmap](docs/ROADMAP.md). A milestone is complete only after its recorded acceptance tests pass; visual improvements cannot replace functional qualification.

For the camera throughput qualification (640x480 and 1280x720, no Mission Planner):

```powershell
.\dev.ps1 camera-test
```

The qualified live path returns uncompressed RGB from a fixed-rate asynchronous producer with `ForceUpdate=false`. Acceptance is at least 20 FPS for 640 x 480, at least 10 FPS for 1280 x 720, and at least 10 FPS in the worst full two-second window. With live ArduCopter SITL, the current Blocks evidence is 26.77 FPS at 640 x 480 and 24.03 FPS at 1280 x 720; the latter's worst full two-second window is 18.5 FPS. PNG compression reached only 6.89 FPS at 1280 x 720 and is not used in the real-time path.

Each run gets its own evidence directory under `logs`. Use `.\dev.ps1 stop` to stop only processes recorded by this environment, and `.\dev.ps1 logs` to open the newest bundle.

For a clean-machine installation, exact prerequisites, verification gates and agent handoff rules, follow [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

The v0.1 release gate intentionally remains independent of ROS 2. The ROS 2 topic bridge and batched 200 Hz CameraImu transport are qualified. Gimbal/VINS/ExternalNav code is present but remains an unclaimed capability until `vins-test` produces runtime PASS evidence; wind command/ack follows after that gate. `dev.ps1 capabilities -Environment blocks -Json` reports implemented capabilities so external tests can fail early instead of inferring support. Camera findings and the upgrade path are recorded in [docs/CAMERA_PERFORMANCE.md](docs/CAMERA_PERFORMANCE.md).
