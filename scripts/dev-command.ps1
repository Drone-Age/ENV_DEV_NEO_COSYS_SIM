[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('doctor', 'setup', 'build', 'run', 'test', 'camera-test', 'stop', 'logs', 'env', 'capabilities')][string]$Command,
    [ValidateSet('list', 'doctor', 'build-map')][string]$EnvironmentCommand = 'list',
    [string]$Environment = 'blocks',
    [ValidateSet('qualification', 'visual')][string]$RenderProfile = 'qualification',
    [switch]$NoMissionPlanner,
    [switch]$Headless,
    [switch]$SkipBuild,
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
    [switch]$WithMissionPlanner
)

. (Join-Path $PSScriptRoot 'common.ps1')
New-Item -ItemType Directory -Force -Path $script:RuntimeRoot, $script:LogsRoot | Out-Null

function Test-PortFree([int]$Port) {
    $tcp = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    return -not ($tcp -or $udp)
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
        $manifest = Get-EnvironmentManifest -EnvironmentId $EnvironmentId -RequireReady
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
    if ($EnvironmentId -ne 'sim2-rural') { throw "Automated map generation is not implemented for environment '$EnvironmentId'." }
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
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'unreal\IndraCosysDemo'))
    $stagedPlugin = [IO.Path]::GetFullPath((Join-Path $projectRoot 'Plugins\Environments\Sim2Rural'))
    if (-not $stagedPlugin.StartsWith($projectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $stagedPlugin) -ne 'Sim2Rural') { throw "Unsafe staged plugin path: $stagedPlugin" }
    $stagedContent = Join-Path $stagedPlugin 'Content'
    if (Test-Path -LiteralPath $stagedContent) { Remove-Item -LiteralPath $stagedContent -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stagedContent | Out-Null

    Write-Step 'Building the deterministic Sim2Rural editor commandlet'
    $project = Join-Path $projectRoot 'IndraCosysDemo.uproject'
    $buildBat = Join-Path $ue 'Engine\Build\BatchFiles\Build.bat'
    & $buildBat IndraCosysDemoEditor Win64 Development "-Project=$project" -WaitMutex -FromMsBuild -NoUBA "-CompilerVersion=$compilerVersion" "-VCToolchainVersion=$compilerVersion" '-WindowsSdkVersion=10.0.22621.0'
    if ($LASTEXITCODE -ne 0) { throw 'Sim2Rural editor commandlet build failed.' }

    $heightmap = Join-Path $script:EnvironmentsRoot 'sim2-rural\data\derived\gis\copdem-2021\height\SIM2_Rural_4033.png'
    $imagery = Join-Path $script:EnvironmentsRoot 'sim2-rural\data\derived\gis\sentinel2-20250903\imagery\SIM2_Rural_Imagery_4096.png'
    if (-not (Test-Path -LiteralPath $heightmap) -or -not (Test-Path -LiteralPath $imagery)) { throw 'Pinned Copernicus/Sentinel-2 build inputs are missing. Initialise Git LFS and run env doctor.' }
    $editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
    $buildLog = Join-Path $script:RuntimeRoot 'sim2-rural-build-map.log'
    Write-Step 'Generating the 4033 x 4033 World Partition landscape and real-map material'
    & $editor $project '-run=Sim2RuralBuildMap' "-Heightmap=$heightmap" "-Imagery=$imagery" -unattended -nop4 -nosplash -NoSound -AllowCommandletRendering "-abslog=$buildLog"
    if ($LASTEXITCODE -ne 0) { throw "Sim2Rural map generation failed; see $buildLog" }

    $sourcePlugin = [IO.Path]::GetFullPath((Join-Path $script:EnvironmentsRoot 'sim2-rural\Plugins\Sim2Rural'))
    $sourceContent = [IO.Path]::GetFullPath((Join-Path $sourcePlugin 'Content'))
    if (-not $sourceContent.StartsWith($sourcePlugin.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $sourceContent) -ne 'Content') { throw "Unsafe source content path: $sourceContent" }
    New-Item -ItemType Directory -Force -Path $sourceContent | Out-Null
    & robocopy.exe $stagedContent $sourceContent /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Generated Sim2Rural content sync failed with robocopy code $LASTEXITCODE." }

    $verifyLog = Join-Path $script:RuntimeRoot 'sim2-rural-verify-map.log'
    Write-Step 'Reloading the saved map and verifying World Partition, imagery and collision'
    & $editor $project '-run=Sim2RuralBuildMap' -VerifyOnly -unattended -nop4 -nosplash -NoSound "-abslog=$verifyLog"
    if ($LASTEXITCODE -ne 0) { throw "Sim2Rural map verification failed; see $verifyLog" }
    Write-Pass 'SIM2 Rural map' 'World Partition, 1024 render components, 1024 collision components, EPSG:32636 and Sentinel-2 material'
}

function Write-Capabilities {
    $manifest = Get-EnvironmentManifest -EnvironmentId $Environment -AllowScaffold
    $capabilities = [ordered]@{
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
            ros2 = $false
            vins = $false
            wind_command_ack = $false
            camera_fixed_rate_hz = $false
            camera_imu_batched = $false
        }
        commands = [ordered]@{
            run = @('-Environment', '-RenderProfile', '-Headless', '-NoMissionPlanner')
            test = @('-Environment', '-RenderProfile')
            qualification_accepted_args = @('-RunId', '-FlightLogDirectory', '-Rosbag', '-FlightQualification', '-FlightQualificationLimitM', '-FlightQualificationProfile', '-FlightQualificationNoWind', '-FlightQualificationNoVisualUi', '-RouteQualification', '-RouteQualificationProfile', '-VinsConfigFile', '-Distro', '-WithMissionPlanner')
        }
    }
    $serialized = $capabilities | ConvertTo-Json -Depth 10
    if ($Json) { Write-Output $serialized } else { $capabilities | Format-List }
}

function Assert-QualificationCapabilities {
    if (-not $FlightQualification -and -not $RouteQualification) { return }
    if ($FlightQualification -and $RouteQualification) { throw 'FlightQualification and RouteQualification are mutually exclusive.' }
    $missing = @('ros2', 'vins', 'camera_fixed_rate_hz', 'camera_imu_batched', 'wind_command_ack')
    if ($FlightQualificationNoWind) { $missing = @($missing | Where-Object { $_ -ne 'wind_command_ack' }) }
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
    Write-Step 'Initialising pinned submodules'
    & git submodule update --init third_party/Cosys-AirSim third_party/ardupilot
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
        $actual = (& git -C $componentPath rev-parse HEAD).Trim()
        if ($actual -ne $entry.Value.commit) { throw "$($entry.Name) is not at its pinned commit." }
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
        Write-Warn 'WSL prerequisites' 'sudo may request the Ubuntu password in this terminal'
        & wsl.exe -d $script:Lock.platform.wsl_distribution -- bash -lc "cd '$ardupilot' && export DO_PYTHON_VENV_ENV=0 && Tools/environment_install/install-prereqs-ubuntu.sh -y 2>&1 | tee '$setupLog'"
        if ($LASTEXITCODE -ne 0) { throw "ArduPilot prerequisite setup failed; see .runtime\ardupilot-prerequisites.log" }
    }
    $rpcReady = Invoke-Wsl -Command "~/venv-ardupilot/bin/python -c 'import msgpackrpc'" -AllowFailure
    if ($rpcReady.ExitCode -ne 0) {
        Write-Step 'Installing the Cosys RPC client into the ArduPilot Python environment'
        Invoke-Wsl -Command "~/venv-ardupilot/bin/pip install rpc-msgpack" | Out-Null
    }
    Write-Pass 'Cosys Python client' 'rpc-msgpack available for camera qualification'
    Write-Pass 'ArduPilot prerequisites' 'Ubuntu toolchain and ~/venv-ardupilot ready'

    $ue = Get-UeRoot
    if ($ue) {
        try {
            & (Join-Path $PSScriptRoot 'configure-firewall.ps1') -UnrealEditor (Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor.exe') -ControlPort $script:Config.ports.cosys_control_udp -SensorPort $script:Config.ports.sitl_sensor_udp
            Write-Pass 'Host/WSL firewalls' 'Unreal UDP 9022 and WSL SITL UDP 9023 only'
        } catch { Write-Warn 'Host/WSL firewalls' 'run setup once from an elevated PowerShell to add the two narrow UDP rules' }
    }
}

function Invoke-Build {
    $environmentManifest = Get-EnvironmentManifest -EnvironmentId $Environment -RequireReady
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
    & $buildBat IndraCosysDemoEditor Win64 Development "-Project=$project" -WaitMutex -FromMsBuild "-CompilerVersion=$compilerVersion" "-VCToolchainVersion=$compilerVersion" '-WindowsSdkVersion=10.0.22621.0'
    if ($LASTEXITCODE -ne 0) { throw 'Unreal Development Editor build failed.' }

    Write-Step 'Building ArduCopter SITL in Ubuntu 24.04'
    $ardupilot = Convert-ToWslPath (Join-Path $script:RepoRoot 'third_party\ardupilot')
    Invoke-Wsl -Command "cd '$ardupilot' && source ~/venv-ardupilot/bin/activate && ./waf configure --board sitl && ./waf copter" | Out-Null
    Write-Pass 'Build' 'Cosys-AirSim, IndraCosysDemoEditor and ArduCopter SITL'
}

function Start-Environment([bool]$ForTest, [switch]$NoMissionPlanner) {
    if ($Distro -ne $script:Lock.platform.wsl_distribution) { throw "This pinned bundle requires WSL distribution '$($script:Lock.platform.wsl_distribution)', received '$Distro'." }
    $environmentManifest = Get-EnvironmentManifest -EnvironmentId $Environment -RequireReady
    Stage-EnvironmentPlugin -Manifest $environmentManifest
    if (-not $SkipBuild) {
        $plugin = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Plugins\AirSim\AirSim.uplugin'
        $editorDll = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\Binaries\Win64\UnrealEditor-IndraCosysDemo.dll'
        $sitl = Join-Path $script:RepoRoot 'third_party\ardupilot\build\sitl\bin\arducopter'
        if (-not (Test-Path -LiteralPath $plugin) -or -not (Test-Path -LiteralPath $editorDll) -or -not (Test-Path -LiteralPath $sitl)) { Invoke-Build }
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
    $arguments = @($project, $environmentManifest.map_path, '-game', '-windowed', '-ResX=1280', '-ResY=720', '-log', "-abslog=$ueLog", "-settings=$($settings.Path)", "-IndraRenderProfile=$RenderProfile", "-IndraEnvironment=$($environmentManifest.id)")
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
    Start-Sleep -Seconds 2
    $pidCheck = Invoke-Wsl -Command "test -s '$runWsl/sitl/wsl.pid' && kill -0 `$(cat '$runWsl/sitl/wsl.pid')" -AllowFailure
    if ($pidCheck.ExitCode -ne 0) { throw "ArduCopter SITL exited during startup; see $runDirectory\sitl\sitl.log" }
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

    if ($WithMissionPlanner -or -not $NoMissionPlanner) {
        & (Join-Path $PSScriptRoot 'mission-planner.ps1') -Action Start -RunDirectory $runDirectory -Port $script:Config.ports.mission_planner_tcp
    }

    $metadata = [ordered]@{
        schema = 1; status = 'RUNNING'; kind = $kind; started_at = (Get-Date).ToUniversalTime().ToString('o')
        repository_commit = (& git -C $script:RepoRoot rev-parse HEAD 2>$null)
        cosys_commit = $script:Lock.submodules.'third_party/Cosys-AirSim'.commit
        ardupilot_commit = $script:Lock.submodules.'third_party/ardupilot'.commit
        ue = $script:Lock.platform.unreal_engine; settings = $settings.Path
        environment = [ordered]@{ id = $environmentManifest.id; version = $environmentManifest.version; map = $environmentManifest.map_path; render_profile = $RenderProfile }
        endpoints = $script:Config.ports; network = $settings.Network
    }
    Write-JsonFile $metadata (Join-Path $runDirectory 'summary.json')
    return $runDirectory
}

function Invoke-SmokeTest {
    try {
        $runDirectory = Start-Environment -ForTest $true -NoMissionPlanner
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
        $command = "source ~/venv-ardupilot/bin/activate && timeout $($timeout + 30) python3 '$controller' --connect tcp:127.0.0.1:$($script:Config.ports.mavlink_tcp) --output '$runWsl/mission-result.json' --lat $($script:Config.origin.latitude) --lon $($script:Config.origin.longitude) --alt $($script:Config.origin.altitude_m) --takeoff $($script:Config.mission.takeoff_m) --side $($script:Config.mission.square_side_m) --timeout $timeout"
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

switch ($Command) {
    'doctor' { exit (Invoke-Doctor) }
    'setup' { Invoke-Setup }
    'build' { Invoke-Build }
    'run' { Assert-QualificationCapabilities; $run = Start-Environment $false -NoMissionPlanner:$NoMissionPlanner; Write-Host "Environment is running. Evidence: $run" -ForegroundColor Green }
    'test' { Assert-QualificationCapabilities; Invoke-SmokeTest }
    'camera-test' {
        Write-Step 'Qualifying the 20 FPS raw-RGB camera profile (Mission Planner is not started)'
        & (Join-Path $PSScriptRoot 'camera-benchmark.ps1') -Width 640 -Height 480 -DurationSeconds 20
        if ($LASTEXITCODE -ne 0) { throw '640x480 camera benchmark failed.' }
        & (Join-Path $PSScriptRoot 'camera-benchmark.ps1') -Width 1280 -Height 720 -DurationSeconds 20
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
        }
    }
    'capabilities' { Write-Capabilities }
}
exit 0
