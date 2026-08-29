[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnrealEditor,
    [int]$ControlPort = 9022,
    [int]$SensorPort = 9023
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$classicName = 'INDRA Cosys UE UDP 9022'
$classic = Get-NetFirewallRule -DisplayName $classicName -ErrorAction SilentlyContinue
if ($classic) {
    $classic | Set-NetFirewallRule -Profile Any -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop
    $classic | Get-NetFirewallApplicationFilter -ErrorAction Stop | Set-NetFirewallApplicationFilter -Program $UnrealEditor -ErrorAction Stop
    $classic | Get-NetFirewallPortFilter -ErrorAction Stop | Set-NetFirewallPortFilter -Protocol UDP -LocalPort $ControlPort -ErrorAction Stop
} else {
    New-NetFirewallRule -DisplayName $classicName -Direction Inbound -Action Allow -Program $UnrealEditor -Protocol UDP -LocalPort $ControlPort -Profile Any -ErrorAction Stop | Out-Null
}

$wslCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$hyperVName = 'INDRA Cosys SITL UDP 9023'
$hyperVRule = Get-NetFirewallHyperVRule -DisplayName $hyperVName -ErrorAction SilentlyContinue
if ($hyperVRule) {
    $hyperVRule | Set-NetFirewallHyperVRule -Enabled True -Profiles Any -Action Allow -Direction Inbound -Protocol UDP -LocalPorts $SensorPort -RemoteAddresses LocalSubnet4 -ErrorAction Stop
} else {
    New-NetFirewallHyperVRule -Name 'INDRA-Cosys-SITL-UDP-9023' -DisplayName $hyperVName -Direction Inbound -VMCreatorId $wslCreator -Protocol UDP -LocalPorts $SensorPort -RemoteAddresses LocalSubnet4 -Action Allow -Enabled True -Profiles Any -ErrorAction Stop | Out-Null
}
