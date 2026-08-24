# Modular Unreal environments

## Outcome and repository topology

`IndraCosysDemo` is the stable UE 5.8.1 host. An environment is a versioned package with `environment.json` and, normally, one content-only Unreal plugin. The parent pins packages as Git submodules and stages their plugins into an ignored generated directory before build/run.

| Environment | Repository | Purpose | Current gate |
|---|---|---|---|
| `blocks` | parent-owned | Small offline flight/camera regression | ready |
| `sim2-rural` | `Drone-Age/ENV_DEV_NEO_COSYS_ENV_SIM2_RURAL` (private/LFS) | 4 x 4 km real local qualification core at the SIM2 origin, optional Cesium exterior | scaffold |
| `cesium-global` | `Drone-Age/ENV_DEV_NEO_COSYS_ENV_CESIUM_GLOBAL` (private/LFS) | Global streamed visual exploration | scaffold |
| rural assets | `Drone-Age/ENV_DEV_NEO_COSYS_ASSETS_RURAL` (private/LFS) | Reusable trees, grass, sunflower and corn content plugin | scaffold/empty |

The rural environment includes the asset repository as a nested submodule. It does not duplicate those assets. Each future map follows the same model: separate private repository, LFS patterns, immutable manifest and a pinned parent gitlink.

## Commands and lifecycle

```powershell
.\dev.ps1 env list
.\dev.ps1 setup -Environment sim2-rural
.\dev.ps1 env doctor sim2-rural
.\dev.ps1 build -Environment sim2-rural
.\dev.ps1 run -Environment sim2-rural -RenderProfile qualification
```

Lifecycle is `scaffold -> preview -> ready`. `build`, `run` and `test` accept only `ready`. `env list` can display every installed state, and `env doctor` is the authoritative readiness check. The manifest schema lives at `contracts/environment.schema.json`.

## SIM2 rural implementation

The exact WGS84 origin is `50.31821195033009, 31.137054110768155, 104 m AMSL`. Build a deterministic local 4 x 4 km collision surface with World Partition, Large World Coordinates, HLOD and Data Layers. The current climb and 10 km Gerono route fit within this core; the latter is accumulated path length, not a 10 km-wide map.

Use a scripted GIS pipeline derived from the read-only SIM2 datum workflow. Candidate input classes are DEM, ortho/satellite imagery, OSM roads/buildings/water/land use and land-cover masks. Acquisition code must check current provider terms. Every dataset record includes source URL/product, provider, licence, timestamp, bounds, CRS, native resolution and SHA-256 of source and derived outputs.

`qualification` must work fully offline with fixed seed, season, sun, exposure, weather, crop assignment and camera settings. `visual` may use Cesium, Lumen, atmosphere, wind and variation. Inside the local 4 x 4 km polygon, hide the Cesium surface so it cannot overlap the collision terrain. Global visual reach is streaming; it is not an infinite local physics mesh. Keep vehicle physics in a local rebased bubble while WGS84/ECEF remains continuous.

Vegetation uses only free, provenance-recorded inputs. Prefer several optimized deciduous tree variants and performant grass. If no redistribution-compatible corn pack exists, author simple LOD/Nanite-aware crop meshes/materials from documented free PBR sources. Sunflower and corn placement follows real crop tags where available; otherwise the deterministic qualification seed assigns explicitly labelled synthetic crop types.

## Legacy references

The old projects under `D:\FILES\Kkovalenko\OneDrive\UnrealEngine\AirSim\Environments` are references, not build inputs. Do not convert them in place, copy old Microsoft AirSim plugins/binaries, or run migration from an online-only placeholder. Audit provenance first, then migrate a selected UE asset from a locally available copy using `Asset Actions -> Migrate` into the destination content plugin. Fix redirectors and validate the migrated package in UE 5.8.1 before committing it through LFS.

## Rural acceptance gate

The rural manifest may become `ready` only when:

1. `/Sim2Rural/Maps/SIM2_Rural_WP` exists and loads with no missing dependency or redirector.
2. The measured origin and elevation are documented; collision covers the full 4 x 4 km core.
3. The v0.1 15 m flight passes in Blocks and rural with equivalent vehicle behaviour.
4. Qualification starts offline and is reproducible; visual mode gracefully reports missing Cesium credentials/network.
5. 640 x 480 camera output sustains at least 20 unique simulation frames/s on the qualification workstation.
6. Dataset and asset provenance is complete and no credentials, absolute workstation paths or unverified OneDrive assets are tracked.
7. After ROS/VINS integration, the climb smoke (25 m) passes before the full 1000 m climb and 10 km route are attempted.

UE references: [Large World Coordinates](https://dev.epicgames.com/documentation/unreal-engine/large-world-coordinates-in-unreal-engine-5), [World Partition](https://dev.epicgames.com/documentation/unreal-engine/world-partition-in-unreal-engine), [Georeferencing a Level](https://dev.epicgames.com/documentation/unreal-engine/georeferencing-a-level-in-unreal-engine). Cesium plugin releases are tracked at [Cesium for Unreal](https://github.com/CesiumGS/cesium-unreal/releases).
