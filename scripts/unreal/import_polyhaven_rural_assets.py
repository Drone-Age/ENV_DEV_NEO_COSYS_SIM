import json
import os
import sys

import unreal


DEST_ROOT = "/IndraRuralAssets/Vegetation/PolyHaven"
NAME_MAP = {
    "grass_medium_01": "GrassMedium01",
    "grass_medium_02": "GrassMedium02",
    "shrub_03": "Shrub03",
    "shrub_04": "Shrub04",
}


def fail(message: str) -> None:
    unreal.log_error(f"INDRA_POLYHAVEN_IMPORT_FAIL {message}")
    raise RuntimeError(message)


def import_file(source_file: str, destination: str, options=None):
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", source_file)
    task.set_editor_property("destination_path", destination)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("replace_existing_settings", True)
    task.set_editor_property("save", False)
    if options is not None:
        task.set_editor_property("options", options)
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])
    imported = list(task.get_editor_property("imported_object_paths") or [])
    if not imported:
        fail(f"no_asset_imported source={source_file} destination={destination}")
    return imported


def create_material(asset_id: str, asset_dir: str, textures: dict):
    stable = NAME_MAP[asset_id]
    material_name = f"M_{stable}"
    material_path = f"{asset_dir}/{material_name}"
    if unreal.EditorAssetLibrary.does_asset_exist(material_path):
        unreal.EditorAssetLibrary.delete_asset(material_path)
    material = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        material_name, asset_dir, unreal.Material, unreal.MaterialFactoryNew()
    )
    if material is None:
        fail(f"cannot_create_material={material_path}")
    material.set_editor_property("blend_mode", unreal.BlendMode.BLEND_MASKED)
    material.set_editor_property("two_sided", True)
    material.set_editor_property("opacity_mask_clip_value", 0.34)

    diffuse = unreal.MaterialEditingLibrary.create_material_expression(
        material, unreal.MaterialExpressionTextureSample, -480, -120
    )
    diffuse.set_editor_property("texture", textures["diffuse"])
    unreal.MaterialEditingLibrary.connect_material_property(
        diffuse, "RGB", unreal.MaterialProperty.MP_BASE_COLOR
    )

    alpha = unreal.MaterialEditingLibrary.create_material_expression(
        material, unreal.MaterialExpressionTextureSample, -480, 80
    )
    alpha.set_editor_property("texture", textures["alpha"])
    unreal.MaterialEditingLibrary.connect_material_property(
        alpha, "R", unreal.MaterialProperty.MP_OPACITY_MASK
    )

    normal = unreal.MaterialEditingLibrary.create_material_expression(
        material, unreal.MaterialExpressionTextureSample, -480, 280
    )
    normal.set_editor_property("texture", textures["normal"])
    normal.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_NORMAL)
    unreal.MaterialEditingLibrary.connect_material_property(
        normal, "RGB", unreal.MaterialProperty.MP_NORMAL
    )

    roughness = unreal.MaterialEditingLibrary.create_material_expression(
        material, unreal.MaterialExpressionConstant, -240, 440
    )
    roughness.set_editor_property("r", 0.82)
    unreal.MaterialEditingLibrary.connect_material_property(
        roughness, "", unreal.MaterialProperty.MP_ROUGHNESS
    )
    unreal.MaterialEditingLibrary.recompile_material(material)
    unreal.EditorAssetLibrary.save_loaded_asset(material, only_if_is_dirty=False)
    return material


source_root = os.environ.get("INDRA_POLYHAVEN_SOURCE_ROOT", "")
lock_path = os.environ.get("INDRA_POLYHAVEN_LOCK", "")
report_path = os.environ.get("INDRA_ASSET_IMPORT_REPORT", "")
if not source_root or not lock_path or not report_path:
    fail("required environment variables are missing")

with open(lock_path, "r", encoding="utf-8-sig") as stream:
    lock = json.load(stream)

mesh_reports = []
expected_assets = []
for source_asset in lock["assets"]:
    asset_id = source_asset["id"]
    if asset_id not in NAME_MAP:
        fail(f"unrecognised_asset={asset_id}")
    stable = NAME_MAP[asset_id]
    asset_dir = f"{DEST_ROOT}/{stable}"
    source_dir = os.path.join(source_root, asset_id)
    textures = {}
    mesh_source = None
    for source_file in source_asset["files"]:
        path = os.path.join(source_dir, source_file["name"])
        if source_file["role"] == "mesh":
            mesh_source = path
            continue
        imported_paths = import_file(path, f"{asset_dir}/Textures")
        texture = unreal.EditorAssetLibrary.load_asset(imported_paths[0])
        if not isinstance(texture, unreal.Texture2D):
            fail(f"not_texture={imported_paths[0]}")
        role = source_file["role"]
        if role == "alpha":
            texture.set_editor_property("srgb", False)
            texture.set_editor_property(
                "compression_settings", unreal.TextureCompressionSettings.TC_MASKS
            )
        elif role == "normal":
            texture.set_editor_property("srgb", False)
            texture.set_editor_property(
                "compression_settings", unreal.TextureCompressionSettings.TC_NORMALMAP
            )
        unreal.EditorAssetLibrary.save_loaded_asset(texture, only_if_is_dirty=False)
        textures[role] = texture
        expected_assets.extend(path.split(".", 1)[0] for path in imported_paths)
    if mesh_source is None or set(textures) != {"diffuse", "alpha", "normal"}:
        fail(f"incomplete_source_set={asset_id}")

    options = unreal.FbxImportUI()
    options.set_editor_property("automated_import_should_detect_type", False)
    options.set_editor_property("import_as_skeletal", False)
    options.set_editor_property("import_mesh", True)
    options.set_editor_property("import_materials", False)
    options.set_editor_property("import_textures", False)
    options.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_STATIC_MESH)
    static_options = options.get_editor_property("static_mesh_import_data")
    static_options.set_editor_property("combine_meshes", True)
    static_options.set_editor_property("generate_lightmap_u_vs", False)
    static_options.set_editor_property("auto_generate_collision", False)
    static_options.set_editor_property("convert_scene", True)
    static_options.set_editor_property("convert_scene_unit", True)
    imported_meshes = import_file(mesh_source, asset_dir, options)
    mesh = unreal.EditorAssetLibrary.load_asset(imported_meshes[0])
    if not isinstance(mesh, unreal.StaticMesh):
        fail(f"not_static_mesh={imported_meshes[0]}")
    stable_mesh_path = f"{asset_dir}/SM_{stable}"
    current_mesh_path = mesh.get_path_name().split(".", 1)[0]
    if current_mesh_path != stable_mesh_path:
        if unreal.EditorAssetLibrary.does_asset_exist(stable_mesh_path):
            unreal.EditorAssetLibrary.delete_asset(stable_mesh_path)
        if not unreal.EditorAssetLibrary.rename_asset(current_mesh_path, stable_mesh_path):
            fail(f"cannot_rename_mesh={current_mesh_path}")
        mesh = unreal.EditorAssetLibrary.load_asset(stable_mesh_path)
    material = create_material(asset_id, asset_dir, textures)
    static_materials = list(mesh.get_editor_property("static_materials") or [])
    if not static_materials:
        fail(f"mesh_has_no_material_slots={stable_mesh_path}")
    for slot_index in range(len(static_materials)):
        mesh.set_material(slot_index, material)
    unreal.EditorAssetLibrary.save_loaded_asset(mesh, only_if_is_dirty=False)
    bounds = mesh.get_bounds()
    mesh_reports.append(
        {
            "id": asset_id,
            "object_path": f"{stable_mesh_path}.SM_{stable}",
            "lod_count": mesh.get_num_lods(),
            "material_slots": len(static_materials),
            "bounds_extent_cm": [
                bounds.box_extent.x,
                bounds.box_extent.y,
                bounds.box_extent.z,
            ],
            "bounds_radius_cm": bounds.sphere_radius,
        }
    )
    expected_assets.extend(
        [stable_mesh_path, f"{asset_dir}/M_{stable}"]
    )

if not unreal.EditorAssetLibrary.save_directory(
    DEST_ROOT, only_if_is_dirty=False, recursive=True
):
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
    "INDRA_POLYHAVEN_IMPORT_PASS "
    f"source_assets={len(lock['assets'])} packages={len(destination_assets)}"
)
sys.exit(0)
