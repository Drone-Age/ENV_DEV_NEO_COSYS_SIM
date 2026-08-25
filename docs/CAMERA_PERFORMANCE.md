# Cosys camera throughput on UE 5.8.1

## Qualified target

INDRA acceptance requires at least 20 FPS at 640x480 and at least 10 FPS at 1280x720. The asynchronous path has already demonstrated approximately 20.5 FPS at both resolutions. The 1280x720 release floor remains 10 FPS so later scene-quality work cannot silently turn the demonstrated 20 Hz into a hard dependency. The live sensor path therefore uses:

- one Scene camera;
- 640x480 or 1280x720;
- uncompressed RGB returned by `simGetImages`;
- `ForceUpdate=false`, a 30 Hz asynchronous GPU producer and a 25 Hz ROS publish cap;
- Lumen GI and Lumen reflections disabled for the sensor capture;
- PNG/JPEG encoding, display and recording performed asynchronously downstream.
- a 640x360 operator/diagnostic viewport during qualification (sensor resolution is unchanged).

Run `./dev.ps1 camera-test` to create fresh evidence bundles. Mission Planner is never launched by this test. Count unique `time_stamp` values; repeated RPC responses must not be counted as new frames. The benchmark also reports p50/p95/p99/max delivery and simulation intervals plus the worst full two-second delivery window. A run fails if that window drops below 10 unique FPS, even if its whole-run average is high.

## Measurements on the reference workstation

The reference machine is Ryzen 5 8400F, RTX 5060 Ti 16 GB, UE 5.8.1 and Cosys Blocks. Each case used one sequential RPC request at a time with a live ArduCopter SITL peer.

| Mode | Resolution | Format | Unique FPS | Mean latency |
|---|---:|---:|---:|---:|
| Async GPU readback, SIM2 Rural, 20 s | 640x480 | raw RGB | 20.50 | 48.77 ms |
| Async GPU readback, SIM2 Rural, 20 s | 1280x720 | raw RGB | 20.49 | 48.78 ms |
| Async GPU readback + pixel gate | 1280x720 | raw RGB | 19.80 | 50.42 ms |
| Async, Windows-native client, monotonic fix + cadence gate | 1280x720 | raw RGB | 20.56 | 48.56 ms |
| Async, WSL2 NAT client, cadence gate | 1280x720 | raw RGB | 15.00 | 66.86 ms |
| Async, WSL2 NAT, named IMUs removed (A/B) | 1280x720 | raw RGB | 14.38 | 69.79 ms |
| ROS 2 Jazzy over WSL2 NAT, repeat | 640x480 | raw RGB | 18.16 wall / 15.0 worst 2 s | live-depth probe |
| ROS 2 Jazzy over WSL2 NAT, best repeat | 640x480 | raw RGB | 21.20 wall / 19.0 worst 2 s | live-depth probe |
| ROS 2 bridge during complete square flight | 640x480 | raw RGB | 23.31 wall | 2,852 frames |
| Final 30 Hz producer, WSL2 NAT | 640x480 | raw RGB | 28.06 / 27.5 worst 2 s | 562 unique, 0 duplicates |
| Final 30 Hz producer, WSL2 NAT | 1280x720 | raw RGB | 26.73 / 25.0 worst 2 s | 537 unique, 0 duplicates |
| ROS 2 + batched IMU strict gate | 640x480 | raw RGB | 21.76 / 19.5 worst 2 s | IMU p95 2.89 ms |
| ROS 2 + batched IMU full square flight | 640x480 | raw RGB | 24.35 wall | TAKEOFF/LAND/DISARM PASS |
| On demand | 640x480 | raw RGB | 21.96-23.64 | 42.29-45.54 ms |
| On demand, 1280x720 viewport | 1280x720 | raw RGB | 19.10-20.31 | 49.22-52.36 ms |
| On demand, 640x360 viewport | 1280x720 | raw RGB | 20.25 | 49.37 ms |
| On demand | 1280x640 | raw RGB | 20.14 | 49.65 ms |
| On demand | 640x480 | PNG | 15.58 | 64.16 ms |
| On demand | 1280x720 | PNG | 7.65 | 130.69 ms |
| `ForceUpdate=true` | 640x480 | raw RGB | 12.41 | 80.60 ms |
| `ForceUpdate=true` | 1280x720 | raw RGB | 11.88 | 84.14 ms |
| Render offscreen | 1280x720 | raw RGB | 15.85 | 63.10 ms |
| SIM2 Rural preview | 640x480 | raw RGB | 20.74 | see evidence bundle |
| SIM2 Rural preview | 1280x720 | raw RGB | 15.33 | see evidence bundle |
| SIM2 Rural preview, repeated baseline | 1280x720 | raw RGB | 17.65 | 56.66 ms |
| SIM2 Rural preview, 320x240 viewport | 1280x720 | raw RGB | 17.28 | 57.86 ms |
| SIM2 Rural preview, strict repeat | 640x480 | raw RGB | 18.62 | 53.69 ms |

The asynchronous rural runs used 411/411 unique frames at 640x480 and 410/410 at 1280x720, with no duplicate timestamps. A separate 1280x720 sample run measured pixel ranges 79-239 and 91-245 with standard deviations 51.09 and 43.32, proving that throughput did not hide a black buffer. Re-run qualification after scene, lighting, driver, camera count or capture-layer changes.

The old 15.33 FPS result is therefore a historical synchronous-path measurement, not the current ceiling. For 1280x720 the hard release floor is 10 unique FPS in every complete two-second window, while stable 20 Hz remains the engineering target. A whole-run average above 10 FPS is insufficient if short stalls violate that window gate.

The final 30 Hz producer runs also sampled the GPU. At 640x480 it averaged 40% utilisation (49% maximum), used at most 5,611 MiB VRAM and averaged 50.8 W. At 1280x720 it averaged 45.7% (59% maximum), used at most 5,635 MiB and averaged 62.5 W. The 1280x720 raw path delivered 26.73 FPS while PNG delivery from the same run was only 6.56 FPS. These values show substantial GPU and VRAM headroom and isolate synchronous readback/CPU compression as the original bottlenecks; changing the GPU or forcing maximum graphics quality is not justified by current evidence.

The earlier cadence repeat exposed an important transport distinction. Before the dedicated UE 5.8.1 render-target/cold-start repair, the Windows-native client delivered 20.56 FPS while WSL2 NAT delivered 15.00 FPS and once fell to 8.5 FPS in its worst window. The final producer now delivers 28.06 FPS at 640x480 and 26.73 FPS at 1280x720 over the same WSL2 NAT route, with worst windows of 27.5 and 25.0 FPS. The raw-RPC transport is therefore qualified at both resolutions. The 1280x720 ROS/VINS end-to-end path remains a separate pending gate because ROS serialization and VINS processing are not exercised by this benchmark.

The instrumented synchronous rural repeat reached 17.65 unique FPS with zero duplicate timestamps. RTX 5060 Ti utilization averaged 39.46%, reached 46% maximum, and averaged 48.84 W against a 180 W board limit. Reducing the operator viewport again from 640x360 to 320x240 slightly reduced throughput to 17.28 FPS, so 640x360 remains the qualified viewport. These measurements rule out GPU saturation and operator viewport fill rate as the primary bottleneck on the reference workstation. The host is already on the Windows High performance plan; the installed GPU is an RTX 5060 Ti 16 GB with a 180 W limit. Driver or NVIDIA power-policy changes are therefore controlled experiments, not the primary fix.

A historical synchronous 640x480 repeat produced 18.62 unique FPS and motivated the fork change. The strict gate is now passed by the asynchronous implementation without weakening the 20 FPS threshold.

Evidence bundles from this measurement remain local under `logs/` and are intentionally not committed.

## Root cause and implemented fix

This is not primarily a WSL networking problem. A Windows-native client measured 22.51 FPS at 640x480 versus 23.64 FPS from WSL.

The stock Cosys/AirSim request path is synchronous. `RenderRequest.cpp` schedules capture on Unreal's game thread, waits for the render command, calls `ReadSurfaceData` to copy the GPU render target into CPU memory, repacks pixels into an RGB vector and optionally compresses PNG on the CPU. `UnrealImageCapture.cpp` waits for that operation before returning the RPC response. With only one request in flight, frame rate is consequently bounded by end-to-end request latency.

`Drone-Age/Cosys-AirSim:indra-ue5.8` now has an opt-in producer enabled with `-IndraAsyncCamera -IndraCameraName=0 -IndraCameraHz=30 -IndraCameraWidth=640 -IndraCameraHeight=480`. It owns a capture-component-scoped render target, schedules `CaptureSceneDeferred` from the viewport, resolves the texture only on Unreal's render thread, uses three `FRHIGPUTextureReadback` slots, and publishes the latest completed raw RGB frame with its original simulation timestamp. During cold start, supported requests receive an explicit empty warm-up response instead of falling back to the blocking stock renderer. Unsupported request types still fall back to stock Cosys. Explicit `SRVMask -> CopySrc -> SRVMask` transitions prevent zero-filled D3D12 copies, and readback resources are recreated when render-target dimensions or format change.

The dedicated target fixes a UE 5.8.1 lifecycle race: Cosys can replace its transient `TextureTarget` after `UnrealImageCapture` is constructed, and `GameThread_GetRenderTargetResource()` must not be dereferenced on the game thread. The producer keeps a stable owned target and performs `GetRenderTargetTexture()` inside the render command. Evidence `2026-08-25_064408_test_17bb9394` passed every ROS contract at 18.16 wall FPS with a 15 FPS worst two-second window. The full flight `2026-08-25_064520_test_1220bb93` passed TAKEOFF, all square waypoints, LAND and DISARM while the bridge sustained 23.31 image FPS with no camera RPC error.

`ForceUpdate=true` is not a fix. In `PIPCamera.cpp` it enables `bCaptureEveryFrame` and `bCaptureOnMovement`; the benchmark shows that this competes with explicit image requests and reduces throughput. Render-offscreen also reduced throughput on this UE 5.8.1 build and is not part of the qualified profile.

The frequently cited Cosys issue #82 reproduces the scene dependence directly: Blocks was around 20 FPS, while CityPark/ElectricDreams dropped to 2-3 FPS when Scene and DepthPlanar were requested together. The comment workaround disables `bCaptureEveryFrame` and `bCaptureOnMovement` for every `SceneCapture2D`; its author reported viewport FPS increasing from 10-12 to 58-63, but also reported a stall while collecting images, and the original reporter later could not reproduce the improvement. It is therefore a useful duplicate-rendering check, not a complete sensor-throughput fix. INDRA already satisfies that check through `ForceUpdate=false` and performs capture at an explicit 30 Hz with a 25 Hz ROS publication cap.

The project already sets `bThrottleCPUWhenNotForeground=False` in `DefaultEditorPerProjectUserSettings.ini`, matching the Cosys custom-environment guidance. The Windows host also uses the High performance power plan. Do not treat either setting as a hypothetical fix: keep them enabled, then use `gpu-metrics.csv` from each benchmark bundle to determine whether the run is GPU-saturated. Low or intermittent GPU utilization together with high RPC latency points to the synchronous render/readback pipeline, not insufficient shader throughput.

## Options evaluated

1. **Use the asynchronous raw RPC path.** This is now the qualified default for the INDRA launchers and passes both supported resolutions.
2. **Reduce only the operator viewport.** A 640x360 viewport improved Blocks while preserving sensor resolution. Test 320x240 as an additional reversible profile; retain it only if evidence shows a repeatable gain and operator usability remains acceptable.
3. **Reduce sensor render cost without changing geometry.** Keep Lumen GI/reflections, motion blur, depth of field and expensive post effects disabled on the qualification camera. Any scalability or show-flag change must be checked for VINS feature count and photometric consistency before adoption.
4. **Avoid duplicate rendering modes.** Keep `ForceUpdate=false`; Unreal documents that manual capture must not be combined with `bCaptureEveryFrame`. `-RenderOffscreen` and PNG already measured worse here and are rejected for the real-time path.
5. **Keep compression downstream.** Raw capture is now decoupled from the stock blocking readback. PNG remains CPU-bound at about 8.85 FPS for 1280x720 and is diagnostic only.

## Ranked follow-up variants

1. **Harden the current asynchronous RPC path (selected).** Measure cadence tails, Unreal game/render/RHI threads, GPU frame time, VRAM and clock/power state during a full flight. Keep a 30 Hz producer, 25 Hz ROS cap and latest-frame semantics; do not let a slow subscriber back-pressure simulation.
2. **WSL mirrored-network A/B test (next, reversible).** The host is currently in default NAT mode and has no `%UserProfile%\.wslconfig`. On supported Windows 11/WSL builds, test `networkingMode=mirrored` and `127.0.0.1` against the same NAT evidence. This requires `wsl --shutdown`, can affect SIM2 networking, and is therefore opt-in until both flight and camera gates pass. Do not promote it from one throughput result; also verify SITL UDP, MAVLink and ROS discovery/firewall behaviour.
3. **Qualification render profile.** Keep one Scene layer, `ForceUpdate=false`, no sensor Lumen GI/reflections, no motion blur/depth of field and no synchronous PNG. Reduce shadows, translucency or foliage only when Unreal Insights/GPU timing identifies them and VINS feature/photometric tests remain green.
4. **Packaged Development executable.** Compare it with `UnrealEditor -game` under the exact same scene, route and camera gate. Adopt it for qualification only if it measurably reduces jitter and preserves diagnostics/deployment reproducibility.
5. **Windows-native camera relay / native ROS 2 publisher.** The native client already proves 20 FPS. If mirrored networking does not close the gap, keep the Cosys consumer on Windows and forward bounded timestamped frames to ROS 2, or publish from a C++ bridge. Avoid an additional render and avoid pure-Python per-pixel copies.
6. **Shared-memory or purpose-built streaming transport.** If DDS/raw forwarding still copies too much, evaluate a bounded ring and a transport optimized for large frames. Cross-OS shared memory is not assumed to be transparent under WSL2; it needs its own latency, loss and shutdown tests.
7. **NVENC/GStreamer stream.** Useful for Mission Planner-like viewing, remote operation and recording at 720p/1080p. It is not the primary VINS feed because encoding/decoding adds latency and can alter features. Qualify it as a separate operator stream; lossless NVENC is an experiment, not an assumed VINS replacement.
8. **Multiple render layers/cameras.** Schedule only requested layers, stagger captures where simultaneity is not required, and batch truly simultaneous requests. Every added Scene/depth/segmentation capture gets its own rate and GPU-budget gate.

## Post-flight investigation gate

Camera transport optimization starts only after a successful automated `TAKEOFF -> route -> LAND -> DISARM` flight. That prerequisite is already evidenced by the rural flight bundles listed in `ROADMAP.md`; Mission Planner is not launched by any camera experiment.

Run the alternatives against the same 1280x720 Scene feed, 20-second duration, route, render profile and 30 Hz producer. Preserve a baseline bundle before each system-level change and test in this order:

1. **Instrument, do not tune blindly.** Capture Unreal Insights timing for game/render/RHI threads, `stat unit`, `stat gpu`, `stat rhi`, GPU clocks/utilization/power, RPC latency and network throughput. A high GPU frame time selects render-profile work; low GPU occupancy plus high delivery latency selects transport work.
2. **WSL2 NAT versus mirrored networking.** Compare the current Windows-host IP path with mirrored `127.0.0.1`. This is an opt-in machine change with a documented rollback and requires rechecking SITL UDP, MAVLink TCP, ROS 2 discovery and firewall behaviour after `wsl --shutdown`.
3. **Editor versus packaged Development.** Compare `UnrealEditor -game` with a packaged Development executable. Keep the packaged form only if it improves the worst-window result without losing reproducible logs or camera correctness.
4. **Windows-native bounded relay.** If WSL still stalls, receive the latest raw timestamped frame beside Unreal on Windows, then forward it to ROS 2 using a bounded queue. This avoids sending one large msgpack response through WSL NAT for every camera sample and deliberately drops superseded frames instead of back-pressuring simulation.
5. **Native C++/shared-memory transport.** If the relay still copies too much, add a versioned ring-buffer or native ROS 2 publisher to the Cosys fork. Validate shutdown recovery, overwritten-frame accounting, timestamp preservation and WSL compatibility before making it the default.
6. **Encoded operator stream only.** Evaluate NVENC/GStreamer for viewing and recording, but do not substitute it for VINS raw RGB unless feature count, photometric quality, latency and timestamp gates prove equivalence.

For every candidate, PASS requires non-black/non-uniform images, strictly increasing simulation timestamps, zero counted duplicate frames, at least 10 unique FPS in every complete two-second window at 1280x720, and no flight/EKF regression. Promotion to the preferred path additionally targets at least 18 average FPS, no p95 delivery gap above 100 ms, and stable 20 Hz during the later VINS flight. GPU/Unreal setting changes must also retain the required VINS feature count and calibration.

The mirrored-network experiment is intentionally opt-in because applying `.wslconfig` requires `wsl --shutdown`. First stop both NewSIM and the reference SIM2, then use `scripts/wsl-network-mode.ps1 -Action EnableMirrored`. The script refuses to proceed while ArduCopter, Gazebo, Cosys bridge or an active NewSIM bundle is detected, preserves the exact previous config, and makes the launchers use loopback for both control/sensor directions. Run `doctor`, the flight test, ROS topic test and both camera resolutions before drawing a conclusion. Use `-Action Restore` to return to the byte-preserved prior configuration; it refuses to overwrite a `.wslconfig` edited by the user during the experiment.

Do not use `ClockSpeed < 1` to manufacture a wall-clock FPS result: it changes the real-time meaning of the test. Do not count viewport FPS, RPC call count or repeated timestamps as sensor FPS.

The repository currently resides on the `F:` SATA HDD. Put Unreal Derived Data Cache and disposable `Intermediate` data on an SSD on machines where this is available; this materially improves builds, shader preparation and texture-streaming stutter. It is not expected to remove the steady synchronous RPC/readback ceiling, so measure it separately from sensor throughput and keep all source/submodule paths unchanged.

Primary references: [Cosys camera settings](https://github.com/Cosys-Lab/Cosys-AirSim/blob/main/docs/settings.md), [Cosys issue #82 and its capture-every-frame experiment](https://github.com/Cosys-Lab/Cosys-AirSim/issues/82#issuecomment-3187222325), [AirSim issue #1766](https://github.com/microsoft/AirSim/issues/1766), [AirSim issue #796](https://github.com/microsoft/AirSim/issues/796), [UE 5.8 performance profiling](https://dev.epicgames.com/documentation/unreal-engine/introduction-to-performance-profiling-and-configuration-in-unreal-engine), [UE 5.8 `USceneCaptureComponent2D::CaptureScene`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/USceneCaptureComponent2D/CaptureScene), [UE 5.8 `FRHIGPUTextureReadback`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/RHI/FRHIGPUTextureReadback), [Microsoft WSL networking modes](https://learn.microsoft.com/windows/wsl/networking), and [NVIDIA Video Codec SDK](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/index.html).

## Implemented fork path and next camera work

The smallest change was implemented on `Drone-Age/Cosys-AirSim:indra-ue5.8`, never on its upstream-synchronised `main`:

1. Produce camera frames at a fixed rate into a bounded latest-frame buffer.
2. Replace blocking `ReadSurfaceData` with UE asynchronous GPU readback (`FRHIGPUTextureReadback`).
3. Let RPC wait for the next completed frame and return its original simulation timestamp without initiating a render-thread readback.
4. Recreate readback staging after resolution/format changes and validate actual pixel content.
5. Keep compression and disk recording outside Unreal's synchronous capture request.

Next work is VINS/ExternalNav integration, the 1280x720 ROS/VINS gate, multiple image layers/cameras, and qualification under the final visual environment. Batched high-rate IMU transport is complete. Shared-memory/BGRA transport remains an optional optimization if RPC copying becomes the next measured bottleneck.
