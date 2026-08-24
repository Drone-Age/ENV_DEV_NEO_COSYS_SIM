[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'setup', 'build', 'run', 'test', 'camera-test', 'stop', 'logs')]
    [string]$Command = 'doctor',
    [switch]$NoMissionPlanner,
    [switch]$Headless,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'scripts\dev-command.ps1'
& $script -Command $Command -NoMissionPlanner:$NoMissionPlanner -Headless:$Headless -SkipBuild:$SkipBuild
exit $LASTEXITCODE
