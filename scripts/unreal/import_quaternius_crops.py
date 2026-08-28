import json
import os
import sys

import unreal


DEST_ROOT = "/IndraRuralAssets/Vegetation/QuaterniusCrops"
NAME_MAP = {
    "corn_mature": "CornMature",
    "wheat_mature": "WheatMature",
}


def fail(message: str) -> None:
    unreal.log_error(f"INDRA_QUATERNIUS_CROP_IMPORT_FAIL {message}")
    raise RuntimeError(message)


source_root = os.environ.get("INDRA_QUATERNIUS_SOURCE_ROOT", "")
lock_path = os.environ.get("INDRA_QUATERNIUS_LOCK", "")
report_path = os.environ.get("INDRA_ASSET_IMPORT_REPORT", "")
if not source_root or not lock_path or not report_path:
    fail("required environment variables are missing")

with open(lock_path, "r", encoding="utf-8-sig") as stream:
    lock = json.load(stream)

mesh_reports = []
for source_file in lock["files"]:
    asset_id = source_file["id"]
    if source_file["role"] != "mesh":
        continue
    if asset_id not in NAME_MAP:
        fail(f"unrecognised_asset={asset_id}")
    stable = NAME_MAP[asset_id]
    asset_dir = f"{DEST_ROOT}/{stable}"
    options = unreal.FbxImportUI()
    options.set_editor_property("automated_import_should_detect_type", False)
    options.set_editor_property("import_as_skeletal", False)
    options.set_editor_property("import_mesh", True)
    options.set_editor_property("import_materials", True)
    options.set_editor_property("import_textures", True)
    options.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_STATIC_MESH)
    static_options = options.get_editor_property("static_mesh_import_data")
    static_options.set_editor_property("combine_meshes", True)
    static_options.set_editor_property("generate_lightmap_u_vs", False)
    static_options.set_editor_property("auto_generate_collision", False)
    static_options.set_editor_property("convert_scene", True)
    static_options.set_editor_property("convert_scene_unit", True)

    task = unreal.AssetImportTask()
    task.set_editor_property("filename", os.path.join(source_root, source_file["name"]))
    task.set_editor_property("destination_path", asset_dir)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("replace_existing_settings", True)
    task.set_editor_property("save", False)
    task.set_editor_property("options", options)
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])
    imported = list(task.get_editor_property("imported_object_paths") or [])
    meshes = []
    for path in imported:
        asset = unreal.EditorAssetLibrary.load_asset(path)
        if isinstance(asset, unreal.StaticMesh):
            meshes.append(asset)
    if len(meshes) != 1:
        fail(f"expected_one_static_mesh={asset_id} imported={imported}")
    mesh = meshes[0]
    stable_mesh_path = f"{asset_dir}/SM_{stable}"
    current_mesh_path = mesh.get_path_name().split(".", 1)[0]
    if current_mesh_path != stable_mesh_path:
        if unreal.EditorAssetLibrary.does_asset_exist(stable_mesh_path):
            unreal.EditorAssetLibrary.delete_asset(stable_mesh_path)
        if not unreal.EditorAssetLibrary.rename_asset(current_mesh_path, stable_mesh_path):
            fail(f"cannot_rename_mesh={current_mesh_path}")
        mesh = unreal.EditorAssetLibrary.load_asset(stable_mesh_path)
    unreal.EditorAssetLibrary.save_loaded_asset(mesh, only_if_is_dirty=False)
    bounds = mesh.get_bounds()
    mesh_reports.append(
        {
            "id": asset_id,
            "object_path": f"{stable_mesh_path}.SM_{stable}",
            "lod_count": mesh.get_num_lods(),
            "material_slots": len(list(mesh.get_editor_property("static_materials") or [])),
            "bounds_extent_cm": [
                bounds.box_extent.x,
                bounds.box_extent.y,
                bounds.box_extent.z,
            ],
            "bounds_radius_cm": bounds.sphere_radius,
        }
    )

if len(mesh_reports) != 2:
    fail(f"expected_two_crop_meshes={len(mesh_reports)}")
if not unreal.EditorAssetLibrary.save_directory(DEST_ROOT, only_if_is_dirty=False, recursive=True):
    fail("destination save failed")

destination_assets = sorted(
    unreal.EditorAssetLibrary.list_assets(DEST_ROOT, recursive=True, include_folder=False)
)
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
    for dependency in registry.get_dependencies(package_name, dependency_options) or []:
        value = str(dependency)
        if not (value.startswith("/IndraRuralAssets/") or value.startswith("/Engine/")):
            external_dependencies.append({"asset": package_name, "dependency": value})
if external_dependencies:
    fail(f"external_dependencies={json.dumps(external_dependencies, sort_keys=True)}")

report = {
    "schema": 1,
    "status": "PASS",
    "source_lock": lock_path,
    "destination_root": DEST_ROOT,
    "asset_count": len(destination_assets),
    "assets": [path.split(".", 1)[0] for path in destination_assets],
    "meshes": mesh_reports,
    "external_dependencies": external_dependencies,
}
with open(report_path, "w", encoding="utf-8", newline="\n") as stream:
    json.dump(report, stream, indent=2, sort_keys=True)
    stream.write("\n")
unreal.log(
    "INDRA_QUATERNIUS_CROP_IMPORT_PASS "
    f"source_meshes={len(mesh_reports)} packages={len(destination_assets)}"
)
sys.exit(0)
