# Cosys camera throughput on UE 5.8.1

## Qualified target

INDRA currently requires 20 FPS rather than 30 FPS. The live sensor path therefore uses:

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

The repeated raw 1280x720 result straddles the 20 FPS threshold: 19.10 FPS failed with a 1280x720 operator viewport, while 20.25 FPS passed after reducing only that viewport to 640x360. Observed p95 request latency is about 59-68 ms. The mode is adequate when a measured average of 20 FPS is sufficient, but it is not a hard real-time 20 Hz guarantee. Re-run qualification after scene, lighting, driver, camera count or capture-layer changes.

Evidence bundles from this measurement remain local under `logs/` and are intentionally not committed.

## Root cause

This is not primarily a WSL networking problem. A Windows-native client measured 22.51 FPS at 640x480 versus 23.64 FPS from WSL.

The current Cosys/AirSim request path is synchronous. `RenderRequest.cpp` schedules capture on Unreal's game thread, waits for the render command, calls `ReadSurfaceData` to copy the GPU render target into CPU memory, repacks pixels into an RGB vector and optionally compresses PNG on the CPU. `UnrealImageCapture.cpp` waits for that operation before returning the RPC response. With only one request in flight, frame rate is consequently bounded by end-to-end request latency.

`ForceUpdate=true` is not a fix. In `PIPCamera.cpp` it enables `bCaptureEveryFrame` and `bCaptureOnMovement`; the benchmark shows that this competes with explicit image requests and reduces throughput. Render-offscreen also reduced throughput on this UE 5.8.1 build and is not part of the qualified profile.

## Upgrade path if a stable margin above 20 FPS is required

Implement the smallest change on `Drone-Age/Cosys-AirSim:indra-ue5.8`, never on its upstream-synchronised `main`:

1. Produce camera frames at a fixed simulation rate into a bounded ring buffer.
2. Replace blocking `ReadSurfaceData` with UE asynchronous GPU readback (`FRHIGPUTextureReadback`).
3. Let RPC return the newest completed frame and its original simulation timestamp without waiting on the render thread.
4. Avoid the per-pixel `FColor` to RGB repack, or expose a tightly packed BGRA buffer/shared-memory transport.
5. Keep compression and disk recording outside Unreal's synchronous capture request.

This fork change is not required for the v0.1 flight demo. It becomes required if 1280x720 must hold 20 Hz with deterministic jitter bounds, if multiple image layers/cameras are enabled, or if the scene upgrade pushes average throughput below the gate.
