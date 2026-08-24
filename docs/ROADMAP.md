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

- Build `/Sim2Rural/Maps/SIM2_Rural_WP` from the pinned Copernicus DEM and Sentinel-2 products at `50.31821195033009, 31.137054110768155, 104 m AMSL`.
- Use a deterministic 4 x 4 km World Partition/LWC collision core for qualification.
- Add georeferencing, landscape material, roads/land-use masks, performant grass, several tree variants, sunflower/corn field representation, HLOD and collision checks.
- Keep `qualification` offline and reproducible. Keep `visual` separately configurable.
- Attach `cesium-global` outside the local qualification polygon for effectively unbounded streamed WGS84/ECEF exploration. The local core remains authoritative for flight physics and test collision; Cesium is not treated as an infinite deterministic physics mesh.
- Pass the existing 15 m square in Blocks and SIM2 Rural with equivalent vehicle behaviour and at least 20 unique 640 x 480 camera frames/s.

Gate: `env doctor sim2-rural`, map-load test, origin/elevation measurement, seam/collision test and flight smoke all PASS before changing readiness to `ready`.

## M2 - sensor and ROS compatibility

- Implement the ROS 2 Jazzy topics, frames and simulation timestamps documented in `TEST_COMPATIBILITY.md`.
- In `Drone-Age/Cosys-AirSim:indra-ue5.8`, decouple camera production from synchronous RPC: fixed-rate RGB at 20 Hz, asynchronous GPU readback and bounded ring buffer.
- Provide 640 x 480 and 1280 x 720 performance evidence; 20 Hz is the required operating point, while measured maximum throughput is reported separately.
- Add timestamp-preserving batched 200 Hz camera IMU, body IMU, gimbal, VINS initializer, vision bridge and ArduPilot ExternalNav.
- Add wind set/get-applied command/ack and preserve separate MAVLink endpoints.

Gate: topic conformance, 20 Hz camera cadence, 190-210 Hz camera IMU, camera-nearest-IMU p95 <= 5 ms, VINS TRACKING and ExternalNav READY.

## M3 - existing climb test compatibility

- Extend `ENV_DEV_NEO_SIM_TEST_VINS_CLIMB` only with backend capability negotiation and backend configuration; preserve `run-test.cmd`, profiles, controller and verdict logic.
- Run the exact pinned commit first against SIM2, then against Cosys/Unreal.
- Qualify in order: stationary sensor test, arm/hover, 25 m climb smoke, then the full climb profile with 25 m steps up to 1000 m, staged wind, Source Set 2 primary and GNSS standby.
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
- Benchmark 640 x 480 and 1280 x 720 on the qualification workstation after every material/lighting change; protect the 20 Hz sensor requirement.

Gate: visual improvements do not regress flight, VINS, timing or reproducibility gates.

## Release sequence

- `v0.1.x`: Blocks flight baseline.
- `v0.2.x`: ready SIM2 Rural map and ROS/sensor compatibility.
- `v0.3.x`: climb and route parity plus environment-quality pass.
- `v1.0.0`: all required SIM2 qualification suites pass on pinned test commits with comparable immutable evidence.
