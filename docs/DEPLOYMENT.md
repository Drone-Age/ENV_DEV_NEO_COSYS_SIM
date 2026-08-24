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
- WSL2 distribution named `Ubuntu`, Ubuntu 24.04 LTS.

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

Do not begin with `--recurse-submodules` on a machine that has not authenticated for the private Drone-Age environment repositories. The default Blocks deployment initialises only the two public source dependencies. For a private map, authenticate `gh`/Git first and select it explicitly:

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

The VINS qualification repositories are also private and are not needed for v0.1. Initialise them only on a qualification workstation:

```powershell
git submodule update --init -- tests/vins_climb_unit tests/vins_10km_unit
git submodule status tests/vins_climb_unit tests/vins_10km_unit
```

Their expected commits are recorded in `tests/test-registry.json`. Until `dev.ps1 capabilities -Json` reports the required ROS/VINS/camera-IMU/wind features, their launch is expected to stop before starting Unreal.

The expected source identities are enforced by `components.lock.json`:

- `third_party/Cosys-AirSim` at `d2ddee2141dfb3fc007cfdbba90ac240a15acf3e`, fork branch `indra-ue5.8`, based on release `5.8-v3.4.1`.
- `third_party/ardupilot` at `ebceaa75aa175c6b6b52f69a8da8337e2919d62b`.

Do not continue while `doctor` reports a failure. A Mission Planner warning before `setup` is expected.

## 3. Prepare runtime dependencies

```powershell
.\dev.ps1 setup
.\dev.ps1 doctor
```

`setup` performs these reproducible actions:

- restores every nested submodule and rechecks the pinned commits;
- enforces an LF checkout inside `third_party/ardupilot`, independent of the user's global Git `core.autocrlf` setting;
- downloads Mission Planner 1.3.83 portable and verifies SHA-256 before extraction;
- validates or installs the ArduPilot Ubuntu toolchain and `~/venv-ardupilot` Python environment;
- installs the `rpc-msgpack` client used by the reproducible Cosys camera benchmark;
- creates two narrow rules required by current WSL networking: Windows inbound UDP 9022 for UnrealEditor, and Hyper-V/WSL inbound UDP 9023 for the WSL creator. No port range is opened.

It also initialises the selected environment submodule recursively. `blocks` is built into the parent and requires no private checkout. Environment commits are pinned in `environments.lock.json`.

Ubuntu can ask for its `sudo` password during first-time package installation. Windows can ask for UAC consent for the firewall rules. The Windows rule applies to the exact UnrealEditor executable and UDP 9022; the Hyper-V rule applies only to WSL, UDP 9023, and the local subnet. These are expected security boundaries, not reasons to broaden permissions.

## 4. Build all three layers

Close Unreal Editor and Visual Studio, then run:

```powershell
.\dev.ps1 build
```

The build order is:

1. Cosys-AirSim/AirLib in Release with the selected MSVC 14.44 patch.
2. Generated AirSim plugin staged into `unreal\IndraCosysDemo\Plugins\AirSim` (ignored by Git).
3. `IndraCosysDemoEditor` for UE 5.8.1, Development/Win64, Windows SDK 10.0.22621.0, explicitly enabling the selected environment plugin so a clean clone cannot depend on a stale DLL.
4. ArduCopter SITL in Ubuntu 24.04.

Generated plugin files, `Binaries`, `Intermediate`, `Saved`, Derived Data and `.runtime` must remain untracked. On HDD-based workspaces, place disposable Unreal `Intermediate` and Derived Data caches on SSD/NVMe when possible; a single AirSim unity unit took about 22 minutes on the reference SATA disk.

## 5. Interactive demo

```powershell
.\dev.ps1 run
```

The launcher discovers the current WSL and Windows host IPs on every run and writes a run-local `settings.json`. Interactive `run` starts Unreal first, ArduCopter SITL second and Mission Planner last. Automated `test` deliberately does not open Mission Planner; its controller owns TCP 5780 while the already-verified observer UI stays out of the way. Neither command reads or writes `Documents\AirSim\settings.json`.

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
| Reserved future ROS domain | 44 |

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

## 7. Camera qualification

Run the two supported resolutions without Mission Planner:

```powershell
.\dev.ps1 camera-test
```

The live profile is Scene image type, raw RGB, `ForceUpdate=false`, Lumen GI/reflections disabled for the sensor capture, a 640x360 diagnostic viewport, and the fork's 21 Hz asynchronous GPU-readback producer. Acceptance is at least 20 unique frames/s at 640x480 and 10 unique frames/s at 1280x720. Every run analyzes early/late raw frames and rejects black or uniform content; `-SaveSamples` additionally preserves those frames as PPM artifacts. The viewport size does not change sensor output resolution. Do not use PNG compression in a control or VINS path; encode or record frames asynchronously downstream. See [CAMERA_PERFORMANCE.md](CAMERA_PERFORMANCE.md) for measured results and implementation details.

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
