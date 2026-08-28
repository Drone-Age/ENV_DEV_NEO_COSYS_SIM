[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ue = Get-UeRoot
if (-not $ue) { throw 'UE 5.8.1 was not found. Run .\dev.ps1 doctor.' }
$editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
$assetRepo = [IO.Path]::GetFullPath((Join-Path $script:EnvironmentsRoot 'sim2-rural\Plugins\IndraRuralAssets'))
$lockPath = Join-Path $assetRepo 'QUATERNIUS_CROP_SOURCE_LOCK.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
if ($lock.schema -ne 1 -or $lock.license -ne 'CC0-1.0' -or @($lock.files | Where-Object role -eq 'mesh').Count -ne 2) {
    throw 'QUATERNIUS_CROP_SOURCE_LOCK.json does not match the reviewed two-mesh CC0 source set.'
}

$runtimeBase = [IO.Path]::GetFullPath($script:RuntimeRoot)
$runtimePrefix = $runtimeBase.TrimEnd('\') + '\'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $runtimeBase 'quaternius-crop-source'))
$stagingRoot = [IO.Path]::GetFullPath((Join-Path $runtimeBase 'quaternius-crop-import'))
foreach ($candidate in @($sourceRoot, $stagingRoot)) {
    if (-not $candidate.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe Quaternius runtime path: $candidate"
    }
}
New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
$headers = @{ 'User-Agent' = 'Drone-Age-INDRA-NewSIM/0.3 (CC0 asset acquisition; https://github.com/Drone-Age)' }
$verifiedSources = @()
foreach ($file in $lock.files) {
    $destination = Join-Path $sourceRoot $file.name
    $needsDownload = -not (Test-Path -LiteralPath $destination -PathType Leaf)
    if (-not $needsDownload) {
        $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $needsDownload = $existingHash -ne $file.sha256 -or (Get-Item -LiteralPath $destination).Length -ne [int64]$file.bytes
    }
    if ($needsDownload) {
        $url = "https://drive.usercontent.google.com/download?id=$($file.google_drive_id)&export=download&confirm=t"
        Invoke-WebRequest -Uri $url -Headers $headers -OutFile $destination
    }
    $item = Get-Item -LiteralPath $destination
    $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne [int64]$file.bytes -or $actualHash -ne $file.sha256) {
        throw "Pinned Quaternius source changed or download is corrupt: $($file.name)"
    }
    $verifiedSources += [ordered]@{
        id = $file.id
        role = $file.role
        file = $file.name
        bytes = $item.Length
        sha256 = $actualHash
        google_drive_id = $file.google_drive_id
    }
}
Write-Pass 'Quaternius crop sources' "$($verifiedSources.Count) pinned CC0 files, SHA-256 verified"

if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
$tempPluginRoot = Join-Path $stagingRoot 'Plugins\IndraRuralAssets'
New-Item -ItemType Directory -Force -Path $tempPluginRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $assetRepo 'Plugins\IndraRuralAssets\IndraRuralAssets.uplugin') -Destination (Join-Path $tempPluginRoot 'IndraRuralAssets.uplugin')
$projectPath = Join-Path $stagingRoot 'IndraQuaterniusImport.uproject'
$project = [ordered]@{
    FileVersion = 3
    EngineAssociation = '5.8'
    Category = 'INDRA'
    Description = 'Disposable project for deterministic Quaternius CC0 crop imports.'
    Plugins = @(
        [ordered]@{ Name = 'PythonScriptPlugin'; Enabled = $true },
        [ordered]@{ Name = 'EditorScriptingUtilities'; Enabled = $true },
        [ordered]@{ Name = 'IndraRuralAssets'; Enabled = $true }
    )
}
$project | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $projectPath -Encoding utf8

$reportPath = Join-Path $stagingRoot 'import-report.json'
$logPath = Join-Path $script:RuntimeRoot 'quaternius-crop-import.log'
$env:INDRA_QUATERNIUS_SOURCE_ROOT = $sourceRoot
$env:INDRA_QUATERNIUS_LOCK = $lockPath
$env:INDRA_ASSET_IMPORT_REPORT = $reportPath
try {
    & $editor $projectPath "-ExecutePythonScript=$(Join-Path $PSScriptRoot 'unreal\import_quaternius_crops.py')" -unattended -nop4 -nosplash -NoSound -NullRHI "-abslog=$logPath"
    if ($LASTEXITCODE -ne 0) { throw "Quaternius crop import failed; see $logPath" }
} finally {
    Remove-Item Env:INDRA_QUATERNIUS_SOURCE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:INDRA_QUATERNIUS_LOCK -ErrorAction SilentlyContinue
    Remove-Item Env:INDRA_ASSET_IMPORT_REPORT -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "UE did not create the Quaternius crop import report; see $logPath" }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.status -ne 'PASS' -or @($report.meshes).Count -ne 2 -or @($report.external_dependencies).Count -ne 0) {
    throw "Quaternius crop import report is not a closed PASS; see $reportPath"
}
# The Unreal-side report necessarily receives an absolute lock path through the
# process environment.  Receipts are repository artefacts, so normalise that
# machine-local value before persisting the report.
$report.source_lock = 'QUATERNIUS_CROP_SOURCE_LOCK.json'

$generatedRoot = Join-Path $tempPluginRoot 'Content\Vegetation\QuaterniusCrops'
$destinationRoot = [IO.Path]::GetFullPath((Join-Path $assetRepo 'Plugins\IndraRuralAssets\Content\Vegetation\QuaterniusCrops'))
$contentRoot = [IO.Path]::GetFullPath((Join-Path $assetRepo 'Plugins\IndraRuralAssets\Content'))
if (-not $destinationRoot.StartsWith($contentRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $destinationRoot) -ne 'QuaterniusCrops') {
    throw "Unsafe rural asset destination: $destinationRoot"
}
New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
& robocopy.exe $generatedRoot $destinationRoot /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Quaternius crop asset sync failed with robocopy code $LASTEXITCODE." }

$derived = @(Get-ChildItem -LiteralPath $destinationRoot -Recurse -File -Filter '*.uasset' | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($destinationRoot.Length + 1).Replace('\', '/')
    [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = $_.Length }
})
$bundleText = ($derived | ForEach-Object { "$($_.path)|$($_.sha256)|$($_.bytes)" }) -join "`n"
$bundleHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($bundleText))).ToLowerInvariant()
$receipt = [ordered]@{
    schema = 1
    id = 'quaternius-crop-selection-v1'
    status = 'accepted'
    provider = $lock.provider
    author = $lock.author
    license = $lock.license
    license_url = $lock.license_url
    imported_at_utc = [DateTime]::UtcNow.ToString('o')
    source_lock = 'QUATERNIUS_CROP_SOURCE_LOCK.json'
    source_files = $verifiedSources
    destination = '/IndraRuralAssets/Vegetation/QuaterniusCrops'
    derived_bundle_sha256 = $bundleHash
    derived_assets = $derived
    unreal_validation = $report
}
$receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $assetRepo 'QUATERNIUS_CROP_IMPORT_RECEIPT.json') -Encoding utf8
Write-Pass 'Quaternius crop import' "2 meshes, $($derived.Count) packages, closed dependencies, bundle $bundleHash"
exit 0
