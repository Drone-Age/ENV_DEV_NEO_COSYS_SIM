# Cosys camera throughput on UE 5.8.1

## Qualified target

INDRA acceptance requires at least 20 FPS at 640x480 and at least 10 FPS at 1280x720. Stable 20 Hz at 1280x720 remains a performance target rather than a release blocker. The live sensor path therefore uses:

- one Scene camera;
- 640x480 or 1280x720;
- uncompressed RGB returned by `simGetImages`;
- `ForceUpdate=false` (on-demand capture);
- Lumen GI and Lumen reflections disabled for the sensor capture;
- PNG/JPEG encoding, display and recording performed asynchronously downstream.
- a 640x360 operator/diagnostic viewport during qualification (sensor resolution is unchanged).

Run `./dev.ps1 camera-test` to create fresh evidence bundles. Mission Planner is never launched by this test. Count unique `time_stamp` values; repeated RPC responses must not be counted as new frames.

## Measurements on the reference workstation

The reference machine is Ryzen 5 8400F, RTX 5060 Ti 16 GB, UE 5.8.1 and Cosys Blocks. Each case used one sequential RPC request at a time with a live ArduCopter SITL peer.

| Mode | Resolution | Format | Unique FPS | Mean latency |
|---|---:|---:|---:|---:|
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

The repeated raw 1280x720 result straddles the 20 Hz optimization target: 19.10 FPS used a 1280x720 operator viewport, while 20.25 FPS followed after reducing only that viewport to 640x360. Rural is heavier and measured 15.33 FPS, but still passes the explicit 10 FPS acceptance gate. Observed p95 request latency in Blocks is about 59-68 ms. None of these synchronous measurements is a hard real-time cadence guarantee. Re-run qualification after scene, lighting, driver, camera count or capture-layer changes.

The instrumented rural repeat reached 17.65 unique FPS with zero duplicate timestamps. RTX 5060 Ti utilization averaged 39.46%, reached 46% maximum, and averaged 48.84 W against a 180 W board limit. Reducing the operator viewport again from 640x360 to 320x240 slightly reduced throughput to 17.28 FPS, so 640x360 remains the qualified viewport. These measurements rule out GPU saturation and operator viewport fill rate as the primary bottleneck on the reference workstation.

A subsequent strict 640x480 repeat produced 18.62 unique FPS with zero duplicate timestamps. Earlier rural runs produced 20.74 and 23.75 FPS, but one of them contained a duplicate timestamp. Therefore 640x480 has demonstrated sufficient peak throughput but not repeatable 20 FPS acceptance. The gate remains failed until a clean run passes and repeatability is established; the test threshold is not weakened.

Evidence bundles from this measurement remain local under `logs/` and are intentionally not committed.

## Root cause

This is not primarily a WSL networking problem. A Windows-native client measured 22.51 FPS at 640x480 versus 23.64 FPS from WSL.

The current Cosys/AirSim request path is synchronous. `RenderRequest.cpp` schedules capture on Unreal's game thread, waits for the render command, calls `ReadSurfaceData` to copy the GPU render target into CPU memory, repacks pixels into an RGB vector and optionally compresses PNG on the CPU. `UnrealImageCapture.cpp` waits for that operation before returning the RPC response. With only one request in flight, frame rate is consequently bounded by end-to-end request latency.

`ForceUpdate=true` is not a fix. In `PIPCamera.cpp` it enables `bCaptureEveryFrame` and `bCaptureOnMovement`; the benchmark shows that this competes with explicit image requests and reduces throughput. Render-offscreen also reduced throughput on this UE 5.8.1 build and is not part of the qualified profile.

The project already sets `bThrottleCPUWhenNotForeground=False` in `DefaultEditorPerProjectUserSettings.ini`, matching the Cosys custom-environment guidance. The Windows host also uses the High performance power plan. Do not treat either setting as a hypothetical fix: keep them enabled, then use `gpu-metrics.csv` from each benchmark bundle to determine whether the run is GPU-saturated. Low or intermittent GPU utilization together with high RPC latency points to the synchronous render/readback pipeline, not insufficient shader throughput.

## Options evaluated

1. **Keep the current raw RPC path for v0.1.** It passes 1280x720 at the required 10 FPS and is the lowest-risk option for the flight demo.
2. **Reduce only the operator viewport.** A 640x360 viewport improved Blocks while preserving sensor resolution. Test 320x240 as an additional reversible profile; retain it only if evidence shows a repeatable gain and operator usability remains acceptable.
3. **Reduce sensor render cost without changing geometry.** Keep Lumen GI/reflections, motion blur, depth of field and expensive post effects disabled on the qualification camera. Any scalability or show-flag change must be checked for VINS feature count and photometric consistency before adoption.
4. **Avoid duplicate rendering modes.** Keep `ForceUpdate=false`; Unreal documents that manual capture must not be combined with `bCaptureEveryFrame`. `-RenderOffscreen` and PNG already measured worse here and are rejected for the real-time path.
5. **Decouple capture from RPC.** This is the durable solution: fixed-rate capture, asynchronous `FRHIGPUTextureReadback`, a bounded latest-frame buffer, and compression/recording downstream. It removes the RPC caller from the game/render-thread critical path and provides stable timestamps for ROS/VINS.

The repository currently resides on the `F:` SATA HDD. Put Unreal Derived Data Cache and disposable `Intermediate` data on an SSD on machines where this is available; this materially improves builds, shader preparation and texture-streaming stutter. It is not expected to remove the steady synchronous RPC/readback ceiling, so measure it separately from sensor throughput and keep all source/submodule paths unchanged.

Primary references: [Cosys custom environment guidance](https://github.com/Cosys-Lab/Cosys-AirSim/blob/main/docs/unreal_custenv.md), [Cosys issue #82](https://github.com/Cosys-Lab/Cosys-AirSim/issues/82), [AirSim issue #1766](https://github.com/microsoft/AirSim/issues/1766), [AirSim issue #796](https://github.com/microsoft/AirSim/issues/796), [UE 5.8 `USceneCaptureComponent2D::CaptureScene`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/USceneCaptureComponent2D/CaptureScene), and [UE 5.8 `FRHIGPUTextureReadback`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/RHI/FRHIGPUTextureReadback).

## Upgrade path toward stable 20 Hz at 1280x720

Implement the smallest change on `Drone-Age/Cosys-AirSim:indra-ue5.8`, never on its upstream-synchronised `main`:

1. Produce camera frames at a fixed simulation rate into a bounded ring buffer.
2. Replace blocking `ReadSurfaceData` with UE asynchronous GPU readback (`FRHIGPUTextureReadback`).
3. Let RPC return the newest completed frame and its original simulation timestamp without waiting on the render thread.
4. Avoid the per-pixel `FColor` to RGB repack, or expose a tightly packed BGRA buffer/shared-memory transport.
5. Keep compression and disk recording outside Unreal's synchronous capture request.

This fork change is not required for the v0.1 flight demo or the 10 FPS 1280x720 acceptance gate. It is required to target deterministic 20 Hz, multiple image layers/cameras, or enough headroom for more expensive scenes.
