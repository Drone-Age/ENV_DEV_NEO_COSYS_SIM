[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Status', 'EnableMirrored', 'Restore')]
    [string]$Action,
    [string]$Distro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$runtimeRoot = Join-Path $repoRoot '.runtime'
$configPath = Join-Path $env:USERPROFILE '.wslconfig'
$statePath = Join-Path $runtimeRoot 'wsl-network-mode-backup.json'
$backupPath = Join-Path $runtimeRoot 'wslconfig.before-indra-cosys'

function Get-ConfiguredMode {
    if (-not (Test-Path -LiteralPath $configPath)) { return 'nat (default; .wslconfig absent)' }
    $inWsl2 = $false
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match '^\s*\[(?<section>[^]]+)\]\s*$') {
            $inWsl2 = $Matches.section -ieq 'wsl2'
            continue
        }
        if ($inWsl2 -and $line -match '^\s*networkingMode\s*=\s*(?<mode>[^#;\s]+)') { return $Matches.mode.ToLowerInvariant() }
    }
    return 'nat (default)'
}

function Assert-NoActiveWslSimulation {
    $activeRun = Join-Path $runtimeRoot 'active-run.txt'
    if (Test-Path -LiteralPath $activeRun) { throw "NewSIM has an active run. Use .\dev.ps1 stop first: $((Get-Content -Raw -LiteralPath $activeRun).Trim())" }
    $output = & wsl.exe -d $Distro -- bash -lc "pgrep -af '[a]rducopter|[g]z sim|[c]osys_ros2_bridge|[s]im_vehicle.py' || true" 2>&1
    if (($output -join "`n").Trim()) { throw "WSL simulation processes are active. Stop NewSIM/SIM2 before changing networking:`n$($output -join "`n")" }
}

function Set-MirroredConfig {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $configPath) {
        foreach ($line in Get-Content -LiteralPath $configPath) { $lines.Add($line) }
    }
    $output = [Collections.Generic.List[string]]::new()
    $inWsl2 = $false
    $foundSection = $false
    $setMode = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(?<section>[^]]+)\]\s*$') {
            if ($inWsl2 -and -not $setMode) { $output.Add('networkingMode=mirrored'); $setMode = $true }
            $inWsl2 = $Matches.section -ieq 'wsl2'
            if ($inWsl2) { $foundSection = $true }
            $output.Add($line)
            continue
        }
        if ($inWsl2 -and $line -match '^\s*networkingMode\s*=') {
            if (-not $setMode) { $output.Add('networkingMode=mirrored'); $setMode = $true }
            continue
        }
        $output.Add($line)
    }
    if ($inWsl2 -and -not $setMode) { $output.Add('networkingMode=mirrored'); $setMode = $true }
    if (-not $foundSection) {
        if ($output.Count -and $output[$output.Count - 1]) { $output.Add('') }
        $output.Add('[wsl2]')
        $output.Add('networkingMode=mirrored')
    }
    Set-Content -LiteralPath $configPath -Value $output -Encoding utf8
}

switch ($Action) {
    'Status' {
        Write-Host "Configured WSL mode: $(Get-ConfiguredMode)"
        Write-Host "Config: $configPath"
        if (Test-Path -LiteralPath $statePath) { Write-Host "Rollback state: $statePath" }
    }
    'EnableMirrored' {
        Assert-NoActiveWslSimulation
        if (Test-Path -LiteralPath $statePath) { throw "Rollback state already exists: $statePath. Restore it before another experiment." }
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $hadConfig = Test-Path -LiteralPath $configPath
        if ($hadConfig) { Copy-Item -LiteralPath $configPath -Destination $backupPath }
        Set-MirroredConfig
        $state = [ordered]@{
            schema = 1
            config_path = $configPath
            had_config = $hadConfig
            backup_path = if ($hadConfig) { $backupPath } else { $null }
            enabled_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash.ToLowerInvariant()
            changed_at = (Get-Date).ToUniversalTime().ToString('o')
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed after writing mirrored configuration.' }
        Write-Host "WSL mirrored mode enabled with rollback state: $statePath" -ForegroundColor Green
    }
    'Restore' {
        Assert-NoActiveWslSimulation
        if (-not (Test-Path -LiteralPath $statePath)) { throw "No INDRA rollback state exists: $statePath" }
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $configPath)) { throw "Expected mirrored config is missing: $configPath" }
        $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash.ToLowerInvariant()
        if ($currentHash -ne $state.enabled_sha256) { throw 'The user modified .wslconfig after the experiment began. Refusing to overwrite those changes; restore manually from the recorded backup.' }
        if ([bool]$state.had_config) {
            Copy-Item -LiteralPath ([string]$state.backup_path) -Destination $configPath -Force
            Remove-Item -LiteralPath ([string]$state.backup_path) -Force
        } else {
            Remove-Item -LiteralPath $configPath -Force
        }
        Remove-Item -LiteralPath $statePath -Force
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed after restoring configuration.' }
        Write-Host 'Previous WSL networking configuration restored.' -ForegroundColor Green
    }
}
