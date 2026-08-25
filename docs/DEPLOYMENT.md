# Deployment on a new Windows workstation

This runbook deploys the v0.1 flight demo without using any files from `ENV_DEV_NEO_SIM2` or an old Microsoft AirSim installation. The target result is a visible Cosys Blocks flight, ArduCopter SITL telemetry in Mission Planner, and a PASS evidence bundle for `TAKEOFF -> 15 x 15 m square -> LAND`.

## 1. Host requirements

Use 64-bit Windows 11 with hardware virtualisation enabled, at least 32 GB RAM, 100 GB free disk space for UE/build products, and a current NVIDIA driver. A reboot can be required after enabling WSL or servicing Visual Studio.

Install these exact product lines:

- Epic Games Launcher and Unreal Engine **5.8.1**. The expected default path is `%ProgramFiles%\Epic Games\UE_5.8`; another path is supported through the per-session `INDRA_UE_ROOT` environment variable.
- Visual Studio 2022 **17.14**, Desktop development with C++ and Game development with C++.
- MSVC **14.44.35211 or newer** within the 14.44 toolset family. UE 5.8.1 explicitly bans 14.44.0–14.44.35210. The Visual Studio component is `Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64`.
- Windows SDK **10.0.22621.0**, component `Microsoft.VisualStudio.Component.Windows11SDK.22621`.
- CMake 3.10 or newer, Git for Windows, Git LFS, and a current NVIDIA driver.
- WSL2 enabled. `setup` imports the pinned Ubuntu 24.04.4 image as the isolated distribution `INDRA-COSYS-SIM`; do not reuse or modify the `Ubuntu` distribution owned by SIM2.

Do not install UE 5.8.0 as a workaround. Cosys-AirSim release 3.4.1 targets the UE 5.8 line and this repository qualifies the available 5.8.1 patch release. Do not disable UnrealBuildTool's compiler safety checks.

Example elevated Visual Studio component installation (adapt `--installPath` if discovery reports a different location):

```powershell
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
& $installer modify `
  --installPath 'C:\Program Files\Microsoft Visual Studio\2022\Community' `
  --add Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 `
  --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
  --passive --norestart
```

Close Visual Studio and idle MSBuild workers before servicing Visual Studio. After installation, verify the concrete folder under `VC\Tools\MSVC`; the product version shown by the installer is insufficient. Windows Kits can be installed on a non-system drive, so discover `KitsRoot10` at `HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots`.

## 2. Clone and verify source identity

Clone recursively into a short local path outside OneDrive:

```powershell
git clone https://github.com/Drone-Age/ENV_DEV_NEO_COSYS_SIM.git
Set-Location ENV_DEV_NEO_COSYS_SIM
.\dev.ps1 doctor
```

Do not begin with `--recurse-submodules` on a machine that has not authenticated for the private Drone-Age environment repositories. The default Blocks deployment initialises the complete pinned source set (Cosys-AirSim, ArduPilot, VINS-NEO, iMAVROS and vio_stack). For a private map, authenticate `gh`/Git first and select it explicitly:

```powershell
gh auth status
.\dev.ps1 setup -Environment sim2-rural
.\dev.ps1 env doctor sim2-rural -Preview
.\dev.ps1 env build-map sim2-rural
```

`env build-map` compiles the environment-owned UE editor commandlet, deterministically recreates the 4033 x 4033 World Partition map from the pinned Copernicus/Sentinel-2 inputs, then reloads it and verifies the georeference, transform, imagery material and all 1024 render/collision components. The command is safe to repeat after a clean clone. The generated `.umap`/`.uasset` files are also pinned through Git LFS so ordinary consumers do not need to regenerate them.

`sim2-rural` is currently marked `preview`. Normal `build`, `run` and flight tests reject it; an engineering validation must opt in with `-Preview`, which is recorded in `summary.json` and cannot promote readiness. `env doctor sim2-rural -Preview` validates package integrity, while `env build-map` is the structural acceptance command. The first clean map build can spend several minutes compiling UE shaders; wait while UnrealEditor-Cmd/ShaderCompileWorker remain active and require the final reload verifier PASS.

The current preview supports a full 15 m square flight directly on the streamed DEM. The temporary pad is removed; runtime traces at 150 m and 500 m hit Landscape collision. The asynchronous raw Scene path passes 20-second tests at 20.50 FPS for 640 x 480 and 20.49 FPS for 1280 x 720 with zero duplicate timestamps. Saved-frame gates also prove that both resolutions return non-uniform image content. Keep `readiness: preview` until full-extent seam/landing probes, vegetation and the remaining environment gates pass.

Private environment datasets use Git LFS. After setup, verify that raster files are real PNGs rather than pointer text:

```powershell
git -C environments\sim2-rural lfs pull
.\dev.ps1 env list
```

Expected `env list` state is `preview` for `sim2-rural`. To prove that the checked-out binary map matches its source contract, rerun `env build-map`; a PASS reports World Partition, EPSG:32636, Sentinel-2 material, 1024 Landscape components and 1024 collision components.

The VINS qualification test repositories are separate from the source components and are not needed for v0.1. Initialise them only on a qualification workstation:

```powershell
git submodule update --init -- tests/vins_climb_unit tests/vins_10km_unit
git submodule status tests/vins_climb_unit tests/vins_10km_unit
```

Their expected commits are recorded in `tests/test-registry.json`. Until `dev.ps1 capabilities -Json` reports the required ROS/VINS/camera-IMU/wind features, their launch is expected to stop before starting Unreal.

The expected source identities are enforced by `components.lock.json`:

- `third_party/Cosys-AirSim` at `5829c0ab18a8800399b43ecfeb921e627b48a625`, fork branch `indra-ue5.8`, based on release `5.8-v3.4.1`.
- `third_party/ardupilot` at `ebceaa75aa175c6b6b52f69a8da8337e2919d62b`.
- `third_party/VINS-NEO` at `0c09aecfebbe7b6bcdd55a3697aef6ba76ececc1`, branch `indra-sim2-compat`.
- `third_party/iMAVROS` at `2bbd27b1a7b40bbf000d664b058f09b5db9dd518`.
- `third_party/vio_stack` at `eb2cc542a0457759b208c27d324556c80cf6a1b6`, branch `indra-sim2-compat`; nested iHUB is `12b249a8d1bb711639997d6b354794a76958177f`.

The vio_stack lock also verifies its exact nested iHUB, iHUB-STM, iCAM and iIMU revisions. Compatibility branches publish the previously local SIM2 commits without changing any component's `main` branch.

The compatibility iHUB server supports a Cosys camera servo backend over `simSetCameraPose` and publishes its applied angle/rate as `/camera/tilt/joint_state`. The Cosys bridge uses that authoritative state to rotate the original timestamped CameraImu samples into the moving camera frame. This preserves the SIM2 UART/calibration and `/camera/tilt/*` contracts; it is not a VINS acceptance claim until the live gimbal and camera-IMU motion gates pass.

Do not continue while `doctor` reports a failure. A Mission Planner warning before `setup` is expected.

## 3. Prepare runtime dependencies

```powershell
.\dev.ps1 setup
.\dev.ps1 doctor
```

`setup` performs these reproducible actions:

- downloads the official pinned Ubuntu 24.04.4 WSL image, verifies its SHA-256, imports `INDRA-COSYS-SIM` beside the repository under `F:\JANUS\WSL` (or the matching parent drive), and creates its non-root `indra` user;
- restores every nested submodule and rechecks the pinned commits;
- enforces LF entrypoints inside `third_party/ardupilot` and nested iHUB, independent of the user's global Git `core.autocrlf` setting;
- downloads Mission Planner 1.3.83 portable and verifies SHA-256 before extraction;
- validates or installs the headless ArduPilot Ubuntu toolchain and `~/venv-ardupilot` Python environment (MAVProxy/wxPython GUI packages are intentionally omitted because Mission Planner is the optional Windows observer);
- installs the `rpc-msgpack` client used by the reproducible Cosys camera benchmark;
- installs the pinned official ROS apt-source bootstrap and stock ROS 2 Jazzy base/message packages under `/opt/ros/jazzy` inside `INDRA-COSYS-SIM`;
- prepares `colcon`, `rosdep`, Eigen, Ceres, OpenCV, serial dependencies and the EGM96-5 GeographicLib geoid required by MAVROS for the pinned source-built VINS overlay;
- creates two narrow rules required by current WSL networking: Windows inbound UDP 9022 for UnrealEditor, and Hyper-V/WSL inbound UDP 9023 for the WSL creator. No port range is opened.

It also initialises the selected environment submodule recursively. `blocks` is built into the parent and requires no private checkout. Environment commits are pinned in `environments.lock.json`.

The isolated `indra` development user has passwordless sudo only inside `INDRA-COSYS-SIM`, allowing an agent to complete a clean deployment without modifying the old SIM2 distribution. Windows can ask for UAC consent for the firewall rules. The Windows rule applies to the exact UnrealEditor executable and UDP 9022; the Hyper-V rule applies only to WSL, UDP 9023, and the local subnet. These are expected security boundaries, not reasons to broaden permissions.

## 4. Build all four layers

Close Unreal Editor and Visual Studio, then run:

```powershell
.\dev.ps1 build
```

The build order is:

1. Cosys-AirSim/AirLib in Release with the selected MSVC 14.44 patch.
2. Generated AirSim plugin staged into `unreal\IndraCosysDemo\Plugins\AirSim` (ignored by Git).
3. `IndraCosysDemoEditor` for UE 5.8.1, Development/Win64, Windows SDK 10.0.22621.0, explicitly enabling the selected environment plugin so a clean clone cannot depend on a stale DLL.
4. ArduCopter SITL in Ubuntu 24.04.
5. Pinned iMAVROS, VINS-NEO, iHUB, VINS initializer and vision bridge source overlay under `.runtime/vins-overlay-jazzy`.

Generated plugin files, `Binaries`, `Intermediate`, `Saved`, Derived Data and `.runtime` must remain untracked. On HDD-based workspaces, place disposable Unreal `Intermediate` and Derived Data caches on SSD/NVMe when possible; a single AirSim unity unit took about 22 minutes on the reference SATA disk.

## 5. Interactive demo

```powershell
.\dev.ps1 run
```

The launcher discovers the current WSL and Windows host IPs on every run and writes a run-local `settings.json`. It explicitly selects `ScalableClock` with `ClockSpeed=1`: Cosys otherwise assigns its SimpleFlight-oriented `SteppableClock` default to ArduCopter and can fall below real time when the 3 ms physics loop is saturated. Interactive `run` starts Unreal first, ArduCopter SITL second and Mission Planner last. Automated `test` deliberately does not open Mission Planner; its controller owns TCP 5780 while the already-verified observer UI stays out of the way. Neither command reads or writes `Documents\AirSim\settings.json`.

The default is the deterministic Blocks qualification profile. Environment and rendering choices are explicit and included in `summary.json`:

```powershell
.\dev.ps1 run -Environment blocks -RenderProfile qualification
.\dev.ps1 test -Environment blocks -RenderProfile qualification
```

Never use a visual/Cesium profile as qualification evidence.

Expected isolated endpoints for SITL instance 2:

| Purpose | Endpoint |
|---|---:|
| Cosys rotor control | UDP 9022 |
| SITL sensors | UDP 9023 |
| MAVLink/controller | TCP 5780 |
| Mission Planner | TCP 5782 |
| Cosys RPC | TCP 41452 |
| ROS 2 Jazzy domain | 44 |

Stop only the processes recorded for this environment:

```powershell
.\dev.ps1 stop
```

## 6. Acceptance test

```powershell
.\dev.ps1 test
```

PASS requires all of the following: MAVLink heartbeat, continuing sensor/position exchange, healthy EKF, successful ARM, all route points, LAND and DISARM without a crash or timeout. Each attempt owns one immutable `logs\<date>_<run-id>\` directory containing generated settings, Unreal/SITL/controller logs, DataFlash/runtime state, parameters, the generated mission and `summary.json`. Mission Planner logs are included only for interactive `run` sessions.

Open the newest bundle with:

```powershell
.\dev.ps1 logs
```

Do not tag `v0.1.0` unless `summary.json` says `PASS`. Validate visible Unreal flight and Mission Planner telemetry separately with `dev.ps1 run`; Mission Planner is not opened by the automated test.

### ROS 2 topic and flight regression

After the ordinary flight PASS, verify the optional SIM2-compatible sensor graph:

```powershell
.\dev.ps1 ros-test -Environment blocks -SkipBuild
.\dev.ps1 vins-test -Environment blocks -SkipBuild
.\dev.ps1 test -Environment blocks -SkipBuild -WithRos2
```

The first command requires all six topics, exact frame IDs, strictly increasing simulation timestamps, valid 640x480 RGB8 payload/calibration and synchronized image metadata. Both IMU feeds must remain within 190-210 Hz in wall and simulation time, camera-nearest-IMU p95 must be at most 5 ms, and the bridge must report zero history overflow/error. Clock/odom require at least 20 wall Hz and image/camera-info at least 10 wall Hz. The second command repeats the full flight with the bridge active and applies the same transport-integrity checks. Neither command launches Mission Planner. The isolated distribution always prefers stock `/opt/ros/jazzy`; legacy callers may still pass `-Distro Ubuntu`, which is accepted only as an argument alias and resolves to the pinned `INDRA-COSYS-SIM` runtime.

`vins-test` is the first VINS acceptance gate. It requires the complete iHUB 0-90 degree sweep, moving-frame CameraImu evidence, at least 15 tracked features, VINS initializer READY, fresh ExternalNav READY and `/mavros/odometry/out`. It never launches Mission Planner and stores its verdict under the run's `vins/` evidence directory.

The reserved ports allow functional SIM2/NewSIM coexistence, but rate qualification must run without a competing Gazebo, VINS, rosbag or GPU-heavy job on the same workstation. Such a load changes wall cadence and invalidates performance evidence; it is not a reason to stop another user-owned simulation. Evidence `2026-08-25_075418_test_91c0c67e` was completed before the concurrent SIM2 VINS-climb run began.

Do not change WSL networking while SIM2 or NewSIM is running. A controlled camera-transport A/B experiment is available only after both stacks are stopped:

```powershell
.\scripts\wsl-network-mode.ps1 -Action Status
.\scripts\wsl-network-mode.ps1 -Action EnableMirrored
.\dev.ps1 doctor
# repeat flight, ros-test and camera-test evidence
.\scripts\wsl-network-mode.ps1 -Action Restore
```

The helper backs up the exact previous `.wslconfig`, refuses to shut WSL down when simulator processes are present and refuses to overwrite later user edits during rollback. Mirrored mode is not a deployment prerequisite and must not be promoted without flight, UDP/TCP, ROS and camera evidence.

## 7. Camera qualification

Run the two supported resolutions without Mission Planner:

```powershell
.\dev.ps1 camera-test
```

The live profile is Scene image type, raw RGB, `ForceUpdate=false`, Lumen GI/reflections disabled for the sensor capture, a 640x360 diagnostic viewport, the fork's 30 Hz asynchronous GPU-readback producer and a 25 Hz ROS publish cap. Acceptance is at least 20 unique frames/s at 640x480 and 10 unique frames/s at 1280x720. The current live-SITL Blocks evidence measured 26.77 and 24.03 FPS respectively, with 18.5 FPS in the worst 1280x720 two-second window and zero duplicate timestamps. Every run analyzes early/late raw frames and rejects black or uniform content; `-SaveSamples` additionally preserves those frames as PPM artifacts. The viewport size does not change sensor output resolution. Do not use PNG compression in a control or VINS path; the measured 1280x720 PNG rate was only 6.89 FPS, so encoding and recording belong asynchronously downstream. See [CAMERA_PERFORMANCE.md](CAMERA_PERFORMANCE.md) for measured results and implementation details.

Do not add `-RenderOffscreen` to the normal acceptance run. It reduced camera throughput on the qualified workstation and can also reduce simulation timing margin. It remains an explicit `-Headless` diagnostic option only.

## 8. UE 5.8.1 compatibility fixes

UE 5.8.0 is not required. If UE 5.8.1 reports C++ API errors after the supported compiler is installed, make the fix in the Cosys fork only:

```powershell
Set-Location third_party\Cosys-AirSim
git switch indra-ue5.8
# implement and test the smallest compatibility patch
git commit
git push origin indra-ue5.8
```

Then return to the parent repository, update the Cosys commit in `components.lock.json`, stage the new submodule gitlink, rebuild from clean generated state if required, and rerun the full smoke test. Keep `Drone-Age/Cosys-AirSim:main` synchronised with upstream and untouched by INDRA patches.

## 9. Troubleshooting order

1. Run `doctor`; resolve machine-contract failures first.
2. Inspect the newest evidence bundle and UnrealBuildTool log.
3. Confirm exact MSVC folder/version and `KitsRoot10` rather than relying on installer labels.
4. Confirm ports are free and WSL IP discovery still matches the active distribution.
5. Confirm both submodule commits before changing source.
6. Only then classify an error as Cosys/UE 5.8.1 source incompatibility and patch the fork branch.

## 10. Autonomous-agent deployment directive

An agent deploying this repository on another workstation must treat this document, `components.lock.json`, `environments.lock.json` and `tests/test-registry.json` as the machine-readable contract. It may install missing in-scope build dependencies and regenerate ignored build products, but must not convert old Unreal projects in place, copy Microsoft AirSim binaries, modify the old SIM2 WSL distribution, change pinned commits silently, or claim a capability without its evidence gate.

Required unattended order:

1. Clone outside OneDrive and run `dev.ps1 doctor`; record every blocking prerequisite.
2. Install or finish UE 5.8.1, VS 2022 17.14, the supported MSVC 14.44 patch and Windows SDK 22621, then repeat `doctor`.
3. Run `dev.ps1 setup`. A fresh machine must end with default user `indra` in `INDRA-COSYS-SIM`, `/opt/ros/jazzy`, `~/venv-ardupilot`, exact component commits and no changes to the distribution named `Ubuntu`.
4. Run `dev.ps1 build`, then the smallest acceptance sequence: `test`, `ros-test`, `vins-test`. Automated commands must not launch Mission Planner.
5. Initialise qualification tests and private environments only when their prior capability gates pass. Preview environments require explicit `-Preview` and cannot provide release evidence.
6. On failure, preserve the run bundle and logs, fix the smallest owning layer, rebuild, and rerun the failed gate plus all earlier gates that the change could affect.
7. Push a component change to its designated compatibility branch first, update its parent lock and submodule gitlink together, and push the parent last. Never modify upstream-synchronised `main` branches.

The agent stops only for missing credentials or licences, an unavailable required installer, a Windows elevation prompt it cannot satisfy, or a hardware/driver failure. It must report the exact failed gate and artifact path instead of replacing the gate with a weaker test.
