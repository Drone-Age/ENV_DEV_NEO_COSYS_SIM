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

function Stage-EnvironmentPlugin([object]$Manifest) {
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
