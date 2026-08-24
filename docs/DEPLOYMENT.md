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
git clone --recurse-submodules https://github.com/Drone-Age/ENV_DEV_NEO_COSYS_SIM.git
Set-Location ENV_DEV_NEO_COSYS_SIM
git submodule update --init --recursive
.\dev.ps1 doctor
```

The expected source identities are enforced by `components.lock.json`:

- `third_party/Cosys-AirSim` at `a552dd6cd517b8d5d26629ad88004356c3007326`, fork branch `indra-ue5.8`, release `5.8-v3.4.1`.
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

Ubuntu can ask for its `sudo` password during first-time package installation. Windows can ask for UAC consent for the firewall rules. The Windows rule applies to the exact UnrealEditor executable and UDP 9022; the Hyper-V rule applies only to WSL, UDP 9023, and the local subnet. These are expected security boundaries, not reasons to broaden permissions.

## 4. Build all three layers

Close Unreal Editor and Visual Studio, then run:

```powershell
.\dev.ps1 build
```

The build order is:

1. Cosys-AirSim/AirLib in Release with the selected MSVC 14.44 patch.
2. Generated AirSim plugin staged into `unreal\IndraCosysDemo\Plugins\AirSim` (ignored by Git).
3. `IndraCosysDemoEditor` for UE 5.8.1, Development/Win64, Windows SDK 10.0.22621.0.
4. ArduCopter SITL in Ubuntu 24.04.

Generated plugin files, `Binaries`, `Intermediate`, `Saved`, Derived Data and `.runtime` must remain untracked.

## 5. Interactive demo

```powershell
.\dev.ps1 run
```

The launcher discovers the current WSL and Windows host IPs on every run and writes a run-local `settings.json`. Interactive `run` starts Unreal first, ArduCopter SITL second and Mission Planner last. Automated `test` deliberately does not open Mission Planner; its controller owns TCP 5780 while the already-verified observer UI stays out of the way. Neither command reads or writes `Documents\AirSim\settings.json`.

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

The live profile is Scene image type, raw RGB, `ForceUpdate=false`, Lumen GI/reflections disabled for the sensor capture, a 640x360 diagnostic viewport, and one request in flight. Acceptance is a sustained average of at least 20 unique frames/s. The viewport size does not change the 640x480 or 1280x720 sensor output. Do not use PNG compression in a control or VINS path; encode or record frames asynchronously downstream. See [CAMERA_PERFORMANCE.md](CAMERA_PERFORMANCE.md) for measured results and the source-level bottleneck.

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
