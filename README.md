# ENV_DEV_NEO_COSYS_SIM

An Unreal Engine 5.8.1 and Cosys-AirSim flight environment for INDRA. The first acceptance target is deliberately small: the Cosys Blocks scene, ArduCopter SITL in WSL2, Mission Planner on Windows, and an automatic `TAKEOFF -> 15 m square -> LAND` smoke mission.

## Pinned stack

- Unreal Engine 5.8.1
- Cosys-AirSim 3.4.1 (`5.8-v3.4.1`) from `Drone-Age/Cosys-AirSim:indra-ue5.8`
- ArduPilot at the same commit used by `ENV_DEV_NEO_SIM2`
- Ubuntu 24.04 in WSL2
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

For the camera throughput qualification (640x480 and 1280x720, no Mission Planner):

```powershell
.\dev.ps1 camera-test
```

The qualified live path requests uncompressed RGB frames on demand with `ForceUpdate=false`. The current target is a sustained average of at least 20 FPS; PNG compression is not used in the real-time path.

Each run gets its own evidence directory under `logs`. Use `.\dev.ps1 stop` to stop only processes recorded by this environment, and `.\dev.ps1 logs` to open the newest bundle.

For a clean-machine installation, exact prerequisites, verification gates and agent handoff rules, follow [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

The v0.1 gate intentionally excludes ROS 2, VINS, migrated SIM2 terrain, gimbal and high-rate camera IMU. Those capabilities are added only after this flight loop is reliable. Camera findings and the upgrade path are recorded in [docs/CAMERA_PERFORMANCE.md](docs/CAMERA_PERFORMANCE.md).
