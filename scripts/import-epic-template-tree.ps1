[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ue = Get-UeRoot
if (-not $ue) { throw 'UE 5.8.1 was not found. Run .\dev.ps1 doctor.' }
$editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
$sourceRelative = 'Templates\TemplateResources\Standard\ArchVis\Content\SampleScene\Tree'
$sourceRoot = Join-Path $ue $sourceRelative
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "The UE ArchVis Example tree is missing: $sourceRelative. Repair the UE 5.8.1 installation."
}

$expected = [ordered]@{
    'HillTree_02.uasset' = 'cacda293bb6be786e4192292e98a8548603442db0102aff0a7d0da75e8f63838'
    'Materials\M_HillTree_01_Branches_2.uasset' = 'c674efa99ee5cd5687cb69a4e28960cdde659aa567c310ea998c3209d3653683'
    'Materials\M_HillTree_01_Branches.uasset' = '7945b9fbe1693eca5b20310723f3079fd4240ad2be842c070cbf7b665f75f602'
    'Materials\M_HillTree_01_Fronds.uasset' = '8c0b02f85690d47926197febc18a59b80f8b43c2d520759cf5c82da7d97b56eb'
    'Materials\M_HillTree_01_Leaves.uasset' = '99491c75b3210ca431dbde94ce6e3f4732d1eae818164f79589c03b554a0e640'
    'Textures\T_Craghead_Oak_LimbTile_02_D.uasset' = '498d83ea0a10ce8696da250f6ab988d5d9d65fa55c410a9375d5e60fcf631417'
    'Textures\T_Craghead_Oak_LimbTile_02_N.uasset' = '8d07d247bfb04d2944ce0d49d2b3208f857002f07f80d98cdeff12e1cda66a7e'
    'Textures\T_Craghead_Oak_Tile_01_D.uasset' = '7941abc2475a646943d3204d644cb500e250c99d78ed656006057d45f5e376ab'
    'Textures\T_Craghead_Oak_Tile_01_N.uasset' = '5f96b50fcfe0c52a568c7b7dce9bbbf842558a863a72b033b617b1b9ab43c718'
    'Textures\T_HillTree_01_Atlas_N.uasset' = 'b1e5e825363d24958f349d202881659b09d0ae9e6098f7664f1972b43c828f3d'
    'Textures\T_HillTree_01_Atlas_S.uasset' = 'eb2d53b1be664b7c5ad19e66f5efbdf646d6232072035816de7ec0c7036cb5b1'
    'Textures\T_HillTree_01_Atlas.uasset' = '1bfc60171084909e3babd04f43a4ccfb2a206b0a9a3e94902efa6421b1699a07'
}

foreach ($entry in $expected.GetEnumerator()) {
    $source = Join-Path $sourceRoot $entry.Key
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Pinned UE Example asset is missing: $($entry.Key)" }
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Pinned UE Example asset changed: $($entry.Key); expected $($entry.Value), found $actual" }
}
Write-Pass 'UE Example source' '12 pinned ArchVis tree packages, SHA-256 verified'

$runtimeBase = [IO.Path]::GetFullPath($script:RuntimeRoot)
$runtimePrefix = $runtimeBase.TrimEnd('\') + '\'
$importStagingRoot = [IO.Path]::GetFullPath((Join-Path $runtimeBase 'epic-template-tree-import'))
if (-not $importStagingRoot.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $importStagingRoot) -ne 'epic-template-tree-import') {
    throw "Unsafe import staging path: $importStagingRoot"
}
if (Test-Path -LiteralPath $importStagingRoot) { Remove-Item -LiteralPath $importStagingRoot -Recurse -Force }
$contentRoot = Join-Path $importStagingRoot 'Content\ArchVis\SampleScene\Tree'
$tempPluginRoot = Join-Path $importStagingRoot 'Plugins\IndraRuralAssets'
New-Item -ItemType Directory -Force -Path $contentRoot, $tempPluginRoot | Out-Null

& robocopy.exe $sourceRoot $contentRoot /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "UE Example staging failed with robocopy code $LASTEXITCODE." }
$assetRepo = [IO.Path]::GetFullPath((Join-Path $script:EnvironmentsRoot 'sim2-rural\Plugins\IndraRuralAssets'))
$descriptorSource = Join-Path $assetRepo 'Plugins\IndraRuralAssets\IndraRuralAssets.uplugin'
Copy-Item -LiteralPath $descriptorSource -Destination (Join-Path $tempPluginRoot 'IndraRuralAssets.uplugin')

$projectPath = Join-Path $importStagingRoot 'IndraAssetImport.uproject'
$project = [ordered]@{
    FileVersion = 3
    EngineAssociation = '5.8'
    Category = 'INDRA'
    Description = 'Disposable project for deterministic migration of UE Examples.'
    Plugins = @(
        [ordered]@{ Name = 'PythonScriptPlugin'; Enabled = $true },
        [ordered]@{ Name = 'EditorScriptingUtilities'; Enabled = $true },
        [ordered]@{ Name = 'IndraRuralAssets'; Enabled = $true }
    )
}
$project | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $projectPath -Encoding utf8

$reportPath = Join-Path $importStagingRoot 'import-report.json'
$logPath = Join-Path $script:RuntimeRoot 'epic-template-tree-import.log'
$pythonScript = Join-Path $PSScriptRoot 'unreal\import_epic_template_tree.py'
$env:INDRA_ASSET_IMPORT_REPORT = $reportPath
try {
    & $editor $projectPath "-ExecutePythonScript=$pythonScript" -unattended -nop4 -nosplash -NoSound -NullRHI "-abslog=$logPath"
    if ($LASTEXITCODE -ne 0) { throw "UE Example asset migration failed; see $logPath" }
} finally {
    Remove-Item Env:INDRA_ASSET_IMPORT_REPORT -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "UE did not create its import report; see $logPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.status -ne 'PASS' -or [int]$report.asset_count -ne 12 -or @($report.external_dependencies).Count -ne 0) {
    throw "UE Example import report is not a closed PASS; see $reportPath"
}

$generatedRoot = Join-Path $tempPluginRoot 'Content\Vegetation\UEExamples\HillTree'
$destinationRoot = [IO.Path]::GetFullPath((Join-Path $assetRepo 'Plugins\IndraRuralAssets\Content\Vegetation\UEExamples\HillTree'))
$assetContentRoot = [IO.Path]::GetFullPath((Join-Path $assetRepo 'Plugins\IndraRuralAssets\Content'))
if (-not $destinationRoot.StartsWith($assetContentRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $destinationRoot) -ne 'HillTree') {
    throw "Unsafe rural asset destination: $destinationRoot"
}
New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
& robocopy.exe $generatedRoot $destinationRoot /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Migrated rural asset sync failed with robocopy code $LASTEXITCODE." }

$derived = @(Get-ChildItem -LiteralPath $destinationRoot -Recurse -File -Filter '*.uasset' | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($destinationRoot.Length + 1).Replace('\', '/')
    [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = $_.Length }
})
if ($derived.Count -ne 12) { throw "Expected 12 migrated assets, found $($derived.Count)." }
$bundleText = ($derived | ForEach-Object { "$($_.path)|$($_.sha256)|$($_.bytes)" }) -join "`n"
$bundleBytes = [Text.Encoding]::UTF8.GetBytes($bundleText)
$bundleHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bundleBytes)).ToLowerInvariant()
$receipt = [ordered]@{
    schema = 1
    id = 'epic-ue58-archvis-hilltree-02'
    status = 'accepted'
    source_kind = 'unreal-engine-example'
    engine = '5.8.1'
    source_relative_path = $sourceRelative.Replace('\', '/')
    source_assets = @($expected.GetEnumerator() | ForEach-Object { [ordered]@{ path = $_.Key.Replace('\', '/'); sha256 = $_.Value } })
    license = 'Unreal Engine EULA - Examples'
    license_url = 'https://www.unrealengine.com/eula/unreal'
    imported_at_utc = [DateTime]::UtcNow.ToString('o')
    destination = '/IndraRuralAssets/Vegetation/UEExamples/HillTree'
    derived_bundle_sha256 = $bundleHash
    derived_assets = $derived
    unreal_validation = $report
}
$receiptPath = Join-Path $assetRepo 'EPIC_TEMPLATE_IMPORT_RECEIPT.json'
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -Encoding utf8
Write-Pass 'Rural tree import' "12 assets, $($report.mesh.lod_count) LODs, closed dependencies, bundle $bundleHash"
Write-Warn 'Map unchanged' 'The accepted tree is available in the asset plugin but has not yet replaced map vegetation.'
exit 0
