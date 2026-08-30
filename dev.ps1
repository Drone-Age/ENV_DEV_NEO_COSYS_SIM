[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'setup', 'build', 'run', 'test', 'camera-test', 'ros-test', 'vins-test', 'wind-test', 'stop', 'logs', 'env', 'capabilities')]
    [string]$Command = 'doctor',
    [Parameter(Position = 1)]
    [ValidateSet('list', 'doctor', 'build-map', 'import-assets')]
    [string]$EnvironmentCommand = 'list',
    [Parameter(Position = 2)]
    [string]$Environment = 'blocks',
    [ValidateSet('qualification', 'visual')]
    [string]$RenderProfile = 'qualification',
    [switch]$NoMissionPlanner,
    [switch]$Headless,
    [switch]$SkipBuild,
    [switch]$Preview,
    [switch]$Json,
    [string]$RunId = '',
    [string]$FlightLogDirectory = '',
    [switch]$Rosbag,
    [switch]$FlightQualification,
    [ValidateRange(1, 1000)][int]$FlightQualificationLimitM = 1000,
    [string]$FlightQualificationProfile = 'tests/vins_climb_unit/profile.json',
    [switch]$FlightQualificationNoWind,
    [switch]$FlightQualificationNoVisualUi,
    [switch]$RouteQualification,
    [string]$RouteQualificationProfile = 'tests/vins_10km_unit/profile.json',
    [string]$VinsConfigFile = '',
    [string]$Distro = 'Ubuntu',
    [switch]$WithRos2,
    [switch]$WithMissionPlanner
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'scripts\dev-command.ps1'
& $script @PSBoundParameters
exit $LASTEXITCODE
