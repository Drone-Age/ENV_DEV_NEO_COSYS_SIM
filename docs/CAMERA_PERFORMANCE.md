# Cosys camera throughput on UE 5.8.1

## Qualified target

INDRA acceptance requires at least 20 FPS at 640x480 and at least 10 FPS at 1280x720. Stable 20 Hz at 1280x720 remains a performance target rather than a release blocker. The live sensor path therefore uses:

- one Scene camera;
- 640x480 or 1280x720;
- uncompressed RGB returned by `simGetImages`;
- `ForceUpdate=false` and the fork's fixed-rate asynchronous producer at 21 Hz;
- Lumen GI and Lumen reflections disabled for the sensor capture;
- PNG/JPEG encoding, display and recording performed asynchronously downstream.
- a 640x360 operator/diagnostic viewport during qualification (sensor resolution is unchanged).

Run `./dev.ps1 camera-test` to create fresh evidence bundles. Mission Planner is never launched by this test. Count unique `time_stamp` values; repeated RPC responses must not be counted as new frames.

## Measurements on the reference workstation

The reference machine is Ryzen 5 8400F, RTX 5060 Ti 16 GB, UE 5.8.1 and Cosys Blocks. Each case used one sequential RPC request at a time with a live ArduCopter SITL peer.

| Mode | Resolution | Format | Unique FPS | Mean latency |
|---|---:|---:|---:|---:|
| Async GPU readback, SIM2 Rural, 20 s | 640x480 | raw RGB | 20.50 | 48.77 ms |
| Async GPU readback, SIM2 Rural, 20 s | 1280x720 | raw RGB | 20.49 | 48.78 ms |
| Async GPU readback + pixel gate | 1280x720 | raw RGB | 19.80 | 50.42 ms |
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

The instrumented rural repeat reached 17.65 unique FPS with zero duplicate timestamps. RTX 5060 Ti utilization averaged 39.46%, reached 46% maximum, and averaged 48.84 W against a 180 W board limit. Reducing the operator viewport again from 640x360 to 320x240 slightly reduced throughput to 17.28 FPS, so 640x360 remains the qualified viewport. These measurements rule out GPU saturation and operator viewport fill rate as the primary bottleneck on the reference workstation.

A historical synchronous 640x480 repeat produced 18.62 unique FPS and motivated the fork change. The strict gate is now passed by the asynchronous implementation without weakening the 20 FPS threshold.

Evidence bundles from this measurement remain local under `logs/` and are intentionally not committed.

## Root cause and implemented fix

This is not primarily a WSL networking problem. A Windows-native client measured 22.51 FPS at 640x480 versus 23.64 FPS from WSL.

The stock Cosys/AirSim request path is synchronous. `RenderRequest.cpp` schedules capture on Unreal's game thread, waits for the render command, calls `ReadSurfaceData` to copy the GPU render target into CPU memory, repacks pixels into an RGB vector and optionally compresses PNG on the CPU. `UnrealImageCapture.cpp` waits for that operation before returning the RPC response. With only one request in flight, frame rate is consequently bounded by end-to-end request latency.

`Drone-Age/Cosys-AirSim:indra-ue5.8` now has an opt-in producer enabled with `-IndraAsyncCamera -IndraCameraName=0 -IndraCameraHz=21`. It schedules `CaptureSceneDeferred`, uses three `FRHIGPUTextureReadback` slots, and publishes the latest completed raw RGB frame with its original simulation timestamp. Unsupported request types fall back to stock Cosys. Explicit `SRVMask -> CopySrc -> SRVMask` transitions prevent zero-filled D3D12 copies, and readback resources are recreated when render-target dimensions or format change.

`ForceUpdate=true` is not a fix. In `PIPCamera.cpp` it enables `bCaptureEveryFrame` and `bCaptureOnMovement`; the benchmark shows that this competes with explicit image requests and reduces throughput. Render-offscreen also reduced throughput on this UE 5.8.1 build and is not part of the qualified profile.

The project already sets `bThrottleCPUWhenNotForeground=False` in `DefaultEditorPerProjectUserSettings.ini`, matching the Cosys custom-environment guidance. The Windows host also uses the High performance power plan. Do not treat either setting as a hypothetical fix: keep them enabled, then use `gpu-metrics.csv` from each benchmark bundle to determine whether the run is GPU-saturated. Low or intermittent GPU utilization together with high RPC latency points to the synchronous render/readback pipeline, not insufficient shader throughput.

## Options evaluated

1. **Use the asynchronous raw RPC path.** This is now the qualified default for the INDRA launchers and passes both supported resolutions.
2. **Reduce only the operator viewport.** A 640x360 viewport improved Blocks while preserving sensor resolution. Test 320x240 as an additional reversible profile; retain it only if evidence shows a repeatable gain and operator usability remains acceptable.
3. **Reduce sensor render cost without changing geometry.** Keep Lumen GI/reflections, motion blur, depth of field and expensive post effects disabled on the qualification camera. Any scalability or show-flag change must be checked for VINS feature count and photometric consistency before adoption.
4. **Avoid duplicate rendering modes.** Keep `ForceUpdate=false`; Unreal documents that manual capture must not be combined with `bCaptureEveryFrame`. `-RenderOffscreen` and PNG already measured worse here and are rejected for the real-time path.
5. **Keep compression downstream.** Raw capture is now decoupled from the stock blocking readback. PNG remains CPU-bound at about 8.85 FPS for 1280x720 and is diagnostic only.

The repository currently resides on the `F:` SATA HDD. Put Unreal Derived Data Cache and disposable `Intermediate` data on an SSD on machines where this is available; this materially improves builds, shader preparation and texture-streaming stutter. It is not expected to remove the steady synchronous RPC/readback ceiling, so measure it separately from sensor throughput and keep all source/submodule paths unchanged.

Primary references: [Cosys custom environment guidance](https://github.com/Cosys-Lab/Cosys-AirSim/blob/main/docs/unreal_custenv.md), [Cosys issue #82](https://github.com/Cosys-Lab/Cosys-AirSim/issues/82), [AirSim issue #1766](https://github.com/microsoft/AirSim/issues/1766), [AirSim issue #796](https://github.com/microsoft/AirSim/issues/796), [UE 5.8 `USceneCaptureComponent2D::CaptureScene`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/USceneCaptureComponent2D/CaptureScene), and [UE 5.8 `FRHIGPUTextureReadback`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/RHI/FRHIGPUTextureReadback).

## Implemented fork path and next camera work

The smallest change was implemented on `Drone-Age/Cosys-AirSim:indra-ue5.8`, never on its upstream-synchronised `main`:

1. Produce camera frames at a fixed rate into a bounded latest-frame buffer.
2. Replace blocking `ReadSurfaceData` with UE asynchronous GPU readback (`FRHIGPUTextureReadback`).
3. Let RPC wait for the next completed frame and return its original simulation timestamp without initiating a render-thread readback.
4. Recreate readback staging after resolution/format changes and validate actual pixel content.
5. Keep compression and disk recording outside Unreal's synchronous capture request.

Next work is ROS 2/VINS transport, batched 200 Hz camera IMU, multiple image layers/cameras, and qualification under the final visual environment. Shared-memory/BGRA transport remains an optional optimization if RPC copying becomes the next bottleneck.
