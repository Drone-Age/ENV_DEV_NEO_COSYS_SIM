# ENV_DEV_NEO_COSYS_SIM contribution rules

- Treat `ENV_DEV_NEO_SIM2` as a read-only reference implementation.
- Keep `third_party/Cosys-AirSim` pinned to the `indra-ue5.8` branch. Never develop against the fork's upstream-synchronised `main` branch.
- Keep all submodules pinned. A component update requires an intentional `components.lock.json` update in the same commit.
- Do not commit workstation-specific absolute paths, credentials, generated Unreal plugin files, `Binaries`, `Intermediate`, `Saved`, Derived Data, `.runtime`, or flight logs.
- One run owns one immutable `logs/<date>_<run-id>/` evidence bundle. Never append a second run to an existing bundle.
- Do not add ROS 2, VINS, terrain migration, or qualification routes to the v0.1 acceptance gate.
- AirLib and the Unreal project must use the same MSVC 14.44 toolset. UE 5.8.1 bans 14.44.0 through 14.44.35210; require 14.44.35211 or newer in the 14.44 family. Keep Windows SDK 10.0.22621 installed and explicitly select it for UnrealBuildTool.
- Prefer repository-relative paths. Discover UE and Visual Studio from the host at runtime.

## Autonomous deployment directive

When asked to deploy this repository on another workstation, follow `docs/DEPLOYMENT.md` from top to bottom and continue until the smoke-test has a PASS evidence bundle or a genuine external blocker is reached.

- Begin with read-only discovery. Never assume `C:` for Windows Kits, Visual Studio package cache, downloads, or WSL storage; use the registry, `vswhere`, and `wsl.exe`.
- Do not rely on the user's global Git line-ending policy. `setup` must leave executable ArduPilot scripts with LF endings so their WSL shebangs remain valid.
- Installation of UE through Epic Games Launcher and any UAC/sudo prompt may require the machine owner. State the exact prompt and continue with all independent work while waiting.
- Use `dev.ps1 doctor` as the machine contract. Fix each reported prerequisite, rerun it, then use `setup`, `build`, and `test` in order. Do not skip a failed gate.
- Verify actual files and versions after every installer exits. Installer exit code alone is not acceptance.
- If UE 5.8.1 compilation exposes a real Cosys source/API incompatibility, create the smallest fix in `third_party/Cosys-AirSim` on `indra-ue5.8`, test it, commit and push that fork branch, then deliberately update the parent gitlink and `components.lock.json`. Never patch the fork's `main`.
- Do not weaken UnrealBuildTool's banned-toolchain checks. Install a supported MSVC patch instead.
- Never copy Microsoft AirSim binaries or plugins from an older UE project. Always stage the plugin produced from the pinned Cosys source.
- Never open broad firewall ranges. v0.1 uses only Windows inbound UDP 9022 for the exact UnrealEditor executable and Hyper-V/WSL inbound UDP 9023 for the WSL creator/local subnet.
- Do not mark deployment complete merely because compilation succeeded. Completion requires `dev.ps1 test`, a landed/disarmed vehicle, and `summary.json` with `status: PASS`.
- Do not launch Mission Planner from `dev.ps1 test`; it is intentionally reserved for interactive `dev.ps1 run` so the automated acceptance run has no obstructing UI.
- Qualify camera throughput with `dev.ps1 camera-test`. Keep `ForceUpdate=false`, request raw RGB, and keep PNG encoding outside the real-time path. A camera change is accepted only from unique simulation timestamps, not RPC call count alone.
