import json
import os
import sys

import unreal


SOURCE_ROOT = "/Game/ArchVis/SampleScene/Tree"
DEST_ROOT = "/IndraRuralAssets/Vegetation/UEExamples/HillTree"
DEST_MESH = f"{DEST_ROOT}/HillTree_02.HillTree_02"


def fail(message: str) -> None:
    unreal.log_error(f"INDRA_EPIC_TREE_IMPORT_FAIL {message}")
    raise RuntimeError(message)


source_assets = sorted(
    unreal.EditorAssetLibrary.list_assets(SOURCE_ROOT, recursive=True, include_folder=False)
)
if len(source_assets) != 12:
    fail(f"expected=12 source_assets={len(source_assets)}")

rename_data = []
for source_path in source_assets:
    asset = unreal.EditorAssetLibrary.load_asset(source_path)
    if asset is None:
        fail(f"cannot_load={source_path}")
    package_name = asset.get_path_name().split(".", 1)[0]
    package_path, _ = package_name.rsplit("/", 1)
    asset_name = asset.get_name()
    relative_folder = package_path[len(SOURCE_ROOT):].strip("/")
    destination_folder = DEST_ROOT
    if relative_folder:
        destination_folder = f"{DEST_ROOT}/{relative_folder}"
    rename_data.append(unreal.AssetRenameData(asset, destination_folder, asset_name))

if not unreal.AssetToolsHelpers.get_asset_tools().rename_assets(rename_data):
    fail("AssetTools rename failed")

if not unreal.EditorAssetLibrary.save_directory(DEST_ROOT, only_if_is_dirty=False, recursive=True):
    fail("destination save failed")

destination_assets = sorted(
    unreal.EditorAssetLibrary.list_assets(DEST_ROOT, recursive=True, include_folder=False)
)
if len(destination_assets) != 12:
    fail(f"expected=12 destination_assets={len(destination_assets)}")

mesh = unreal.EditorAssetLibrary.load_asset(DEST_MESH)
if not isinstance(mesh, unreal.StaticMesh):
    fail(f"missing_static_mesh={DEST_MESH}")

registry = unreal.AssetRegistryHelpers.get_asset_registry()
dependency_options = unreal.AssetRegistryDependencyOptions(
    include_soft_package_references=True,
    include_hard_package_references=True,
    include_searchable_names=False,
    include_soft_management_references=False,
    include_hard_management_references=False,
)
external_dependencies = []
for asset_path in destination_assets:
    package_name = asset_path.split(".", 1)[0]
    for dependency in (registry.get_dependencies(package_name, dependency_options) or []):
        value = str(dependency)
        if not (value.startswith("/IndraRuralAssets/") or value.startswith("/Engine/")):
            external_dependencies.append({"asset": package_name, "dependency": value})
if external_dependencies:
    fail(f"external_dependencies={json.dumps(external_dependencies, sort_keys=True)}")

bounds = mesh.get_bounds()
report = {
    "schema": 1,
    "status": "PASS",
    "source_root": SOURCE_ROOT,
    "destination_root": DEST_ROOT,
    "assets": [path.split(".", 1)[0] for path in destination_assets],
    "asset_count": len(destination_assets),
    "mesh": {
        "object_path": DEST_MESH,
        "lod_count": mesh.get_num_lods(),
        "bounds_extent_cm": [bounds.box_extent.x, bounds.box_extent.y, bounds.box_extent.z],
        "bounds_radius_cm": bounds.sphere_radius,
    },
    "external_dependencies": external_dependencies,
}

output_path = os.environ.get("INDRA_ASSET_IMPORT_REPORT", "")
if not output_path:
    fail("INDRA_ASSET_IMPORT_REPORT is not set")
with open(output_path, "w", encoding="utf-8", newline="\n") as stream:
    json.dump(report, stream, indent=2, sort_keys=True)
    stream.write("\n")

unreal.log(
    "INDRA_EPIC_TREE_IMPORT_PASS "
    f"assets={len(destination_assets)} lods={report['mesh']['lod_count']} "
    f"radius_cm={report['mesh']['bounds_radius_cm']:.2f}"
)
sys.exit(0)
