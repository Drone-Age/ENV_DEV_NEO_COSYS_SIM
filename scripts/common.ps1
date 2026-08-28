Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeRoot = Join-Path $script:RepoRoot '.runtime'
$script:LogsRoot = Join-Path $script:RepoRoot 'logs'
$script:EnvironmentsRoot = Join-Path $script:RepoRoot 'environments'
$script:Config = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'config\demo.json') | ConvertFrom-Json
$script:Lock = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'components.lock.json') | ConvertFrom-Json
$environmentLockPath = Join-Path $script:RepoRoot 'environments.lock.json'
$script:EnvironmentLock = if (Test-Path -LiteralPath $environmentLockPath) { Get-Content -Raw -LiteralPath $environmentLockPath | ConvertFrom-Json } else { [pscustomobject]@{ environments = [pscustomobject]@{} } }

function Write-Step([string]$Message) { Write-Host "[indra-cosys] $Message" -ForegroundColor Cyan }
function Write-Pass([string]$Name, [string]$Detail) { Write-Host ("  PASS  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Green }
function Write-Fail([string]$Name, [string]$Detail) { Write-Host ("  FAIL  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Red }
function Write-Warn([string]$Name, [string]$Detail) { Write-Host ("  WARN  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Yellow }

function Initialize-EnvironmentPackage([string]$EnvironmentId) {
    $property = $script:EnvironmentLock.environments.psobject.Properties[$EnvironmentId]
    if (-not $property -or -not $property.Value.submodule) { return }
    $relativePath = [string]$property.Value.submodule
    $absolutePath = Join-Path $script:RepoRoot $relativePath
    $gitMarker = Join-Path $absolutePath '.git'
    if (-not (Test-Path -LiteralPath $gitMarker)) {
        Write-Step "Initialising environment submodule $relativePath"
        & git -C $script:RepoRoot submodule update --init --recursive -- $relativePath
        if ($LASTEXITCODE -ne 0) { throw "Unable to initialise private environment '$EnvironmentId'. Authenticate GitHub account access to Drone-Age and retry." }
    }
    $actual = (& git -C $absolutePath rev-parse HEAD 2>$null).Trim()
    if ($property.Value.commit -and $actual -ne $property.Value.commit) {
        throw "Environment '$EnvironmentId' must be at $($property.Value.commit), found $actual."
    }
}

function Resolve-EnvironmentPackageFile {
    param(
        [Parameter(Mandatory)][string]$EnvironmentRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Label must be a repository-relative path, found '$RelativePath'."
    }
    $root = [IO.Path]::GetFullPath($EnvironmentRoot).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the environment package: '$RelativePath'."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is missing: $resolved"
    }
    return $resolved
}

function Assert-EnvironmentAssetReceipts {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$EnvironmentRoot,
        [Parameter(Mandatory)][object]$Manifest
    )
    $property = $Manifest.psobject.Properties['asset_receipts']
    if (-not $property) { return }
    foreach ($entry in @($property.Value)) {
        $receiptPath = Resolve-EnvironmentPackageFile -EnvironmentRoot $EnvironmentRoot -RelativePath ([string]$entry.path) -Label "Environment '$EnvironmentId' asset receipt"
        try { $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json } catch { throw "Invalid JSON in asset receipt $receiptPath`: $($_.Exception.Message)" }
        if ([string]$receipt.status -ne [string]$entry.status) {
            throw "Environment '$EnvironmentId' asset receipt '$($entry.path)' status is '$($receipt.status)', expected '$($entry.status)'."
        }
        $sourceLock = [string]$receipt.source_lock
        if ([string]::IsNullOrWhiteSpace($sourceLock) -or [IO.Path]::IsPathRooted($sourceLock) -or $sourceLock -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
            throw "Environment '$EnvironmentId' asset receipt '$($entry.path)' contains a non-portable source_lock '$sourceLock'."
        }
        $receiptRoot = Split-Path -Parent $receiptPath
        Resolve-EnvironmentPackageFile -EnvironmentRoot $receiptRoot -RelativePath $sourceLock -Label "Environment '$EnvironmentId' asset source lock" | Out-Null
        $validationProperty = $receipt.psobject.Properties['unreal_validation']
        if ($validationProperty) {
            $validationLockProperty = $validationProperty.Value.psobject.Properties['source_lock']
            if ($validationLockProperty -and [string]$validationLockProperty.Value -ne $sourceLock) {
                throw "Environment '$EnvironmentId' asset receipt '$($entry.path)' has inconsistent Unreal source_lock '$($validationLockProperty.Value)'."
            }
        }
    }
}

function Assert-EnvironmentFieldCrops {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$EnvironmentRoot,
        [Parameter(Mandatory)][object]$Manifest
    )
    $mapBuildProperty = $Manifest.psobject.Properties['map_build']
    if (-not $mapBuildProperty) { return }
    $fieldCropsProperty = $mapBuildProperty.Value.psobject.Properties['field_crops']
    if (-not $fieldCropsProperty) { return }
    $fieldCrops = $fieldCropsProperty.Value
    $source = [string]$fieldCrops.source
    $strategyProperty = $fieldCrops.psobject.Properties['sowing_strategy']
    if ([string]::IsNullOrWhiteSpace($source) -or -not $strategyProperty) {
        throw "Environment '$EnvironmentId' field_crops must declare source and sowing_strategy."
    }
    $strategy = $strategyProperty.Value
    if ([string]$strategy.parcel_assignment -ne 'stable-per-field') {
        throw "Environment '$EnvironmentId' field_crops parcel_assignment must be stable-per-field."
    }
    $maskProperty = $fieldCrops.psobject.Properties['authoritative_cropland_mask']
    $seedProperty = $fieldCrops.psobject.Properties['assignment_seed']
    if (-not $maskProperty -or -not $seedProperty -or $seedProperty.Value -isnot [ValueType]) {
        throw "Environment '$EnvironmentId' field_crops requires an authoritative mask and numeric deterministic assignment seed."
    }
    Resolve-EnvironmentPackageFile -EnvironmentRoot $EnvironmentRoot -RelativePath ([string]$maskProperty.Value) -Label "Environment '$EnvironmentId' authoritative cropland mask" | Out-Null
    $baseline = @($strategy.baseline_crops | ForEach-Object { [string]$_ })
    if ($baseline.Count -lt 1 -or @($baseline | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or @($baseline | Select-Object -Unique).Count -ne $baseline.Count) {
        throw "Environment '$EnvironmentId' field_crops baseline_crops must contain unique non-empty asset ids."
    }
    $optional = @($strategy.optional_crops | ForEach-Object { [string]$_ })
    if (@($optional | Where-Object { $baseline -contains $_ }).Count -gt 0) {
        throw "Environment '$EnvironmentId' optional crops must not also appear in baseline_crops."
    }
    $exclusions = @($strategy.exclude | ForEach-Object { [string]$_ })
    foreach ($requiredExclusion in @('roads', 'buildings', 'water', 'qualification-clearing')) {
        if ($exclusions -notcontains $requiredExclusion) {
            throw "Environment '$EnvironmentId' field crop exclusions must include '$requiredExclusion'."
        }
    }
    foreach ($tier in @('near', 'mid', 'far')) {
        $tierProperty = $strategy.psobject.Properties[$tier]
        if (-not $tierProperty -or [string]::IsNullOrWhiteSpace([string]$tierProperty.Value)) {
            throw "Environment '$EnvironmentId' field crop strategy must define the '$tier' representation tier."
        }
    }

    $provenanceProperty = $Manifest.psobject.Properties['asset_provenance']
    if (-not $provenanceProperty -or @($provenanceProperty.Value).Count -lt 1) {
        throw "Environment '$EnvironmentId' field_crops requires at least one asset_provenance manifest."
    }
    $matches = @()
    foreach ($relativeProvenance in @($provenanceProperty.Value)) {
        $provenancePath = Resolve-EnvironmentPackageFile -EnvironmentRoot $EnvironmentRoot -RelativePath ([string]$relativeProvenance) -Label "Environment '$EnvironmentId' asset provenance"
        try { $provenance = Get-Content -Raw -LiteralPath $provenancePath | ConvertFrom-Json } catch { throw "Invalid JSON in asset provenance $provenancePath`: $($_.Exception.Message)" }
        $matches += @($provenance.assets | Where-Object { [string]$_.id -eq $source } | ForEach-Object { [pscustomobject]@{ Asset = $_; Root = Split-Path -Parent $provenancePath } })
    }
    if ($matches.Count -ne 1) {
        throw "Environment '$EnvironmentId' field crop source '$source' must resolve to exactly one provenance record; found $($matches.Count)."
    }
    $sourceAsset = $matches[0].Asset
    if ([string]::IsNullOrWhiteSpace([string]$sourceAsset.license) -or [string]::IsNullOrWhiteSpace([string]$sourceAsset.receipt)) {
        throw "Environment '$EnvironmentId' field crop source '$source' lacks licence or receipt provenance."
    }
    $sourceReceiptPath = Resolve-EnvironmentPackageFile -EnvironmentRoot $matches[0].Root -RelativePath ([string]$sourceAsset.receipt) -Label "Environment '$EnvironmentId' field crop receipt"
    $sourceReceipt = Get-Content -Raw -LiteralPath $sourceReceiptPath | ConvertFrom-Json
    if ([string]$sourceReceipt.status -ne 'accepted') {
        throw "Environment '$EnvironmentId' field crop receipt status is '$($sourceReceipt.status)', not 'accepted'."
    }
    $sourceMeshIds = @($sourceReceipt.source_files | Where-Object { [string]$_.role -eq 'mesh' } | ForEach-Object { [string]$_.id })
    $validatedMeshIds = @($sourceReceipt.unreal_validation.meshes | ForEach-Object { [string]$_.id })
    foreach ($crop in $baseline) {
        if ($sourceMeshIds -notcontains $crop -or $validatedMeshIds -notcontains $crop) {
            throw "Environment '$EnvironmentId' baseline crop '$crop' is not both source-pinned and Unreal-validated by '$source'."
        }
        $minimum = $fieldCrops.minimum_instances.psobject.Properties[$crop]
        $maximum = $fieldCrops.maximum_instances.psobject.Properties[$crop]
        if (-not $minimum -or -not $maximum -or [int64]$minimum.Value -lt 1 -or [int64]$maximum.Value -lt [int64]$minimum.Value) {
            throw "Environment '$EnvironmentId' baseline crop '$crop' requires valid minimum_instances and maximum_instances bounds."
        }
    }
}

function Get-EnvironmentManifest {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string]$EnvironmentId,
        [switch]$RequireReady,
        [switch]$AllowScaffold
    )
    $directory = Join-Path $script:EnvironmentsRoot $EnvironmentId
    $manifestPath = Join-Path $directory 'environment.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $locked = $script:EnvironmentLock.environments.psobject.Properties[$EnvironmentId]
        if ($locked) { throw "Environment '$EnvironmentId' is configured but not initialised. Run .\dev.ps1 setup -Environment $EnvironmentId." }
        throw "Unknown environment '$EnvironmentId'. Run .\dev.ps1 env list."
    }
    try { $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json } catch { throw "Invalid JSON in $manifestPath`: $($_.Exception.Message)" }
    if ([int]$manifest.schema -ne 1) { throw "Environment '$EnvironmentId' uses unsupported schema '$($manifest.schema)'." }
    if ($manifest.id -ne $EnvironmentId) { throw "Manifest id '$($manifest.id)' does not match directory '$EnvironmentId'." }
    if (-not $manifest.version -or -not $manifest.map_path -or -not $manifest.wgs84_origin) { throw "Environment '$EnvironmentId' is missing version, map_path or wgs84_origin." }
    if (-not ([string]$manifest.map_path).StartsWith('/')) { throw "Environment '$EnvironmentId' map_path must be an Unreal package path beginning with '/'." }
    if (@($manifest.compatibility.unreal_engine) -notcontains $script:Lock.platform.unreal_engine) { throw "Environment '$EnvironmentId' does not declare UE $($script:Lock.platform.unreal_engine) compatibility." }
    if ($manifest.content_plugin.path) {
        $pluginPath = Join-Path $directory ([string]$manifest.content_plugin.path)
        if (-not (Test-Path -LiteralPath $pluginPath -PathType Container)) { throw "Environment '$EnvironmentId' content plugin is missing: $pluginPath" }
        $descriptor = Join-Path $pluginPath ([string]$manifest.content_plugin.descriptor)
        if (-not (Test-Path -LiteralPath $descriptor -PathType Leaf)) { throw "Environment '$EnvironmentId' plugin descriptor is missing: $descriptor" }
    }
    $requiredPluginsProperty = $manifest.psobject.Properties['required_plugins']
    $requiredPlugins = if ($requiredPluginsProperty) { @($requiredPluginsProperty.Value) } else { @() }
    foreach ($requiredPlugin in $requiredPlugins) {
        $requiredPath = Join-Path $directory ([string]$requiredPlugin.path)
        $requiredDescriptor = Join-Path $requiredPath ([string]$requiredPlugin.descriptor)
        if (-not (Test-Path -LiteralPath $requiredDescriptor -PathType Leaf)) { throw "Environment '$EnvironmentId' required plugin is missing: $requiredDescriptor" }
    }
    Assert-EnvironmentAssetReceipts -EnvironmentId $EnvironmentId -EnvironmentRoot $directory -Manifest $manifest
    Assert-EnvironmentFieldCrops -EnvironmentId $EnvironmentId -EnvironmentRoot $directory -Manifest $manifest
    foreach ($dataset in @($manifest.datasets)) {
        $derivedManifestProperty = $dataset.psobject.Properties['derived_manifest']
        if (-not $derivedManifestProperty) { continue }
        $derivedManifest = Join-Path $directory ([string]$derivedManifestProperty.Value)
        if (-not (Test-Path -LiteralPath $derivedManifest -PathType Leaf)) {
            throw "Environment '$EnvironmentId' dataset '$($dataset.id)' is missing its derived manifest/LFS object: $derivedManifest"
        }
        if ($RequireReady) {
            $provenance = Get-Content -Raw -LiteralPath $derivedManifest | ConvertFrom-Json
            $records = @()
            foreach ($layerName in @('height', 'imagery')) {
                $layerProperty = $provenance.psobject.Properties[$layerName]
                if (-not $layerProperty) { continue }
                $fullProperty = $layerProperty.Value.psobject.Properties['full']
                if ($fullProperty) { $records += $fullProperty.Value }
                $tilesProperty = $layerProperty.Value.psobject.Properties['tiles']
                if ($tilesProperty) { $records += @($tilesProperty.Value) }
            }
            foreach ($record in $records) {
                $artifact = Join-Path (Split-Path -Parent $derivedManifest) ([string]$record.path)
                if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Environment '$EnvironmentId' derived artifact/LFS object is missing: $artifact" }
                $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
                if ($actualHash -ne [string]$record.sha256) { throw "Environment '$EnvironmentId' derived artifact hash mismatch or unresolved LFS pointer: $artifact" }
            }
        }
    }
    if ($RequireReady -and $manifest.readiness -ne 'ready') { throw "Environment '$EnvironmentId' readiness is '$($manifest.readiness)', not 'ready'." }
    if (-not $AllowScaffold -and -not $RequireReady -and $manifest.readiness -eq 'scaffold') { throw "Environment '$EnvironmentId' is only a scaffold." }
    return $manifest
}

function Get-RuntimeEnvironmentManifest {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [switch]$Preview
    )
    if (-not $Preview) {
        return Get-EnvironmentManifest -EnvironmentId $EnvironmentId -RequireReady
    }
    $manifest = Get-EnvironmentManifest -EnvironmentId $EnvironmentId
    if ($manifest.readiness -notin @('preview', 'ready')) {
        throw "Environment '$EnvironmentId' readiness is '$($manifest.readiness)'; -Preview permits only preview or ready environments."
    }
    return $manifest
}

function Install-EnvironmentExternalPlugins([object]$Manifest) {
    $property = $Manifest.psobject.Properties['external_plugins']
    if (-not $property) { return }

    $ueRoot = Get-UeRoot
    if (-not $ueRoot) { throw 'UE 5.8.1 is required before external Unreal plugins can be installed.' }
    # Official prebuilt Marketplace plugins must live under the Engine. If they
    # are placed in the project UBT treats their Source as project code and
    # needlessly recompiles already compatible release binaries.
    $externalRoot = [IO.Path]::GetFullPath((Join-Path $ueRoot 'Engine\Plugins\Marketplace'))
    $downloadRoot = [IO.Path]::GetFullPath((Join-Path $script:RuntimeRoot 'downloads'))
    New-Item -ItemType Directory -Force -Path $externalRoot, $downloadRoot | Out-Null

    $legacyProjectExternal = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins\External'))
    if (Test-Path -LiteralPath $legacyProjectExternal) {
        $projectPluginsRoot = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins'))
        if (-not $legacyProjectExternal.StartsWith($projectPluginsRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $legacyProjectExternal) -ne 'External') {
            throw "Unsafe legacy external plugin cleanup path: $legacyProjectExternal"
        }
        Remove-Item -LiteralPath $legacyProjectExternal -Recurse -Force
    }

    foreach ($plugin in @($property.Value)) {
        $name = [string]$plugin.name
        $target = [IO.Path]::GetFullPath((Join-Path $externalRoot $name))
        if (-not $target.StartsWith($externalRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $target) -ne $name) {
            throw "Unsafe external plugin target: $target"
        }
        $descriptor = Join-Path $target ([string]$plugin.descriptor)
        $receiptPath = Join-Path $target '.indra-install.json'
        $pluginModulesPath = Join-Path $target 'Binaries\Win64\UnrealEditor.modules'
        $engineModulesPath = Join-Path $ueRoot 'Engine\Binaries\Win64\UnrealEditor.modules'
        $validInstall = $false
        if ((Test-Path -LiteralPath $descriptor -PathType Leaf) -and
            (Test-Path -LiteralPath $receiptPath -PathType Leaf) -and
            (Test-Path -LiteralPath $pluginModulesPath -PathType Leaf) -and
            (Test-Path -LiteralPath $engineModulesPath -PathType Leaf)) {
            try {
                $installed = Get-Content -Raw -LiteralPath $descriptor | ConvertFrom-Json
                $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
                $pluginModules = Get-Content -Raw -LiteralPath $pluginModulesPath | ConvertFrom-Json
                $engineModules = Get-Content -Raw -LiteralPath $engineModulesPath | ConvertFrom-Json
                $validInstall = [string]$installed.VersionName -eq [string]$plugin.version -and
                    [string]$installed.EngineVersion -eq [string]$plugin.engine_version -and
                    [string]$receipt.archive_sha256 -eq ([string]$plugin.sha256).ToLowerInvariant() -and
                    [string]$receipt.source_url -eq [string]$plugin.url -and
                    [string]$pluginModules.BuildId -eq [string]$engineModules.BuildId
            } catch { $validInstall = $false }
        }
        if ($validInstall) {
            Write-Pass "External plugin $name" "v$($plugin.version), UE $($plugin.engine_version), cached"
            continue
        }

        $archive = [IO.Path]::GetFullPath((Join-Path $downloadRoot ([string]$plugin.archive)))
        $expectedHash = ([string]$plugin.sha256).ToLowerInvariant()
        $archiveValid = (Test-Path -LiteralPath $archive -PathType Leaf) -and
            ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant() -eq $expectedHash)
        if (-not $archiveValid) {
            $partial = "$archive.partial"
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if (-not $curl) { throw "curl.exe is required to download external plugin $name." }
            Write-Step "Downloading pinned external plugin $name v$($plugin.version)"
            & $curl.Source -L --fail --retry 3 --output $partial ([string]$plugin.url)
            if ($LASTEXITCODE -ne 0) { throw "Download failed for external plugin $name." }
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                throw "SHA-256 mismatch for external plugin $name`: expected $expectedHash, received $actualHash."
            }
            Move-Item -LiteralPath $partial -Destination $archive -Force
        }

        $extractRoot = [IO.Path]::GetFullPath((Join-Path $script:RuntimeRoot ("extract-{0}-{1}" -f $name, [guid]::NewGuid().ToString('N'))))
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        try {
            Write-Step "Installing pinned external plugin $name v$($plugin.version)"
            & tar.exe -xf $archive -C $extractRoot
            if ($LASTEXITCODE -ne 0) { throw "Extraction failed for external plugin $name." }
            $source = Join-Path $extractRoot $name
            $sourceDescriptor = Join-Path $source ([string]$plugin.descriptor)
            if (-not (Test-Path -LiteralPath $sourceDescriptor -PathType Leaf)) {
                throw "External plugin archive does not contain $name/$($plugin.descriptor)."
            }
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            & robocopy.exe $source $target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "External plugin staging failed with robocopy code $LASTEXITCODE." }
            Write-JsonFile ([ordered]@{
                schema = 1
                name = $name
                version = [string]$plugin.version
                engine_version = [string]$plugin.engine_version
                source_url = [string]$plugin.url
                archive_sha256 = $expectedHash
                installed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
            }) $receiptPath
        } finally {
            if ($extractRoot.StartsWith($script:RuntimeRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        $pluginBuildId = (Get-Content -Raw -LiteralPath $pluginModulesPath | ConvertFrom-Json).BuildId
        $engineBuildId = (Get-Content -Raw -LiteralPath $engineModulesPath | ConvertFrom-Json).BuildId
        if (-not (Test-Path -LiteralPath $descriptor) -or -not (Test-Path -LiteralPath $receiptPath) -or
            $installedHash -ne $expectedHash -or [string]$pluginBuildId -ne [string]$engineBuildId) {
            throw "External plugin $name installation verification failed."
        }
        Write-Pass "External plugin $name" "v$($plugin.version), UE $($plugin.engine_version), SHA-256 verified"
    }
}

function Stage-EnvironmentPlugin([object]$Manifest) {
    Install-EnvironmentExternalPlugins -Manifest $Manifest
    $projectPluginsRoot = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins'))
    $stagingRoot = [IO.Path]::GetFullPath((Join-Path $projectPluginsRoot 'Environments'))
    if (-not $stagingRoot.StartsWith($projectPluginsRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $stagingRoot) -ne 'Environments') {
        throw "Unsafe environment staging path: $stagingRoot"
    }
    $plugins = @()
    if ($Manifest.content_plugin.path) { $plugins += $Manifest.content_plugin }
    $requiredPluginsProperty = $Manifest.psobject.Properties['required_plugins']
    if ($requiredPluginsProperty) { $plugins += @($requiredPluginsProperty.Value) }
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    $desiredNames = @($plugins | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_.descriptor) })
    foreach ($existing in Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue) {
        if ($desiredNames -contains $existing.Name) { continue }
        $existingPath = [IO.Path]::GetFullPath($existing.FullName)
        if (-not $existingPath.StartsWith($stagingRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe staged plugin cleanup path: $existingPath"
        }
        Remove-Item -LiteralPath $existingPath -Recurse -Force
    }
    foreach ($plugin in $plugins) {
        $source = Join-Path (Join-Path $script:EnvironmentsRoot $Manifest.id) ([string]$plugin.path)
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$plugin.descriptor)
        $target = Join-Path $stagingRoot $name
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        # Keep locally generated module products. A runtime launch must not erase
        # the Editor DLL that Invoke-Build or env build-map just produced.
        & robocopy.exe $source $target /MIR /XD Binaries Intermediate Saved DerivedDataCache /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Environment plugin '$name' staging failed with robocopy code $LASTEXITCODE." }
    }
}

function Get-UeRoot {
    $candidates = @()
    if ($env:INDRA_UE_ROOT) { $candidates += $env:INDRA_UE_ROOT }
    $candidates += (Join-Path $env:ProgramFiles 'Epic Games\UE_5.8')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'Engine\Binaries\Win64\UnrealEditor.exe'))) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $path = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $path) { return $null }
    return ([string]$path).Trim()
}

function Get-MsvcVersion([string]$VsRoot) {
    if (-not $VsRoot) { return $null }
    $root = Join-Path $VsRoot 'VC\Tools\MSVC'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $match = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -like '14.44.*' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if ($match) { return $match.Name }
    return $null
}

function Get-MsvcCompilerVersion([string]$VsRoot, [string]$ToolsetVersion) {
    if (-not $VsRoot -or -not $ToolsetVersion) { return $null }
    $compiler = Join-Path $VsRoot "VC\Tools\MSVC\$ToolsetVersion\bin\Hostx64\x64\cl.exe"
    if (-not (Test-Path -LiteralPath $compiler)) { return $null }
    $info = (Get-Item -LiteralPath $compiler).VersionInfo
    if (-not $info.ProductMajorPart) { return $null }
    return "$($info.ProductMajorPart).$($info.ProductMinorPart).$($info.ProductBuildPart)"
}

function Test-MsvcVersion([string]$Version) {
    if (-not $Version) { return $false }
    return ([version]$Version -ge [version]$script:Lock.platform.msvc_minimum)
}

function Get-WindowsSdkRoot {
    try {
        return (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
    } catch { return $null }
}

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Command, [switch]$AllowFailure)
    $output = & wsl.exe -d $script:Lock.platform.wsl_distribution -- bash -lc $Command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "WSL command failed ($code): $Command`n$($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = @($output) }
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ($WindowsPath.Contains("'")) { throw "Apostrophes in repository paths are not supported: $WindowsPath" }
    $result = Invoke-Wsl -Command "wslpath -a '$WindowsPath'"
    return ([string]($result.Output | Select-Object -Last 1)).Trim()
}

function Get-NetworkInfo {
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    $mirrored = $false
    if (Test-Path -LiteralPath $wslConfig) {
        $inWsl2 = $false
        foreach ($line in Get-Content -LiteralPath $wslConfig) {
            if ($line -match '^\s*\[(?<section>[^]]+)\]\s*$') { $inWsl2 = $Matches.section -ieq 'wsl2'; continue }
            if ($inWsl2 -and $line -match '^\s*networkingMode\s*=\s*mirrored\s*(?:[#;].*)?$') { $mirrored = $true; break }
        }
    }
    if ($mirrored) {
        return [pscustomobject]@{ WslIp = '127.0.0.1'; WindowsIp = '127.0.0.1'; Mode = 'mirrored' }
    }
    $wslIpResult = Invoke-Wsl -Command 'hostname -I'
    $wslIp = (([string]($wslIpResult.Output -join ' ')).Trim() -split '\s+')[0]
    $windowsIpResult = Invoke-Wsl -Command 'ip route show default'
    $route = ([string]($windowsIpResult.Output -join ' ')).Trim()
    if ($route -notmatch '\bdefault\s+via\s+(?<address>\S+)') { throw "Unable to determine Windows host IP from WSL route: $route" }
    $windowsIp = $Matches.address
    $parsedWsl = $null
    $parsedWindows = $null
    if (-not [Net.IPAddress]::TryParse($wslIp, [ref]$parsedWsl)) { throw "Invalid WSL IP: $wslIp" }
    if (-not [Net.IPAddress]::TryParse($windowsIp, [ref]$parsedWindows)) { throw "Invalid Windows host IP: $windowsIp" }
    return [pscustomobject]@{ WslIp = $wslIp; WindowsIp = $windowsIp; Mode = 'nat' }
}

function New-RunDirectory {
    param([string]$Kind, [string]$RequestedRunId = '', [string]$RequestedDirectory = '')
    if ($RequestedRunId -and $RequestedRunId -notmatch '^[A-Za-z0-9_-]+$') { throw "RunId must contain only letters, numbers, underscore and dash: '$RequestedRunId'." }
    $runId = if ($RequestedRunId) { $RequestedRunId } else { '{0}_{1}_{2}' -f (Get-Date -Format 'HHmmss'), $Kind, ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
    if ($RequestedDirectory) {
        $directory = [IO.Path]::GetFullPath($RequestedDirectory)
        if (Test-Path -LiteralPath $directory) {
            $existing = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)
            $allowedLauncherFiles = @('test-run.json', 'launcher-transcript.log')
            $unexpected = @($existing | Where-Object { $_.PSIsContainer -or $_.Name -notin $allowedLauncherFiles })
            if ($unexpected.Count) { throw "FlightLogDirectory already contains unexpected evidence: $directory ($($unexpected.Name -join ', '))" }
        }
    } else {
        $day = Get-Date -Format 'yyyy-MM-dd'
        $directory = Join-Path $script:LogsRoot "$day`_$runId"
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $directory 'unreal'), (Join-Path $directory 'sitl'), (Join-Path $directory 'mission-planner') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Value $directory -Encoding utf8
    return $directory
}

function Get-ActiveRun {
    $state = Join-Path $script:RuntimeRoot 'active-run.txt'
    if (-not (Test-Path -LiteralPath $state)) { return $null }
    $path = (Get-Content -Raw -LiteralPath $state).Trim()
    if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    return $null
}

function Write-JsonFile([object]$Value, [string]$Path, [int]$Depth = 10) {
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-AirSimSettings([string]$RunDirectory) {
    $network = Get-NetworkInfo
    $template = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'config\airsim\settings.json.template')
    $values = [ordered]@{
        '__CLOCK_SPEED__' = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $script:Config.clock_speed)
        '__RPC_PORT__' = [string]$script:Config.ports.cosys_rpc_tcp
        '__ORIGIN_LAT__' = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:R}', [double]$script:Config.origin.latitude)
        '__ORIGIN_LON__' = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:R}', [double]$script:Config.origin.longitude)
        '__ORIGIN_ALT__' = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:R}', [double]$script:Config.origin.altitude_m)
        '__WINDOWS_IP__' = $network.WindowsIp
        '__WSL_IP__' = $network.WslIp
        '__SENSOR_PORT__' = [string]$script:Config.ports.sitl_sensor_udp
        '__CONTROL_PORT__' = [string]$script:Config.ports.cosys_control_udp
    }
    foreach ($entry in $values.GetEnumerator()) { $template = $template.Replace($entry.Key, $entry.Value) }
    $path = Join-Path $RunDirectory 'settings.json'
    Set-Content -LiteralPath $path -Value $template -Encoding utf8
    Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | Out-Null
    return [pscustomobject]@{ Path = $path; Network = $network }
}

function Save-ProcessState([Diagnostics.Process]$Process, [string]$Name, [string]$RunDirectory) {
    $state = [ordered]@{
        name = $Name
        pid = $Process.Id
        start_time_utc_ticks = $Process.StartTime.ToUniversalTime().Ticks
        executable = $Process.Path
    }
    Write-JsonFile $state (Join-Path $RunDirectory "$Name-process.json")
}

function Get-RecordedProcess([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $process = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks -eq [int64]$state.start_time_utc_ticks) { return $process }
    } catch { }
    return $null
}

function Stop-RecordedProcesses([string]$RunDirectory) {
    # Stop Linux consumers/producers before Unreal. Otherwise their final RPC
    # calls time out against a dead Cosys server and contaminate a PASS bundle
    # with false bridge errors during normal cleanup.
    $stopper = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\stop_process_group.sh')
    foreach ($relativePidPath in @('vins\wsl.pid', 'ros2\wsl.pid', 'sitl\wsl.pid', 'sitl\sitl.pid')) {
        $wslPidFile = Join-Path $RunDirectory $relativePidPath
        if (Test-Path -LiteralPath $wslPidFile) {
            $pidValue = (Get-Content -Raw -LiteralPath $wslPidFile).Trim()
            if ($pidValue -match '^\d+$') {
                $graceSeconds = if ($relativePidPath -eq 'ros2\wsl.pid') { 4 } else { 1 }
                Invoke-Wsl -Command "bash '$stopper' '$pidValue' '$graceSeconds'" -AllowFailure | Out-Null
            }
            Remove-Item -LiteralPath $wslPidFile -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($statePath in Get-ChildItem -LiteralPath $RunDirectory -Filter '*-process.json' -File -ErrorAction SilentlyContinue) {
        $process = Get-RecordedProcess $statePath.FullName
        if ($process) {
            Write-Step "Stopping $($statePath.BaseName) PID $($process.Id)"
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $statePath.FullName -Force -ErrorAction SilentlyContinue
    }
}
