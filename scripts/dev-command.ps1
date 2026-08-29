[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('doctor', 'setup', 'build', 'run', 'test', 'camera-test', 'ros-test', 'vins-test', 'ivins', 'stop', 'logs', 'env', 'capabilities')][string]$Command,
    [ValidateSet('list', 'doctor', 'build-map', 'import-assets')][string]$EnvironmentCommand = 'list',
    [string]$Environment = 'blocks',
    [ValidateSet('qualification', 'visual')][string]$RenderProfile = 'qualification',
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
    [switch]$WithMissionPlanner,
    [ValidateSet('installed', 'source')][string]$IvinsRuntime = 'installed',
    [ValidateSet('doctor', 'status', 'enroll', 'sync', 'update-check', 'update-status', 'update-install')][string]$IvinsCommand = 'status',
    [string]$IvinsEnrollmentKeyFile = '',
    [string]$IvinsVersion = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
New-Item -ItemType Directory -Force -Path $script:RuntimeRoot, $script:LogsRoot | Out-Null

function Test-PortFree([int]$Port) {
    # Closed RPC connections legitimately remain in TIME_WAIT between
    # back-to-back acceptance runs. Only a listener conflicts with our bind.
    $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    return -not ($tcp -or $udp)
}

function Invoke-IvinsWsl([string]$WslCommand, [string]$Operation) {
    $result = Invoke-Wsl -Command $WslCommand -AllowFailure
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.ExitCode -ne 0) {
        throw "IVINS $Operation failed with exit code $($result.ExitCode)."
    }
}

function Assert-IvinsInstalledRuntime {
    $command = @'
set -e
test "$(dpkg --print-architecture)" = amd64
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(cat /etc/ivins/newsim-platform)" = newsim-cosys
grep -Eq '^[A-Za-z0-9._-]{8,128}$' /etc/ivins/newsim-instance-id
test "$(stat -c '%U:%G:%a' /etc/ivins/newsim-platform)" = root:root:444
test "$(stat -c '%U:%G:%a' /etc/ivins/newsim-instance-id)" = root:root:444
test -x /usr/sbin/ivins-installer
test -x /usr/share/ivins/newsim-preflight.sh
test -r /usr/share/doc/ivins/release-manifest.json
python3 - /usr/share/doc/ivins/release-manifest.json <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["schema_version"] == 4
assert manifest["release"]["version"] == "3.1.0.0"
assert manifest["release"]["debian_version"] == "3.1.0.0-1+noble"
assert manifest["platform"] == {
    "distribution": "ubuntu",
    "release": "24.04",
    "codename": "noble",
    "architecture": "amd64",
    "native_machine": "x86_64",
    "device": "NewSIM Cosys",
    "ros_distribution": "jazzy",
    "role": "DEV-only",
}
assert manifest["supported_platforms"] == ["ubuntu24-amd64-newsim"]
assert manifest["compatibility"]["environment"]["production_authorized"] is False
PY
/usr/share/ivins/newsim-preflight.sh
test -r /opt/iros2j/setup.bash
test -r /opt/imavros/setup.bash
test -r /opt/vins/setup.bash
test -r /opt/vio_stack/current/local_setup.bash
dpkg-query -W -f='${Package}=${Version} ${Architecture} ${db:Status-Status}\n' \
  ivins ivins-installer-agent iros2j-ros-core imavros vins-mono-ros2 vio-stack
'@
    Invoke-IvinsWsl $command 'installed-runtime check'
}

function Invoke-IvinsManagement {
    switch ($IvinsCommand) {
        'doctor' {
            Assert-IvinsInstalledRuntime
            Invoke-IvinsWsl '/usr/sbin/ivins-installer --version' 'version check'
            Write-Pass 'IVINS DEV runtime' 'official Noble AMD64 packages are installed'
        }
        'status' {
            Invoke-IvinsWsl 'sudo -n /usr/sbin/ivins-installer status' 'status'
        }
        'enroll' {
            if ($IvinsEnrollmentKeyFile -notmatch '^/[A-Za-z0-9._/-]+$') {
                throw 'Provide -IvinsEnrollmentKeyFile as an absolute WSL path containing only letters, digits, dot, underscore, slash or hyphen.'
            }
            $keyPath = $IvinsEnrollmentKeyFile
            $command = "sudo -n test -f '$keyPath' && sudo -n /usr/sbin/ivins-installer enroll --server https://ivins.drone-age.org --key-file '$keyPath'"
            Invoke-IvinsWsl $command 'official DEV enrollment'
        }
        'sync' {
            Invoke-IvinsWsl 'sudo -n systemctl start ivins-update-agent.service && sudo -n /usr/sbin/ivins-installer status' 'automatic stage synchronization'
        }
        'update-check' {
            Invoke-IvinsWsl 'sudo -n /usr/bin/ibootctl update check' 'update check'
        }
        'update-status' {
            Invoke-IvinsWsl 'sudo -n /usr/bin/ibootctl update status' 'update status'
        }
        'update-install' {
            if ($IvinsVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
                throw 'Provide the exact four-component product version with -IvinsVersion.'
            }
            Invoke-IvinsWsl "sudo -n /usr/bin/ibootctl update install '$IvinsVersion'" 'locally approved update installation'
        }
    }
}

function Set-LfLineEnding([string[]]$Paths) {
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required WSL entrypoint is missing: $path"
        }
        $text = [IO.File]::ReadAllText($path)
        if ($text.Contains("`r")) {
            [IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n").Replace("`r", "`n"), $utf8NoBom)
        }
    }
}

function Invoke-EnvironmentList {
    $rows = foreach ($entry in $script:EnvironmentLock.environments.psobject.Properties) {
        $environmentId = $entry.Name
        $manifestPath = Join-Path (Join-Path $script:EnvironmentsRoot $environmentId) 'environment.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            [pscustomobject]@{ Id = $environmentId; Version = '-'; Readiness = 'NOT_INITIALIZED'; Offline = '-'; Global = '-'; Map = "run setup -Environment $environmentId" }
            continue
        }
        try {
            $manifest = Get-EnvironmentManifest -EnvironmentId $environmentId -AllowScaffold
            [pscustomobject]@{
                Id = $manifest.id
                Version = $manifest.version
                Readiness = $manifest.readiness
                Offline = [bool]$manifest.capabilities.offline
                Global = [bool]$manifest.capabilities.global_streaming
                Map = $manifest.map_path
            }
        } catch {
            [pscustomobject]@{ Id = $environmentId; Version = '-'; Readiness = 'INVALID'; Offline = $false; Global = $false; Map = $_.Exception.Message }
        }
    }
    if (-not $rows) { throw "No environment manifests were found under $script:EnvironmentsRoot." }
    $rows | Sort-Object Id | Format-Table -AutoSize
}

function Invoke-EnvironmentDoctor([string]$EnvironmentId) {
    Write-Step "Checking environment '$EnvironmentId'"
    try {
        $manifest = Get-RuntimeEnvironmentManifest -EnvironmentId $EnvironmentId -Preview:$Preview
        if ($manifest.readiness -eq 'preview') {
            Write-Warn 'Readiness' 'preview explicitly authorized; doctor validates package integrity, not promotion gates'
        }
        Write-Pass 'Manifest' "schema $($manifest.schema), version $($manifest.version)"
        Write-Pass 'Unreal compatibility' ($manifest.compatibility.unreal_engine -join ', ')
        Write-Pass 'Map' $manifest.map_path
        if ($manifest.content_plugin.path) {
            Write-Pass 'Content plugin' (Join-Path $script:EnvironmentsRoot "$EnvironmentId\$($manifest.content_plugin.path)")
        } else {
            Write-Pass 'Content plugin' 'built into parent project'
        }
        Write-Pass 'Qualification' $(if ($manifest.profiles.qualification) { 'available' } else { 'not declared' })
        return 0
    } catch {
        Write-Fail 'Environment' $_.Exception.Message
        return 1
    }
}

function Invoke-EnvironmentBuildMap([string]$EnvironmentId) {
    if ($EnvironmentId -notin @('sim2-rural', 'cesium-global')) { throw "Automated map generation is not implemented for environment '$EnvironmentId'." }
    $manifest = Get-EnvironmentManifest -EnvironmentId $EnvironmentId -AllowScaffold
    $ue = Get-UeRoot
    $vs = Get-VsInstallPath
    $msvc = Get-MsvcVersion $vs
    $compilerVersion = Get-MsvcCompilerVersion $vs $msvc
    if (-not $ue -or -not $vs -or -not (Test-MsvcVersion $compilerVersion)) { throw 'UE 5.8.1, Visual Studio 17.14 and MSVC 14.44.35211 or newer are required. Run doctor.' }
    $sdkRoot = Get-WindowsSdkRoot
    if (-not $sdkRoot -or -not (Test-Path -LiteralPath (Join-Path $sdkRoot 'Lib\10.0.22621.0\um\x64\kernel32.lib'))) { throw 'Windows SDK 10.0.22621.0 is missing. Run doctor.' }

    Write-Step "Staging the $EnvironmentId editor plugin"
    Stage-EnvironmentPlugin -Manifest $manifest

    if ($EnvironmentId -eq 'cesium-global') {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo'))
        $project = Join-Path $projectRoot 'IndraCosysDemo.uproject'
        $buildBat = Join-Path $ue 'Engine\Build\BatchFiles\Build.bat'
        $pluginName = [IO.Path]::GetFileNameWithoutExtension([string]$manifest.content_plugin.descriptor)
        Write-Step 'Building the Cesium Global map commandlet against the pinned UE 5.8 plugin'
        & $buildBat IndraCosysDemoEditor Win64 Development "-Project=$project" -WaitMutex -FromMsBuild -NoUBA -DisableAdaptiveUnity -MaxParallelActions=2 "-EnablePlugins=$pluginName" "-CompilerVersion=$compilerVersion" "-VCToolchainVersion=$compilerVersion" '-WindowsSdkVersion=10.0.22621.0'
        if ($LASTEXITCODE -ne 0) { throw 'Cesium Global editor commandlet build failed.' }

        $editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
        $buildLog = Join-Path $script:RuntimeRoot 'cesium-global-build-map.log'
        & $editor $project '-run=CesiumGlobalBuildMap' -unattended -nop4 -nosplash -NoSound -NullRHI "-abslog=$buildLog"
        if ($LASTEXITCODE -ne 0) { throw "Cesium Global map generation failed; see $buildLog" }

        $stagedContent = Join-Path $projectRoot 'Plugins\Environments\IndraCesiumGlobal\Content'
        $sourcePlugin = [IO.Path]::GetFullPath((Join-Path $script:EnvironmentsRoot 'cesium-global\Plugins\IndraCesiumGlobal'))
        $sourceContent = Join-Path $sourcePlugin 'Content'
        New-Item -ItemType Directory -Force -Path $sourceContent | Out-Null
        & robocopy.exe $stagedContent $sourceContent /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Generated Cesium Global content sync failed with robocopy code $LASTEXITCODE." }

        Stage-EnvironmentPlugin -Manifest $manifest
        $verifyLog = Join-Path $script:RuntimeRoot 'cesium-global-verify-map.log'
        & $editor $project '-run=CesiumGlobalBuildMap' -VerifyOnly -unattended -nop4 -nosplash -NoSound -NullRHI "-abslog=$verifyLog"
        if ($LASTEXITCODE -ne 0) { throw "Cesium Global map verification failed; see $verifyLog" }
        Write-Pass 'Cesium Global map' 'georeference, streamed terrain/buildings and token-free fallback verified'
        return
    }
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo'))
    $stagedPlugin = [IO.Path]::GetFullPath((Join-Path $projectRoot 'Plugins\Environments\Sim2Rural'))
    if (-not $stagedPlugin.StartsWith($projectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $stagedPlugin) -ne 'Sim2Rural') { throw "Unsafe staged plugin path: $stagedPlugin" }
    $stagedContent = Join-Path $stagedPlugin 'Content'
    $packagedMap = Join-Path $stagedContent 'Maps\SIM2_Rural_WP.umap'
    if (-not (Test-Path -LiteralPath $packagedMap)) {
        throw 'The packaged SIM2 Rural map is missing. Initialise the environment submodule and Git LFS; deployment does not regenerate the 4033x4033 Landscape.'
    }

    Write-Step 'Building the deterministic Sim2Rural editor commandlet'
    $project = Join-Path $projectRoot 'IndraCosysDemo.uproject'
    $buildBat = Join-Path $ue 'Engine\Build\BatchFiles\Build.bat'
    $environmentPluginName = [IO.Path]::GetFileNameWithoutExtension([string]$manifest.content_plugin.descriptor)
    # The parent-owned AirSim plugin is a writable mirror. Without this flag UBT
    # treats every mirrored source as an adaptive working-set file and expands a
    # small map-editor change into dozens of multi-gigabyte non-unity actions.
    & $buildBat IndraCosysDemoEditor Win64 Development "-Project=$project" -WaitMutex -FromMsBuild -NoUBA -DisableAdaptiveUnity -MaxParallelActions=2 "-EnablePlugins=$environmentPluginName" "-CompilerVersion=$compilerVersion" "-VCToolchainVersion=$compilerVersion" '-WindowsSdkVersion=10.0.22621.0'
    if ($LASTEXITCODE -ne 0) { throw 'Sim2Rural editor commandlet build failed.' }

    $editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
    # Deployment consumes the immutable, LFS-pinned map package. Re-importing
    # the 4033² Landscape on every workstation is unnecessary and exposes an
    # intermittent UE 5.8.1 Renderer/Landscape race. This metadata-only phase
    # makes the complete physics core always-loaded without rebuilding assets.
    $patchLog = Join-Path $script:RuntimeRoot 'sim2-rural-patch-physics.log'
    Write-Step 'Applying the full-extent always-loaded collision contract to the packaged map'
    & $editor $project '-run=Sim2RuralBuildMap' -PatchPhysicsCoverage -unattended -nop4 -nosplash -NoSound "-abslog=$patchLog"
    if ($LASTEXITCODE -ne 0) { throw "Sim2Rural physics metadata patch failed; see $patchLog" }

    $visualPatchLog = Join-Path $script:RuntimeRoot 'sim2-rural-patch-visual-assets.log'
    $landcoverMask = Join-Path $script:EnvironmentsRoot 'sim2-rural\data\derived\gis\worldcover-2021\landcover\SIM2_Rural_Cropland_Mask_4096.png'
    if (-not (Test-Path -LiteralPath $landcoverMask)) { throw "Pinned ESA WorldCover cropland mask is missing: $landcoverMask" }
    Write-Step 'Applying provenance-tracked rural assets and the ESA WorldCover field layer'
    & $editor $project '-run=Sim2RuralBuildMap' -PatchVisualAssets "-Landcover=$landcoverMask" -unattended -nop4 -nosplash -NoSound "-abslog=$visualPatchLog"
    if ($LASTEXITCODE -ne 0) { throw "Sim2Rural visual asset patch failed; see $visualPatchLog" }

    $sourcePlugin = [IO.Path]::GetFullPath((Join-Path $script:EnvironmentsRoot 'sim2-rural\Plugins\Sim2Rural'))
    $sourceContent = [IO.Path]::GetFullPath((Join-Path $sourcePlugin 'Content'))
    if (-not $sourceContent.StartsWith($sourcePlugin.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $sourceContent) -ne 'Content') { throw "Unsafe source content path: $sourceContent" }
    New-Item -ItemType Directory -Force -Path $sourceContent | Out-Null
    & robocopy.exe $stagedContent $sourceContent /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Generated Sim2Rural content sync failed with robocopy code $LASTEXITCODE." }

    $verifyLog = Join-Path $script:RuntimeRoot 'sim2-rural-verify-map.log'
    Write-Step 'Reloading the saved map and verifying World Partition, imagery, collision and OSM actors'
    & $editor $project '-run=Sim2RuralBuildMap' -VerifyOnly -unattended -nop4 -nosplash -NoSound "-abslog=$verifyLog"
    if ($LASTEXITCODE -ne 0) { throw "Sim2Rural map verification failed; see $verifyLog" }
    Write-Pass 'SIM2 Rural map' 'World Partition, terrain collision, EPSG:32636, Sentinel-2, ESA WorldCover fields and provenance-tracked OSM vegetation'
}

function Get-BackendCapabilities {
    $manifest = Get-EnvironmentManifest -EnvironmentId $Environment -AllowScaffold
    $sensorProfile = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ros2\sensor-profile.json') -Raw | ConvertFrom-Json
    return [ordered]@{
        schema = 1
        backend = 'cosys-airsim'
        backend_version = $script:Lock.submodules.'third_party/Cosys-AirSim'.release
        environment = [ordered]@{
            id = $manifest.id
            version = $manifest.version
            readiness = $manifest.readiness
            wgs84_origin = $manifest.wgs84_origin
        }
        interfaces = [ordered]@{
            launcher = 'dev.ps1'
            evidence_schema = 1
            mission_planner_default_for_test = $false
            ros2 = $true
            vins = $false
            wind_command_ack = $false
            camera_fixed_rate_hz = $true
            camera_imu_batched = $true
        }
        camera = [ordered]@{
            mode = 'fixed-rate-async-gpu-readback'
            producer_hz = [double]$sensorProfile.camera.producer_hz
            ros_published_hz = [double]$sensorProfile.camera.published_hz
            qualified_resolutions = @(
                [ordered]@{ width = 640; height = 480; minimum_fps = 20.0 }
                [ordered]@{ width = 1280; height = 720; minimum_fps = 10.0 }
            )
            rejects_duplicate_timestamps = $true
            rejects_uniform_frames = $true
        }
        imu = [ordered]@{
            mode = 'timestamp-preserving-batched-rpc'
            nominal_hz = [double]$sensorProfile.camera_imu.nominal_hz
            wall_budget_hz = [double]$sensorProfile.camera_imu.wall_budget_hz
            batch_poll_hz = [double]$sensorProfile.camera_imu.batch_poll_hz
            accepted_rate_hz = [ordered]@{ minimum = 190.0; maximum = 210.0 }
            camera_nearest_imu_p95_max_ms = 5.0
            rejects_history_overflow = $true
        }
        commands = [ordered]@{
            run = @('-Environment', '-RenderProfile', '-Headless', '-NoMissionPlanner', '-WithRos2', '-Preview')
            test = @('-Environment', '-RenderProfile', '-WithRos2', '-Preview')
            ros_test = @('-Environment', '-RenderProfile', '-Preview')
            qualification_accepted_args = @('-RunId', '-FlightLogDirectory', '-Rosbag', '-FlightQualification', '-FlightQualificationLimitM', '-FlightQualificationProfile', '-FlightQualificationNoWind', '-FlightQualificationNoVisualUi', '-RouteQualification', '-RouteQualificationProfile', '-VinsConfigFile', '-Distro', '-WithRos2', '-WithMissionPlanner', '-IvinsRuntime')
            ivins = @('-IvinsCommand', '-IvinsEnrollmentKeyFile', '-IvinsVersion')
        }
    }
}

function Write-Capabilities {
    $capabilities = Get-BackendCapabilities
    $serialized = $capabilities | ConvertTo-Json -Depth 10
    if ($Json) { Write-Output $serialized } else { $capabilities | Format-List }
}

function Assert-QualificationCapabilities {
    if (-not $FlightQualification -and -not $RouteQualification) { return }
    if ($FlightQualification -and $RouteQualification) { throw 'FlightQualification and RouteQualification are mutually exclusive.' }
    $required = @('ros2', 'vins', 'camera_fixed_rate_hz', 'camera_imu_batched', 'wind_command_ack')
    if ($FlightQualificationNoWind) { $required = @($required | Where-Object { $_ -ne 'wind_command_ack' }) }
    $interfaces = (Get-BackendCapabilities).interfaces
    $missing = @($required | Where-Object {
        -not $interfaces.Contains($_) -or -not [bool]$interfaces[$_]
    })
    if ($missing.Count -eq 0) { return }
    $kind = if ($FlightQualification) { 'VINS climb' } else { 'VINS route' }
    throw "$kind qualification is registered but not enabled on the current Cosys backend. Missing capabilities: $($missing -join ', '). Query '.\dev.ps1 capabilities -Environment $Environment -Json'. No simulator process was started."
}

function Invoke-Doctor {
    Write-Step 'Checking the v0.1 workstation contract'
    $failures = 0
    $ue = Get-UeRoot
    if ($ue) {
        $build = Get-Content -Raw -LiteralPath (Join-Path $ue 'Engine\Build\Build.version') | ConvertFrom-Json
        $actual = "$($build.MajorVersion).$($build.MinorVersion).$($build.PatchVersion)"
        if ($actual -eq $script:Lock.platform.unreal_engine) { Write-Pass 'Unreal Engine' "$actual at $ue" } else { Write-Fail 'Unreal Engine' "expected $($script:Lock.platform.unreal_engine), found $actual"; $failures++ }
    } else { Write-Fail 'Unreal Engine' 'UE 5.8 is not installed or INDRA_UE_ROOT is invalid'; $failures++ }

    $vs = Get-VsInstallPath
    if ($vs) { Write-Pass 'Visual Studio' $vs } else { Write-Fail 'Visual Studio' 'C++ workload not found'; $failures++ }
    $msvc = Get-MsvcVersion $vs
    $compilerVersion = Get-MsvcCompilerVersion $vs $msvc
    if (Test-MsvcVersion $compilerVersion) {
        Write-Pass 'MSVC toolset' "$compilerVersion (layout $msvc)"
    } else {
        $found = if ($compilerVersion) { "found banned/obsolete $compilerVersion" } else { 'not found' }
        Write-Fail 'MSVC toolset' "$found; 14.44.35211 or newer is required"
        $failures++
    }
    $sdkRoot = Get-WindowsSdkRoot
    $sdk = if ($sdkRoot) { Join-Path $sdkRoot 'Lib\10.0.22621.0\um\x64\kernel32.lib' } else { '' }
    if (Test-Path -LiteralPath $sdk) { Write-Pass 'Windows SDK' '10.0.22621.0' } else { Write-Fail 'Windows SDK' '10.0.22621.0 is not installed'; $failures++ }

    $cmake = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmake) { Write-Pass 'CMake' ((& cmake.exe --version | Select-Object -First 1)) } else { Write-Fail 'CMake' 'cmake.exe is not on PATH'; $failures++ }
    $wsl = Invoke-Wsl -Command 'lsb_release -ds' -AllowFailure
    if ($wsl.ExitCode -eq 0 -and (($wsl.Output -join ' ') -match 'Ubuntu 24\.04')) { Write-Pass 'WSL2 Ubuntu' ($wsl.Output -join ' ') } else { Write-Fail 'WSL2 Ubuntu' ($wsl.Output -join ' '); $failures++ }
    $ros = Invoke-Wsl -Command "if [ -f /opt/ros/jazzy/setup.bash ]; then source /opt/ros/jazzy/setup.bash; elif [ -f /opt/iros2j/setup.bash ]; then source /opt/iros2j/setup.bash; else exit 66; fi; test -x ~/venv-ardupilot/bin/python3 && ~/venv-ardupilot/bin/python3 -c 'import msgpackrpc, rclpy; from sensor_msgs.msg import Image, Imu; from nav_msgs.msg import Odometry; from rosgraph_msgs.msg import Clock'" -AllowFailure
    if ($ros.ExitCode -eq 0) { Write-Pass 'ROS 2 Jazzy' 'ArduPilot venv sees RPC and SIM2 ROS message contracts' } else { Write-Fail 'ROS 2 Jazzy' 'combined ArduPilot venv + /opt/iros2j or /opt/ros/jazzy environment is required'; $failures++ }

    $gpu = Get-CimInstance Win32_VideoController | Where-Object Name -Match 'NVIDIA' | Select-Object -First 1
    if ($gpu) {
        $gpuDetail = $gpu.Name
        $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if ($nvidiaSmi) {
            $memory = (& nvidia-smi.exe --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1).Trim()
            if ($memory -match '^\d+$') { $gpuDetail += ", $([math]::Round([int]$memory / 1024, 1)) GiB" }
        }
        Write-Pass 'GPU' $gpuDetail
    } else { Write-Warn 'GPU' 'NVIDIA adapter was not detected' }

    foreach ($entry in $script:Lock.submodules.psobject.Properties) {
        $path = Join-Path $script:RepoRoot $entry.Name
        $actual = (& git -C $path rev-parse HEAD 2>$null).Trim()
        if ($actual -eq $entry.Value.commit) { Write-Pass $entry.Name $actual.Substring(0, 12) } else { Write-Fail $entry.Name "expected $($entry.Value.commit), found $actual"; $failures++ }
        if ($entry.Value.PSObject.Properties.Name -contains 'nested_submodules') {
            foreach ($nested in $entry.Value.nested_submodules.PSObject.Properties) {
                $nestedPath = Join-Path $path $nested.Name
                $nestedActual = (& git -C $nestedPath rev-parse HEAD 2>$null).Trim()
                $label = "$($entry.Name)/$($nested.Name)"
                if ($nestedActual -eq $nested.Value) { Write-Pass $label $nestedActual.Substring(0, 12) } else { Write-Fail $label "expected $($nested.Value), found $nestedActual"; $failures++ }
            }
        }
    }

    foreach ($port in @($script:Config.ports.cosys_control_udp, $script:Config.ports.sitl_sensor_udp, $script:Config.ports.mavlink_tcp, $script:Config.ports.mission_planner_tcp, $script:Config.ports.cosys_rpc_tcp)) {
        if (Test-PortFree $port) { Write-Pass "Port $port" 'available' } else { Write-Fail "Port $port" 'already in use'; $failures++ }
    }

    $mp = Join-Path $script:RuntimeRoot "tools\mission-planner-$($script:Lock.mission_planner.version)\MissionPlanner.exe"
    if (Test-Path -LiteralPath $mp) { Write-Pass 'Mission Planner' $script:Lock.mission_planner.version } else { Write-Warn 'Mission Planner' 'not staged yet; setup will download it' }
    if ($failures) { Write-Host "`nDoctor found $failures blocking issue(s)." -ForegroundColor Red; return 1 }
    Write-Host "`nDoctor PASS: the workstation is ready for setup/build." -ForegroundColor Green
    return 0
}

function Invoke-Setup {
    Write-Step "Preparing isolated WSL distribution '$($script:Lock.platform.wsl_distribution)'"
    & (Join-Path $PSScriptRoot 'setup-wsl-distro.ps1') -RepoRoot $script:RepoRoot -DistroName $script:Lock.platform.wsl_distribution
    if ($LASTEXITCODE -ne 0) { throw 'Isolated Ubuntu 24.04 WSL setup failed.' }

    Write-Step 'Provisioning stable NewSIM IVINS identity'
    $ivinsIdentitySetup = Convert-ToWslPath (Join-Path $PSScriptRoot 'wsl\setup_ivins_newsim_identity.sh')
    & wsl.exe -d $script:Lock.platform.wsl_distribution -u root -- bash $ivinsIdentitySetup
    if ($LASTEXITCODE -ne 0) { throw 'Stable NewSIM IVINS identity setup failed.' }
    Write-Pass 'NewSIM IVINS identity' 'root-owned platform and instance markers ready'

    Write-Step 'Initialising pinned submodules'
    $componentPaths = @($script:Lock.submodules.psobject.Properties | ForEach-Object { $_.Name })
    & git submodule update --init -- $componentPaths
    if ($LASTEXITCODE -ne 0) { throw 'Submodule initialisation failed.' }
    foreach ($entry in $script:Lock.submodules.psobject.Properties) {
        $componentPath = Join-Path $script:RepoRoot $entry.Name
        if ($entry.Name -eq 'third_party/ardupilot') {
            & git -C $componentPath config core.autocrlf false
            if ($LASTEXITCODE -ne 0) { throw 'Unable to enforce LF checkout for ArduPilot.' }
        }
        & git -C $componentPath checkout --detach $entry.Value.commit
        if ($LASTEXITCODE -ne 0) { throw "Unable to check out pinned commit for $($entry.Name)." }
        if ($entry.Name -eq 'third_party/ardupilot') {
            # Re-materialise the pinned tree after disabling autocrlf. This preserves the
            # upstream repository's intentional mix of LF and CRLF while keeping WSL entrypoints LF.
            & git -C $componentPath checkout-index --force --all
            if ($LASTEXITCODE -ne 0) { throw 'Unable to materialise the pinned ArduPilot tree.' }
            & git -C $componentPath add -u
            & git -C $componentPath diff --cached --quiet
            if ($LASTEXITCODE -ne 0) { throw 'ArduPilot checkout differs from its pinned commit.' }
        }
        & git -C $componentPath submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "Recursive submodule initialisation failed for $($entry.Name)." }
        if ($entry.Name -eq 'third_party/vio_stack') {
            $ihubPath = Join-Path $componentPath 'src\actuators\iHUB'
            & git -C $ihubPath config core.autocrlf false
            if ($LASTEXITCODE -ne 0) { throw 'Unable to enforce LF checkout for iHUB.' }
            Set-LfLineEnding -Paths @(
                (Join-Path $ihubPath 'scripts\ihub-client'),
                (Join-Path $ihubPath 'scripts\ihub-server-sim'),
                (Join-Path $ihubPath 'scripts\ihub-uart-sim')
            )
            # The blobs are already LF in Git. Refreshing the index records the
            # mechanically corrected NTFS worktree without creating a source diff.
            & git -C $ihubPath add scripts/ihub-client scripts/ihub-server-sim scripts/ihub-uart-sim
            & git -C $ihubPath diff --cached --quiet
            if ($LASTEXITCODE -ne 0) { throw 'iHUB entrypoint normalisation changed pinned source content.' }
        }
        $actual = (& git -C $componentPath rev-parse HEAD).Trim()
        if ($actual -ne $entry.Value.commit) { throw "$($entry.Name) is not at its pinned commit." }
        if ($entry.Value.PSObject.Properties.Name -contains 'nested_submodules') {
            foreach ($nested in $entry.Value.nested_submodules.PSObject.Properties) {
                $nestedPath = Join-Path $componentPath $nested.Name
                $nestedActual = (& git -C $nestedPath rev-parse HEAD 2>$null).Trim()
                if ($nestedActual -ne $nested.Value) {
                    throw "$($entry.Name)/$($nested.Name) is not at its pinned commit."
                }
            }
        }
    }

    Initialize-EnvironmentPackage -EnvironmentId $Environment
    Get-EnvironmentManifest -EnvironmentId $Environment -AllowScaffold | Out-Null

    & (Join-Path $PSScriptRoot 'mission-planner.ps1') -Action Setup
    if ($LASTEXITCODE -ne 0) { throw 'Mission Planner setup failed.' }

    Write-Step 'Preparing the ArduPilot Ubuntu 24.04 toolchain and Python venv'
    $ardupilot = Convert-ToWslPath (Join-Path $script:RepoRoot 'third_party\ardupilot')
    $setupLog = Convert-ToWslPath (Join-Path $script:RuntimeRoot 'ardupilot-prerequisites.log')
    $ready = Invoke-Wsl -Command "test -x ~/venv-ardupilot/bin/python && command -v g++ >/dev/null && command -v make >/dev/null && command -v ccache >/dev/null && ~/venv-ardupilot/bin/python -c 'import pymavlink, pexpect, lxml, numpy'" -AllowFailure
    if ($ready.ExitCode -ne 0) {
        & wsl.exe -d $script:Lock.platform.wsl_distribution -- bash -lc "cd '$ardupilot' && export DO_PYTHON_VENV_ENV=0 DO_AP_STM_ENV=0 SKIP_AP_GRAPHIC_ENV=1 && Tools/environment_install/install-prereqs-ubuntu.sh -y 2>&1 | tee '$setupLog'"
        if ($LASTEXITCODE -ne 0) { throw "ArduPilot prerequisite setup failed; see .runtime\ardupilot-prerequisites.log" }
    }
    $rpcReady = Invoke-Wsl -Command "~/venv-ardupilot/bin/python -c 'import msgpackrpc'" -AllowFailure
    if ($rpcReady.ExitCode -ne 0) {
        Write-Step 'Installing the Cosys RPC client into the ArduPilot Python environment'
        Invoke-Wsl -Command "~/venv-ardupilot/bin/pip install rpc-msgpack" | Out-Null
    }
    Write-Pass 'Cosys Python client' 'rpc-msgpack available for camera qualification'
    Write-Pass 'ArduPilot prerequisites' 'Ubuntu toolchain and ~/venv-ardupilot ready'

    $rosReady = Invoke-Wsl -Command "if [ -f /opt/ros/jazzy/setup.bash ]; then source /opt/ros/jazzy/setup.bash; elif [ -f /opt/iros2j/setup.bash ]; then source /opt/iros2j/setup.bash; else exit 66; fi; ~/venv-ardupilot/bin/python3 -c 'import msgpackrpc, rclpy; from sensor_msgs.msg import Image, Imu; from nav_msgs.msg import Odometry; from rosgraph_msgs.msg import Clock'" -AllowFailure
    if ($rosReady.ExitCode -ne 0) {
        $rosSetup = Convert-ToWslPath (Join-Path $PSScriptRoot 'wsl\setup_ros2_jazzy.sh')
        & wsl.exe -d $script:Lock.platform.wsl_distribution -u root -- bash $rosSetup
        if ($LASTEXITCODE -ne 0) { throw 'ROS 2 Jazzy setup failed.' }
    }
    Write-Pass 'ROS 2 Jazzy' 'SIM2-compatible bridge runtime available'

    Write-Step 'Preparing pinned VINS/iMAVROS/vio_stack overlay dependencies'
    $repoWsl = Convert-ToWslPath $script:RepoRoot
    $vinsSetup = Convert-ToWslPath (Join-Path $PSScriptRoot 'wsl\setup_vins_overlay.sh')
    & wsl.exe -d $script:Lock.platform.wsl_distribution -u root -- bash $vinsSetup $repoWsl
    if ($LASTEXITCODE -ne 0) { throw 'VINS overlay prerequisite setup failed.' }
    Write-Pass 'VINS overlay prerequisites' 'colcon, rosdep and native libraries ready'

    $ue = Get-UeRoot
    if ($ue) {
        try {
            & (Join-Path $PSScriptRoot 'configure-firewall.ps1') -UnrealEditor (Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor.exe') -ControlPort $script:Config.ports.cosys_control_udp -SensorPort $script:Config.ports.sitl_sensor_udp
            Write-Pass 'Host/WSL firewalls' 'Unreal UDP 9022 and WSL SITL UDP 9023 only'
        } catch { Write-Warn 'Host/WSL firewalls' 'run setup once from an elevated PowerShell to add the two narrow UDP rules' }
    }
}

function Invoke-Build {
    $environmentManifest = Get-RuntimeEnvironmentManifest -EnvironmentId $Environment -Preview:$Preview
    $ue = Get-UeRoot
    $vs = Get-VsInstallPath
    $msvc = Get-MsvcVersion $vs
    $compilerVersion = Get-MsvcCompilerVersion $vs $msvc
    if (-not $ue -or -not $vs -or -not (Test-MsvcVersion $compilerVersion)) { throw 'UE 5.8.1, Visual Studio 17.14 and MSVC 14.44.35211 or newer are required. Run doctor.' }
    $sdkRoot = Get-WindowsSdkRoot
    $sdk = if ($sdkRoot) { Join-Path $sdkRoot 'Lib\10.0.22621.0\um\x64\kernel32.lib' } else { '' }
    if (-not (Test-Path -LiteralPath $sdk)) { throw 'Windows SDK 10.0.22621.0 is missing. Run doctor.' }

    Write-Step "Building Cosys-AirSim 3.4.1 with MSVC $compilerVersion (layout $msvc)"
    $vsDevCmd = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
    $cosys = Join-Path $script:RepoRoot 'third_party\Cosys-AirSim'
    $buildCmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 -winsdk=10.0.22621.0 && set AIRSIM_VCTOOLSVERSION=$msvc && call `"$cosys\build.cmd`" --no-full-poly-car --Release"
    & cmd.exe /d /s /c $buildCmd
    if ($LASTEXITCODE -ne 0) { throw 'Cosys-AirSim build failed.' }

    Write-Step 'Staging the generated AirSim plugin into the parent-owned UE project'
    $sourcePlugin = Join-Path $cosys 'Unreal\Plugins\AirSim'
    $targetPlugin = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins\AirSim'
    New-Item -ItemType Directory -Force -Path $targetPlugin | Out-Null
    & robocopy.exe $sourcePlugin $targetPlugin /MIR /XD Binaries Intermediate /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Plugin staging failed with robocopy code $LASTEXITCODE." }

    Stage-EnvironmentPlugin -Manifest $environmentManifest

    Write-Step 'Building the IndraCosysDemo Development Editor target'
    $project = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\IndraCosysDemo.uproject'
    $buildBat = Join-Path $ue 'Engine\Build\BatchFiles\Build.bat'
    # The generated plugin is mirrored into the project as writable files. UBT
    # otherwise treats the entire AirSim source tree as an adaptive working set,
    # creates dozens of multi-gigabyte non-unity compiler actions and thrashes a
    # 32 GB workstation. The canonical source is the Cosys submodule, so a normal
    # unity build is both safe and dramatically more reproducible here.
    $environmentBuildArguments = @()
    if ($environmentManifest.content_plugin.descriptor) {
        $environmentPluginName = [IO.Path]::GetFileNameWithoutExtension([string]$environmentManifest.content_plugin.descriptor)
        $environmentBuildArguments += "-EnablePlugins=$environmentPluginName"
    }
    & $buildBat IndraCosysDemoEditor Win64 Development "-Project=$project" -WaitMutex -FromMsBuild -NoUBA -DisableAdaptiveUnity -MaxParallelActions=2 @environmentBuildArguments "-CompilerVersion=$compilerVersion" "-VCToolchainVersion=$compilerVersion" '-WindowsSdkVersion=10.0.22621.0'
    if ($LASTEXITCODE -ne 0) { throw 'Unreal Development Editor build failed.' }

    Write-Step 'Building ArduCopter SITL in Ubuntu 24.04'
    $ardupilot = Convert-ToWslPath (Join-Path $script:RepoRoot 'third_party\ardupilot')
    Invoke-Wsl -Command "cd '$ardupilot' && source ~/venv-ardupilot/bin/activate && ./waf configure --board sitl && ./waf copter" | Out-Null

    if ($IvinsRuntime -eq 'installed') {
        Write-Step 'Verifying the official installed IVINS DEV runtime'
        Assert-IvinsInstalledRuntime
        Write-Step 'Building only the NewSIM adapter overlay against installed IVINS packages'
    } else {
        Write-Step 'Building the pinned ROS 2 VINS/iMAVROS/vio_stack source overlay'
    }
    $repoWsl = Convert-ToWslPath $script:RepoRoot
    $vinsBuilder = Convert-ToWslPath (Join-Path $PSScriptRoot 'wsl\build_vins_overlay.sh')
    Invoke-Wsl -Command "bash '$vinsBuilder' '$repoWsl' ~/.local/share/indra-cosys '$IvinsRuntime'" | Out-Null
    Write-Pass 'Build' "Cosys-AirSim, IndraCosysDemoEditor, ArduCopter SITL and IVINS runtime mode '$IvinsRuntime'"
}

function Start-RosBridge([string]$RunDirectory, [object]$Settings) {
    $repoWsl = Convert-ToWslPath $script:RepoRoot
    $runWsl = Convert-ToWslPath $RunDirectory
    $profile = Convert-ToWslPath (Join-Path $script:RepoRoot 'config\ros2\sensor-profile.json')
    $launcher = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\start_ros_bridge.sh')
    $domainId = [int]$script:Config.future_ros_domain_id
    $command = "bash '$launcher' '$repoWsl' '$runWsl' '$($Settings.Network.WindowsIp)' '$($script:Config.ports.cosys_rpc_tcp)' '$profile' '$domainId'"
    $result = Invoke-Wsl -Command $command -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Unable to launch ROS 2 bridge: $($result.Output -join ' ')" }
    # A running process and a status file only prove that ROS initialized.  On a
    # cold Unreal launch the asynchronous camera can still be waiting for its
    # first render-thread readback, so require one accepted sample from every
    # advertised sensor before declaring the graph ready.
    $deadline = (Get-Date).AddSeconds(180)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $reportedBridgeError = $null
        $check = Invoke-Wsl -Command "test -s '$runWsl/ros2/wsl.pid' && kill -0 `$(cat '$runWsl/ros2/wsl.pid') && test -s '$runWsl/ros2/status.json'" -AllowFailure
        if ($check.ExitCode -eq 0) {
            try {
                $status = Get-Content -LiteralPath (Join-Path $RunDirectory 'ros2\status.json') -Raw | ConvertFrom-Json
                if ([string]$status.last_error) { $reportedBridgeError = [string]$status.last_error }
                $topics = $status.topics
                $required = @('/sim/ground_truth/odom', '/sim/body/imu', '/sim/camera/imu', '/sim/camera/image_raw')
                $ready = $true
                foreach ($topic in $required) {
                    $sample = $topics.PSObject.Properties[$topic].Value
                    if ($null -eq $sample -or [int64]$sample.count -lt 1) { $ready = $false; break }
                }
                if ($ready -and -not $reportedBridgeError) { break }
            } catch {
                # The bridge replaces status.json atomically; retry while the
                # first complete sensor snapshot is being written.
                $ready = $false
            }
        }
        if ($reportedBridgeError) { throw "ROS bridge rejected startup sensor data: $reportedBridgeError" }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "ROS 2 bridge did not publish all required sensors within 180 seconds; see $RunDirectory\ros2\bridge.log" }
    Write-Pass 'ROS 2 bridge' "domain $domainId, SIM2-compatible topics published"
}

function Start-VinsStack([string]$RunDirectory, [object]$Settings) {
    $repoWsl = Convert-ToWslPath $script:RepoRoot
    $runWsl = Convert-ToWslPath $RunDirectory
    $launcher = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\start_vins_stack.sh')
    $domainId = [int]$script:Config.future_ros_domain_id
    $command = "bash '$launcher' '$repoWsl' '$runWsl' '$($Settings.Network.WindowsIp)' '$($script:Config.ports.cosys_rpc_tcp)' '$($script:Config.ports.mavlink_tcp)' '$domainId' '900' '$IvinsRuntime'"
    $result = Invoke-Wsl -Command $command -AllowFailure
    if ($result.ExitCode -ne 0) { throw "Unable to launch VINS stack: $($result.Output -join ' ')" }
    $check = Invoke-Wsl -Command "test -s '$runWsl/vins/wsl.pid' && kill -0 `$(cat '$runWsl/vins/wsl.pid')" -AllowFailure
    if ($check.ExitCode -ne 0) { throw "VINS stack exited during startup; see $RunDirectory\vins\stack.log" }
    Write-Pass 'VINS stack' "IVINS runtime mode '$IvinsRuntime' launched in ROS domain $domainId"
}

function Start-Environment([bool]$ForTest, [switch]$NoMissionPlanner, [switch]$StartRos2, [switch]$StartVins) {
    if ($StartVins -and -not $StartRos2) { throw 'VINS requires the Cosys ROS 2 bridge.' }
    if ($Distro -notin @($script:Lock.platform.wsl_distribution, 'Ubuntu')) { throw "This pinned bundle requires WSL distribution '$($script:Lock.platform.wsl_distribution)'; legacy test launchers may pass 'Ubuntu' as an alias." }
    $environmentManifest = Get-RuntimeEnvironmentManifest -EnvironmentId $Environment -Preview:$Preview
    if ($environmentManifest.readiness -eq 'preview') {
        Write-Warn 'Preview environment' 'runtime evidence is diagnostic and cannot promote the environment to ready by itself'
    }
    Stage-EnvironmentPlugin -Manifest $environmentManifest
    if (-not $SkipBuild) {
        $plugin = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins\AirSim\AirSim.uplugin'
        $editorDll = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Binaries\Win64\UnrealEditor-IndraCosysDemo.dll'
        $sitl = Join-Path $script:RepoRoot 'third_party\ardupilot\build\sitl\bin\arducopter'
        $overlayName = if ($IvinsRuntime -eq 'installed') { 'ivins-adapter-overlay-jazzy' } else { 'vins-overlay-jazzy' }
        $vinsOverlayCheck = Invoke-Wsl -Command "test -f ~/.local/share/indra-cosys/$overlayName/install/setup.bash" -AllowFailure
        $vinsBuildMissing = $StartVins -and $vinsOverlayCheck.ExitCode -ne 0
        if (-not (Test-Path -LiteralPath $plugin) -or -not (Test-Path -LiteralPath $editorDll) -or -not (Test-Path -LiteralPath $sitl) -or $vinsBuildMissing) { Invoke-Build }
    }
    if (Get-ActiveRun) { throw 'An environment run is already active. Use .\dev.ps1 stop first.' }
    foreach ($port in @($script:Config.ports.cosys_control_udp, $script:Config.ports.sitl_sensor_udp, $script:Config.ports.mavlink_tcp, $script:Config.ports.mission_planner_tcp, $script:Config.ports.cosys_rpc_tcp)) {
        if (-not (Test-PortFree $port)) { throw "Port $port is in use; SIM2 isolation cannot be guaranteed." }
    }

    $kind = if ($ForTest) { 'test' } else { 'run' }
    $runDirectory = New-RunDirectory -Kind $kind -RequestedRunId $RunId -RequestedDirectory $FlightLogDirectory
    $settings = New-AirSimSettings $runDirectory
    Write-Step "Run bundle: $runDirectory"
    Write-Step "Network: Windows $($settings.Network.WindowsIp), WSL $($settings.Network.WslIp)"

    $ue = Get-UeRoot
    if (-not $ue) { throw 'UE 5.8.1 was not found.' }
    $editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor.exe'
    $project = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\IndraCosysDemo.uproject'
    $ueLog = Join-Path $runDirectory 'unreal\Unreal.log'
    $sensorProfile = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ros2\sensor-profile.json') -Raw | ConvertFrom-Json
    $viewportWidth = if ($RenderProfile -eq 'qualification') { 640 } else { 1280 }
    $viewportHeight = if ($RenderProfile -eq 'qualification') { 360 } else { 720 }
    $arguments = @(
        $project, $environmentManifest.map_path,
        '-game', '-windowed', "-ResX=$viewportWidth", "-ResY=$viewportHeight", '-log',
        "-abslog=$ueLog", "-settings=$($settings.Path)",
        "-IndraRenderProfile=$RenderProfile", "-IndraEnvironment=$($environmentManifest.id)",
        '-IndraAsyncCamera', '-IndraCameraName=0',
        "-IndraCameraHz=$([double]$sensorProfile.camera.producer_hz)",
        "-IndraCameraWidth=$([int]$sensorProfile.camera.width)",
        "-IndraCameraHeight=$([int]$sensorProfile.camera.height)"
    )
    if ($ForTest) { $arguments += @('-Unattended', '-NoSplash') }
    if ($Headless) { $arguments += '-RenderOffscreen' }
    $ueProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $project) -PassThru
    Save-ProcessState $ueProcess 'unreal' $runDirectory
    Start-Sleep -Seconds 3
    if ($ueProcess.HasExited) { throw "UnrealEditor exited during startup with code $($ueProcess.ExitCode)." }
    Write-Pass 'Unreal' "PID $($ueProcess.Id), settings isolated to this run"

    Write-Step 'Waiting for the AirSim UDP control endpoint (first launch may compile shaders)'
    $readyDeadline = (Get-Date).AddMinutes(10)
    $ready = $false
    while ((Get-Date) -lt $readyDeadline) {
        if ($ueProcess.HasExited) { throw "UnrealEditor exited before AirSim became ready with code $($ueProcess.ExitCode)." }
        $endpoint = Get-NetUDPEndpoint -LocalPort $script:Config.ports.cosys_control_udp -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $ueProcess.Id } |
            Select-Object -First 1
        if ($endpoint) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "AirSim did not bind UDP $($script:Config.ports.cosys_control_udp) within 10 minutes; see $ueLog" }
    Write-Pass 'AirSim readiness' "UDP $($script:Config.ports.cosys_control_udp) bound by Unreal PID $($ueProcess.Id)"

    $environmentRuntimeGate = $null
    if ($environmentManifest.id -eq 'sim2-rural') {
        $terrainDeadline = (Get-Date).AddMinutes(2)
        $terrainMatch = $null
        while ((Get-Date) -lt $terrainDeadline) {
            if ($ueProcess.HasExited) { throw "UnrealEditor exited before the SIM2 Rural full-extent terrain gate completed." }
            $terrainLog = Get-Content -LiteralPath $ueLog -Raw -ErrorAction SilentlyContinue
            if ($terrainLog -match 'SIM2_RURAL_FULL_EXTENT_FAIL[^\r\n]*') {
                throw "SIM2 Rural full-extent collision gate failed: $($Matches[0])"
            }
            $terrainMatch = [regex]::Match($terrainLog, 'SIM2_RURAL_FULL_EXTENT_PASS traces=(\d+) landscape_hits=(\d+) failures=0 proxy_centres=(\d+) seam_pairs=(\d+) seam_jumps=0 boundary=(\d+) min_z_cm=([-0-9.]+) max_z_cm=([-0-9.]+)')
            if ($terrainMatch.Success) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $terrainMatch.Success) { throw "SIM2 Rural full-extent collision gate did not complete within 2 minutes; see $ueLog" }
        $environmentRuntimeGate = [ordered]@{
            verdict = 'PASS'
            traces = [int]$terrainMatch.Groups[1].Value
            landscape_hits = [int]$terrainMatch.Groups[2].Value
            proxy_centres = [int]$terrainMatch.Groups[3].Value
            seam_pairs = [int]$terrainMatch.Groups[4].Value
            boundary = [int]$terrainMatch.Groups[5].Value
            minimum_z_cm = [double]::Parse($terrainMatch.Groups[6].Value, [Globalization.CultureInfo]::InvariantCulture)
            maximum_z_cm = [double]::Parse($terrainMatch.Groups[7].Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Pass 'SIM2 Rural terrain' "$($environmentRuntimeGate.landscape_hits)/$($environmentRuntimeGate.traces) full-extent Landscape hits; 256 proxy centres and 480 seam pairs"
    }

    $ardupilot = Convert-ToWslPath (Join-Path $script:RepoRoot 'third_party\ardupilot')
    $runWsl = Convert-ToWslPath $runDirectory
    $location = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:R},{1:R},{2:R},0',
        [double]$script:Config.origin.latitude,
        [double]$script:Config.origin.longitude,
        [double]$script:Config.origin.altitude_m
    )
    $sitlLauncher = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\start_sitl.sh')
    $sitlCommand = "'$sitlLauncher' '$ardupilot' '$runWsl' '$location' '$($script:Config.sitl_instance)' '$($settings.Network.WindowsIp)' '$($script:Config.ports.mission_planner_tcp)'"
    $sitlStart = Invoke-Wsl -Command $sitlCommand -AllowFailure
    if ($sitlStart.ExitCode -ne 0) { throw "Unable to launch ArduCopter SITL: $($sitlStart.Output -join ' ')" }
    $sitlLiveness = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\assert_sitl_alive.sh')
    $pidCheck = Invoke-Wsl -Command "bash '$sitlLiveness' '$runWsl' 15" -AllowFailure
    if ($pidCheck.ExitCode -ne 0) { throw "ArduCopter SITL did not remain stable for 15 seconds; see $runDirectory\sitl\sitl.log" }
    Write-Pass 'ArduCopter SITL' "instance $($script:Config.sitl_instance), AirSim $($settings.Network.WindowsIp), TCP $($script:Config.ports.mavlink_tcp)/$($script:Config.ports.mission_planner_tcp)"

    $mavlinkDeadline = (Get-Date).AddSeconds(60)
    $mavlinkReady = $false
    while ((Get-Date) -lt $mavlinkDeadline) {
        $listen = Invoke-Wsl -Command "ss -H -ltn | grep -Eq '(^|:)$($script:Config.ports.mavlink_tcp)[[:space:]]' && ss -H -ltn | grep -Eq '(^|:)$($script:Config.ports.mission_planner_tcp)[[:space:]]'" -AllowFailure
        if ($listen.ExitCode -eq 0) { $mavlinkReady = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $mavlinkReady) { throw "SITL did not open MAVLink TCP $($script:Config.ports.mavlink_tcp)/$($script:Config.ports.mission_planner_tcp) within 60 seconds." }
    Write-Pass 'MAVLink listeners' "TCP $($script:Config.ports.mavlink_tcp)/$($script:Config.ports.mission_planner_tcp) ready"

    if ($StartRos2) { Start-RosBridge -RunDirectory $runDirectory -Settings $settings }
    if ($StartVins) { Start-VinsStack -RunDirectory $runDirectory -Settings $settings }

    if ($WithMissionPlanner -or -not $NoMissionPlanner) {
        & (Join-Path $PSScriptRoot 'mission-planner.ps1') -Action Start -RunDirectory $runDirectory -Port $script:Config.ports.mission_planner_tcp
    }

    $metadata = [ordered]@{
        schema = 1; status = 'RUNNING'; kind = $kind; started_at = (Get-Date).ToUniversalTime().ToString('o')
        repository_commit = (& git -C $script:RepoRoot rev-parse HEAD 2>$null)
        cosys_commit = $script:Lock.submodules.'third_party/Cosys-AirSim'.commit
        ardupilot_commit = $script:Lock.submodules.'third_party/ardupilot'.commit
        ue = $script:Lock.platform.unreal_engine; settings = $settings.Path
        environment = [ordered]@{ id = $environmentManifest.id; version = $environmentManifest.version; readiness = $environmentManifest.readiness; preview_authorized = [bool]$Preview; map = $environmentManifest.map_path; render_profile = $RenderProfile; runtime_gate = $environmentRuntimeGate }
        endpoints = $script:Config.ports; network = $settings.Network
        ros2 = [ordered]@{ enabled = [bool]$StartRos2; domain_id = [int]$script:Config.future_ros_domain_id }
        vins = [ordered]@{
            enabled = [bool]$StartVins
            runtime_mode = $IvinsRuntime
            overlay = $(if ($IvinsRuntime -eq 'installed') { '~/.local/share/indra-cosys/ivins-adapter-overlay-jazzy/install/setup.bash' } else { '~/.local/share/indra-cosys/vins-overlay-jazzy/install/setup.bash' })
        }
    }
    Write-JsonFile $metadata (Join-Path $runDirectory 'summary.json')
    return $runDirectory
}

function Invoke-SmokeTest {
    try {
        $runDirectory = Start-Environment -ForTest $true -NoMissionPlanner -StartRos2:$WithRos2
    } catch {
        $startupRun = Get-ActiveRun
        if ($startupRun) { Stop-RecordedProcesses $startupRun }
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
        throw
    }
    try {
        $runWsl = Convert-ToWslPath $runDirectory
        $controller = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\demo_mission.py')
        $timeout = [int]$script:Config.mission.timeout_s
        Write-Step 'Uploading TAKEOFF -> 15 m square -> LAND and evaluating acceptance gates'
        $command = "source ~/venv-ardupilot/bin/activate && timeout $($timeout + 30) python3 '$controller' --connect tcp:127.0.0.1:$($script:Config.ports.mavlink_tcp) --output '$runWsl/mission-result.json' --sitl-pid-file '$runWsl/sitl/sitl.pid' --lat $($script:Config.origin.latitude) --lon $($script:Config.origin.longitude) --alt $($script:Config.origin.altitude_m) --takeoff $($script:Config.mission.takeoff_m) --side $($script:Config.mission.square_side_m) --timeout $timeout"
        $result = Invoke-Wsl -Command $command -AllowFailure
        $result.Output | Tee-Object -FilePath (Join-Path $runDirectory 'controller.log') | ForEach-Object { Write-Host $_ }
        if ($result.ExitCode -ne 0) { throw "Smoke mission failed with code $($result.ExitCode)." }
        $mission = Get-Content -Raw -LiteralPath (Join-Path $runDirectory 'mission-result.json') | ConvertFrom-Json
        if ($mission.verdict -ne 'PASS') { throw "Smoke mission verdict is $($mission.verdict)." }
        $summaryPath = Join-Path $runDirectory 'summary.json'
        $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        $summary.status = 'PASS'
        $summary | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
        $summary | Add-Member -NotePropertyName mission -NotePropertyValue $mission -Force
        if ($WithRos2) {
            $bridgeStatus = Assert-RosBridgeTransport -RunDirectory $runDirectory
            $summary | Add-Member -NotePropertyName ros_bridge_status -NotePropertyValue $bridgeStatus -Force
        }
        Write-JsonFile $summary $summaryPath
        Write-Host "Smoke mission PASS: $runDirectory" -ForegroundColor Green
    } catch {
        $summaryPath = Join-Path $runDirectory 'summary.json'
        if (Test-Path -LiteralPath $summaryPath) {
            $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
            $summary.status = 'FAIL'; $summary | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force; Write-JsonFile $summary $summaryPath
        }
        throw
    } finally {
        Stop-RecordedProcesses $runDirectory
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
    }
}

function Assert-RosBridgeTransport([string]$RunDirectory) {
    $statusPath = Join-Path $RunDirectory 'ros2\status.json'
    if (-not (Test-Path -LiteralPath $statusPath)) { throw "ROS bridge status is missing: $statusPath" }
    $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
    if ([string]$status.last_error) { throw "ROS bridge reported an error: $($status.last_error)" }
    foreach ($topic in @('/sim/body/imu', '/sim/camera/imu')) {
        $sample = $status.topics.PSObject.Properties[$topic].Value
        if ($null -eq $sample) { throw "ROS bridge status is missing $topic" }
        if ([int64]$sample.errors -ne 0) { throw "ROS bridge $topic recorded $($sample.errors) errors" }
        if ([int64]$sample.batch_overflows -ne 0) { throw "ROS bridge $topic recorded $($sample.batch_overflows) batch overflows" }
        if ([int64]$sample.physical_rejected -ne 0) { throw "ROS bridge $topic rejected $($sample.physical_rejected) physically invalid samples" }
        if ([int64]$sample.backward_dropped -ne 0 -or [int64]$sample.duplicates_dropped -ne 0) {
            throw "ROS bridge $topic did not preserve a strictly increasing sample sequence"
        }
    }
    return $status
}

function Invoke-RosTopicTest {
    try {
        $runDirectory = Start-Environment -ForTest $true -NoMissionPlanner -StartRos2
    } catch {
        $startupRun = Get-ActiveRun
        if ($startupRun) { Stop-RecordedProcesses $startupRun }
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
        throw
    }
    try {
        $runWsl = Convert-ToWslPath $runDirectory
        $profile = Convert-ToWslPath (Join-Path $script:RepoRoot 'config\ros2\sensor-profile.json')
        $probe = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\ros_topic_probe.py')
        $output = "$runWsl/ros2/topic-probe.json"
        $domainId = [int]$script:Config.future_ros_domain_id
        $command = "if [ -f /opt/ros/jazzy/setup.bash ]; then source /opt/ros/jazzy/setup.bash; else source /opt/iros2j/setup.bash; fi; export ROS_DOMAIN_ID=$domainId; ~/venv-ardupilot/bin/python3 '$probe' --duration 12 --profile '$profile' --output '$output'"
        Write-Step 'Probing SIM2-compatible ROS 2 topics, rates, frames and timestamps'
        $result = Invoke-Wsl -Command $command -AllowFailure
        $result.Output | Tee-Object -FilePath (Join-Path $runDirectory 'ros2\topic-probe.log') | ForEach-Object { Write-Host $_ }
        if ($result.ExitCode -ne 0) { throw "ROS topic conformance failed with code $($result.ExitCode)." }
        $probeResult = Get-Content -Raw -LiteralPath (Join-Path $runDirectory 'ros2\topic-probe.json') | ConvertFrom-Json
        $bridgeStatus = Assert-RosBridgeTransport -RunDirectory $runDirectory
        $summaryPath = Join-Path $runDirectory 'summary.json'
        $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        $summary.status = 'PASS'
        $summary | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
        $summary | Add-Member -NotePropertyName ros_topic_probe -NotePropertyValue $probeResult -Force
        $summary | Add-Member -NotePropertyName ros_bridge_status -NotePropertyValue $bridgeStatus -Force
        Write-JsonFile $summary $summaryPath
        Write-Host "ROS topic conformance PASS: $runDirectory" -ForegroundColor Green
    } catch {
        $summaryPath = Join-Path $runDirectory 'summary.json'
        if (Test-Path -LiteralPath $summaryPath) {
            $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
            $summary.status = 'FAIL'
            $summary | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force
            Write-JsonFile $summary $summaryPath
        }
        throw
    } finally {
        Stop-RecordedProcesses $runDirectory
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VinsRuntimeTest {
    try {
        $runDirectory = Start-Environment -ForTest $true -NoMissionPlanner -StartRos2 -StartVins
    } catch {
        $startupRun = Get-ActiveRun
        if ($startupRun) { Stop-RecordedProcesses $startupRun }
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
        throw
    }
    try {
        $runWsl = Convert-ToWslPath $runDirectory
        $repoWsl = Convert-ToWslPath $script:RepoRoot
        $qualification = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\vins_flight_qualification.sh')
        $output = "$runWsl/vins/runtime-probe.json"
        $domainId = [int]$script:Config.future_ros_domain_id
        $controllerPort = [int]$script:Config.ports.mission_planner_tcp
        $missionTimeout = [int]$script:Config.mission.timeout_s
        $command = "bash '$qualification' '$repoWsl' '$runWsl' '$domainId' '$controllerPort' '$($script:Config.origin.latitude)' '$($script:Config.origin.longitude)' '$($script:Config.origin.altitude_m)' '$($script:Config.mission.takeoff_m)' '$($script:Config.mission.square_side_m)' '$missionTimeout' '480' '180'"
        Write-Step 'Waiting for iHUB calibration, then flying a GPS-safe translation route for VINS/ExternalNav admission'
        $result = Invoke-Wsl -Command $command -AllowFailure
        $result.Output | Tee-Object -FilePath (Join-Path $runDirectory 'vins\runtime-probe.log') | ForEach-Object { Write-Host $_ }
        if ($result.ExitCode -ne 0) { throw "VINS runtime qualification failed with code $($result.ExitCode)." }
        $probeResult = Get-Content -Raw -LiteralPath (Join-Path $runDirectory 'vins\runtime-probe.json') | ConvertFrom-Json
        if ($probeResult.status -ne 'PASS') { throw "VINS runtime verdict is $($probeResult.status)." }
        $missionPath = Join-Path $runDirectory 'vins\qualification-mission.json'
        if (-not (Test-Path -LiteralPath $missionPath)) { throw 'VINS translation mission evidence is missing.' }
        $missionResult = Get-Content -Raw -LiteralPath $missionPath | ConvertFrom-Json
        if ($missionResult.verdict -ne 'PASS') { throw "VINS translation mission verdict is $($missionResult.verdict)." }
        $bridgeStatus = Assert-RosBridgeTransport -RunDirectory $runDirectory
        if ([int64]$bridgeStatus.gimbal.rejected -ne 0) { throw 'ROS bridge rejected an authoritative gimbal sample.' }
        $summaryPath = Join-Path $runDirectory 'summary.json'
        $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        $summary.status = 'PASS'
        $summary | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
        $summary | Add-Member -NotePropertyName vins_runtime_probe -NotePropertyValue $probeResult -Force
        $summary | Add-Member -NotePropertyName vins_translation_mission -NotePropertyValue $missionResult -Force
        $summary | Add-Member -NotePropertyName ros_bridge_status -NotePropertyValue $bridgeStatus -Force
        Write-JsonFile $summary $summaryPath
        Write-Host "VINS runtime PASS: $runDirectory" -ForegroundColor Green
    } catch {
        $summaryPath = Join-Path $runDirectory 'summary.json'
        if (Test-Path -LiteralPath $summaryPath) {
            $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
            $summary.status = 'FAIL'
            $summary | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force
            Write-JsonFile $summary $summaryPath
        }
        throw
    } finally {
        Stop-RecordedProcesses $runDirectory
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
    }
}

switch ($Command) {
    'doctor' { exit (Invoke-Doctor) }
    'setup' { Invoke-Setup }
    'build' { Invoke-Build }
    'run' { Assert-QualificationCapabilities; $run = Start-Environment $false -NoMissionPlanner:$NoMissionPlanner -StartRos2:$WithRos2; Write-Host "Environment is running. Evidence: $run" -ForegroundColor Green }
    'test' { Assert-QualificationCapabilities; Invoke-SmokeTest }
    'ros-test' { Invoke-RosTopicTest }
    'vins-test' { Invoke-VinsRuntimeTest }
    'ivins' { Invoke-IvinsManagement }
    'camera-test' {
        Write-Step 'Qualifying raw-RGB camera profiles: 640x480 >= 20 FPS, 1280x720 >= 10 FPS (Mission Planner is not started)'
        & (Join-Path $PSScriptRoot 'camera-benchmark.ps1') -Width 640 -Height 480 -DurationSeconds 20 -MinRawFps 20 -Environment $Environment -RenderProfile $RenderProfile -Preview:$Preview
        if ($LASTEXITCODE -ne 0) { throw '640x480 camera benchmark failed.' }
        & (Join-Path $PSScriptRoot 'camera-benchmark.ps1') -Width 1280 -Height 720 -DurationSeconds 20 -MinRawFps 10 -Environment $Environment -RenderProfile $RenderProfile -Preview:$Preview
        if ($LASTEXITCODE -ne 0) { throw '1280x720 camera benchmark failed.' }
    }
    'stop' {
        $run = Get-ActiveRun
        if ($run) { Stop-RecordedProcesses $run; Write-Step "Stopped environment for $run" } else { Write-Warn 'Stop' 'no active run is recorded' }
        Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
    }
    'logs' {
        $latest = Get-ChildItem -LiteralPath $script:LogsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw 'No run bundles exist yet.' }
        Write-Host $latest.FullName
        Invoke-Item -LiteralPath $latest.FullName
    }
    'env' {
        switch ($EnvironmentCommand) {
            'list' { Invoke-EnvironmentList }
            'doctor' { exit (Invoke-EnvironmentDoctor -EnvironmentId $Environment) }
            'build-map' { Invoke-EnvironmentBuildMap -EnvironmentId $Environment }
            'import-assets' {
                if ($Environment -ne 'sim2-rural') { throw "Asset import is not implemented for environment '$Environment'." }
                & (Join-Path $PSScriptRoot 'import-epic-template-tree.ps1')
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                & (Join-Path $PSScriptRoot 'import-polyhaven-rural-assets.ps1')
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                & (Join-Path $PSScriptRoot 'import-quaternius-crops.ps1')
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
        }
    }
    'capabilities' { Write-Capabilities }
}
exit 0
