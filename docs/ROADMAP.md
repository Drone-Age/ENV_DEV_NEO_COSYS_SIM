# Roadmap: from Blocks demo to SIM2 qualification parity

## Definition of done

The new simulator is a replacement candidate for `ENV_DEV_NEO_SIM2` only when the same pinned qualification-test commits can run against both backends and produce comparable evidence and PASS verdicts. A visually attractive Unreal map alone is not parity. Mission Planner is optional for a human-observed run and is disabled in all automated gates.

Each phase is entered only after the preceding phase passes. Failed gates remain visible in the evidence bundle; they are not waived by later work.

## M0 - stable small demo (complete baseline)

- UE 5.8.1, Cosys-AirSim and ArduCopter SITL launch through `dev.ps1`.
- Blocks executes `TAKEOFF -> 15 m square -> LAND -> DISARM` without Mission Planner.
- Logs and `summary.json` are collected per run.
- Environment and test packages have a submodule/lock contract.

Gate: repeat the Blocks smoke after every launcher, Cosys or sensor-path change.

## M1 - real SIM2-location environment

- [done] Build `/Sim2Rural/Maps/SIM2_Rural_WP` from the pinned Copernicus DEM and Sentinel-2 products at `50.31821195033009, 31.137054110768155, 104 m AMSL`.
- [done] Create a deterministic 4 x 4 km World Partition/LWC visual core with 1024 verified render and serialized heightfield-collision components.
- [done] Pass the 15 m square flight in the real map (`2026-08-24_204647_test_6c00d140`): heartbeat, sensor exchange, healthy EKF, ARM, all waypoints, LAND and DISARM; maximum altitude 5.71 m.
- [done] Sustain 640 x 480 raw RGB at 20.74 unique FPS with zero duplicate timestamps (`2026-08-24_205010_camera-sim2-rural-640x480_42cfbbd9`).
- [done] Repartition the generated Landscape into 256 runtime streaming proxies, verify 1024 collision components, remove the temporary pad, hit DEM collision at 150 m and 500 m, and pass the complete square flight directly on the DEM (`2026-08-24_214945_test_50550629`).
- [pass, optimize] 1280 x 720 raw RGB reaches 15.33 unique FPS in rural and passes its 10 FPS minimum. The asynchronous producer in M2 remains required to pursue stable 20 Hz and tighter jitter; 640 x 480 remains qualified at >=20 FPS.
- Add georeferencing, landscape material, roads/land-use masks, performant grass, several tree variants, sunflower/corn field representation, HLOD and collision checks.
- Keep `qualification` offline and reproducible. Keep `visual` separately configurable.
- Attach `cesium-global` outside the local qualification polygon for effectively unbounded streamed WGS84/ECEF exploration. The local core remains authoritative for flight physics and test collision; Cesium is not treated as an infinite deterministic physics mesh.
- Pass the existing 15 m square in Blocks and SIM2 Rural with equivalent vehicle behaviour and at least 20 unique 640 x 480 camera frames/s.

Structural subgate: `env build-map sim2-rural` now regenerates and reload-verifies the map, exact georeference, Sentinel-2 material, 256 World Partition Landscape proxies and 1024 collision components. Origin-area runtime traces and pad-free flight pass. Remaining runtime gate: `env doctor sim2-rural`, full-extent physics line traces/landing probes, origin/elevation measurement, seam probes, vegetation checks, flight smoke and both camera acceptance tests must all PASS before changing readiness from `preview` to `ready`.

## M2 - sensor and ROS compatibility

- Implement the ROS 2 Jazzy topics, frames and simulation timestamps documented in `TEST_COMPATIBILITY.md`.
- In `Drone-Age/Cosys-AirSim:indra-ue5.8`, decouple camera production from synchronous RPC: fixed-rate RGB at 20 Hz, asynchronous GPU readback and bounded ring buffer.
- Provide 640 x 480 and 1280 x 720 performance evidence. Acceptance is >=20 FPS and >=10 FPS respectively; stable 20 Hz at 1280 x 720 is an explicit optimization target, while measured maximum throughput and jitter are reported separately.
- Add timestamp-preserving batched 200 Hz camera IMU, body IMU, gimbal, VINS initializer, vision bridge and ArduPilot ExternalNav.
- Add wind set/get-applied command/ack and preserve separate MAVLink endpoints.

Gate: topic conformance, 20 Hz camera cadence, 190-210 Hz camera IMU, camera-nearest-IMU p95 <= 5 ms, VINS TRACKING and ExternalNav READY.

## M3 - existing climb test compatibility

- Pin `ENV_DEV_NEO_SIM_TEST_VINS_CLIMB` v2.0.0 commit `10b3f4717ee599b99a4bfdba4fca29869661ca37` as `tests/vins_climb_unit`; preserve `run-test.cmd`, schema-2 profiles, controller and verdict logic. Extend it only with backend capability negotiation and backend configuration.
- Run the exact pinned commit first against SIM2, then against Cosys/Unreal.
- Qualify in order: `-PrintOnly` contract validation, stationary topic/timestamp test, ground admission, arm/hover, `profile-smoke.json` 25 m climb, then `profile.json` with 25 m steps up to 1000 m.
- Preserve its admission rules: finite VINS odometry >=4 Hz, >=15 features, bridge and `/mavros/odometry/out` READY for 2 s, Source Set 2 confirmed and settled for 10 s before ARM, Source Set 1/GNSS standby fallback, LOITER throughout normal qualification.
- Preserve wind semantics exactly: command IDs and applied acknowledgements within 5 s; 5->10 m/s smoke at 25 m; from 100 m four 18 m/s N/S/N/S gusts; additional tiered gusts through 1000 m. LAND and DISARM must occur on Source Set 2 for PASS.
- Record MCAP, DataFlash, parameters, routes, timestamps and immutable JSON/PDF verdicts.

Gate: both backends PASS the same climb-test commit and differences fall within explicitly versioned tolerances. A Cosys-only fork of the test is not accepted.

## M4 - route and remaining SIM2 suites

- Run the pinned `ENV_DEV_NEO_SIM_TEST_VINS_10KM` Gerono qualification through the same adapter.
- Register and pin the remaining SIM2 suites (500 m, Source Set 2/LOITER, altitude ladder, wind command/ack and fault/recovery cases) one repository at a time in `tests/test-registry.json`.
- Every suite declares capabilities and fails early if its backend cannot supply them.
- Compare timing, trajectory, VINS state transitions, ExternalNav health and evidence schemas between SIM2 and Cosys.

Gate: the complete required registry passes without changing backend-neutral mission or acceptance logic.

## M5 - environment portfolio and quality

- Add new environments only as separate `Drone-Age/ENV_DEV_NEO_COSYS_ENV_<NAME>` repositories, pinned as parent submodules.
- Keep reusable asset libraries in separate `..._ASSETS_<NAME>` repositories and document source/licence/redistribution for every asset.
- Provide `qualification` and `visual` profiles. Improve Nanite/PBR materials, foliage, atmosphere, weather and camera optics only after deterministic functional gates remain green.
- Benchmark 640 x 480 and 1280 x 720 on the qualification workstation after every material/lighting change; protect the 20 FPS and 10 FPS acceptance gates respectively, and track stable 20 Hz at 1280 x 720 as an optimization target.

Gate: visual improvements do not regress flight, VINS, timing or reproducibility gates.

The first full environment is a composition, not one unbounded monolithic map: `sim2-rural` is the offline authoritative 4 x 4 km test/physics core at the SIM2 coordinates, while the separately versioned `cesium-global` package supplies streamed real-world space outside it. Unreal/LWC removes ordinary world-coordinate limits, but network-streamed Cesium terrain is visual/non-deterministic and cannot replace the local qualification collision mesh.

## Release sequence

- `v0.1.x`: Blocks flight baseline.
- `v0.2.x`: ready SIM2 Rural map and ROS/sensor compatibility.
- `v0.3.x`: climb and route parity plus environment-quality pass.
- `v1.0.0`: all required SIM2 qualification suites pass on pinned test commits with comparable immutable evidence.
