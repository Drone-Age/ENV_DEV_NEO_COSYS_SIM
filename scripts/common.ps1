Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeRoot = Join-Path $script:RepoRoot '.runtime'
$script:LogsRoot = Join-Path $script:RepoRoot 'logs'
$script:Config = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'config\demo.json') | ConvertFrom-Json
$script:Lock = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'components.lock.json') | ConvertFrom-Json

function Write-Step([string]$Message) { Write-Host "[indra-cosys] $Message" -ForegroundColor Cyan }
function Write-Pass([string]$Name, [string]$Detail) { Write-Host ("  PASS  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Green }
function Write-Fail([string]$Name, [string]$Detail) { Write-Host ("  FAIL  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Red }
function Write-Warn([string]$Name, [string]$Detail) { Write-Host ("  WARN  {0,-24} {1}" -f $Name, $Detail) -ForegroundColor Yellow }

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
    return [pscustomobject]@{ WslIp = $wslIp; WindowsIp = $windowsIp }
}

function New-RunDirectory([string]$Kind) {
    $day = Get-Date -Format 'yyyy-MM-dd'
    $runId = '{0}_{1}_{2}' -f (Get-Date -Format 'HHmmss'), $Kind, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $directory = Join-Path $script:LogsRoot "$day`_$runId"
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
    foreach ($statePath in Get-ChildItem -LiteralPath $RunDirectory -Filter '*-process.json' -File -ErrorAction SilentlyContinue) {
        $process = Get-RecordedProcess $statePath.FullName
        if ($process) {
            Write-Step "Stopping $($statePath.BaseName) PID $($process.Id)"
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $statePath.FullName -Force -ErrorAction SilentlyContinue
    }
    foreach ($pidName in @('sitl.pid', 'wsl.pid')) {
        $wslPidFile = Join-Path $RunDirectory "sitl\$pidName"
        if (Test-Path -LiteralPath $wslPidFile) {
            $pidValue = (Get-Content -Raw -LiteralPath $wslPidFile).Trim()
            if ($pidValue -match '^\d+$') {
                Invoke-Wsl -Command "kill -TERM $pidValue 2>/dev/null || true; sleep 1; kill -KILL $pidValue 2>/dev/null || true" -AllowFailure | Out-Null
            }
            Remove-Item -LiteralPath $wslPidFile -Force -ErrorAction SilentlyContinue
        }
    }
}
