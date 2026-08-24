[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Start')][string]$Action,
    [string]$RunDirectory,
    [int]$Port = 5782
)

. (Join-Path $PSScriptRoot 'common.ps1')
$component = $script:Lock.mission_planner
$toolDirectory = Join-Path $script:RuntimeRoot ("tools\mission-planner-{0}" -f $component.version)
$executable = Join-Path $toolDirectory 'MissionPlanner.exe'
$archiveDirectory = Join-Path $script:RuntimeRoot 'downloads'
$archivePath = Join-Path $archiveDirectory $component.archive

if ($Action -eq 'Setup') {
    New-Item -ItemType Directory -Force -Path $archiveDirectory, (Split-Path -Parent $toolDirectory) | Out-Null
    $valid = (Test-Path -LiteralPath $archivePath) -and ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $component.sha256)
    if (-not $valid) {
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
        Write-Step "Downloading Mission Planner $($component.version)"
        Invoke-WebRequest -Uri $component.url -OutFile $archivePath
    }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $component.sha256) { throw 'Mission Planner archive SHA-256 mismatch.' }
    if (-not (Test-Path -LiteralPath $executable)) {
        $staging = Join-Path $script:RuntimeRoot 'tools\mission-planner-extracting'
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $staging
        if (-not (Test-Path -LiteralPath (Join-Path $staging 'MissionPlanner.exe'))) { throw 'MissionPlanner.exe is missing from the archive.' }
        if (Test-Path -LiteralPath $toolDirectory) { Remove-Item -LiteralPath $toolDirectory -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $toolDirectory
    }
    Write-Pass 'Mission Planner' "$($component.version) portable"
    exit 0
}

if (-not $RunDirectory -or -not (Test-Path -LiteralPath $RunDirectory)) { throw 'A valid RunDirectory is required.' }
if (-not (Test-Path -LiteralPath $executable)) { throw 'Mission Planner is not installed. Run .\dev.ps1 setup.' }
$configPath = Join-Path $RunDirectory 'mission-planner\config.xml'
$logDirectory = Join-Path $RunDirectory 'mission-planner'
$autoConnect = ConvertTo-Json -Compress -InputObject @([ordered]@{ Label='INDRA Cosys SITL'; Enabled=$true; Port=$Port; Protocol='Tcp'; Format='MAVLink'; Direction='Outbound'; ConfigString='127.0.0.1' })
$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Config>
  <AutoConnect>$([Security.SecurityElement]::Escape($autoConnect))</AutoConnect>
  <comport>TCP</comport>
  <TCP_host>127.0.0.1</TCP_host>
  <TCP_port>$Port</TCP_port>
  <logdirectory>$([Security.SecurityElement]::Escape($logDirectory))</logdirectory>
  <loadwpsonconnect>False</loadwpsonconnect>
</Config>
"@
Set-Content -LiteralPath $configPath -Value $xml.TrimStart() -Encoding utf8
$process = Start-Process -FilePath $executable -WorkingDirectory $toolDirectory -ArgumentList @('-config', ('"{0}"' -f $configPath)) -PassThru
Start-Sleep -Seconds 2
if ($process.HasExited) { throw "Mission Planner exited with code $($process.ExitCode)." }
Save-ProcessState $process 'mission-planner' $RunDirectory
Write-Pass 'Mission Planner' "PID $($process.Id), TCP 127.0.0.1:$Port"
