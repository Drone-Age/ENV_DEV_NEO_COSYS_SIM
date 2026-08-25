[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 8192)][int]$Width,
    [Parameter(Mandatory)][ValidateRange(1, 8192)][int]$Height,
    [ValidateRange(5, 300)][int]$DurationSeconds = 20,
    [ValidateRange(0, 240)][double]$MinRawFps = 20,
    [ValidateRange(0, 240)][double]$MinSustainedRawFps = 10,
    [ValidateRange(320, 3840)][int]$ViewportWidth = 640,
    [ValidateRange(240, 2160)][int]$ViewportHeight = 360,
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string]$Environment = 'blocks',
    [ValidateSet('qualification', 'visual')][string]$RenderProfile = 'qualification',
    [switch]$Preview,
    [switch]$Offscreen,
    [switch]$ForceUpdate,
    [switch]$DisableAsyncCamera,
    [switch]$DisableNamedImus,
    [switch]$SaveSamples,
    [switch]$WindowsClient
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$gpuMonitor = $null

if (Get-ActiveRun) { throw 'An environment run is already active. Use .\dev.ps1 stop first.' }
$environmentManifest = Get-RuntimeEnvironmentManifest -EnvironmentId $Environment -Preview:$Preview
Stage-EnvironmentPlugin -Manifest $environmentManifest
if ($environmentManifest.readiness -eq 'preview') {
    Write-Warn 'Preview environment' 'camera evidence is diagnostic until all environment gates pass'
}

$runDirectory = New-RunDirectory "camera-$Environment-$($Width)x$Height"
try {
    $settingsInfo = New-AirSimSettings $runDirectory
    $settings = Get-Content -Raw -LiteralPath $settingsInfo.Path | ConvertFrom-Json
    if ($DisableNamedImus) {
        $settings.Vehicles.Copter.PSObject.Properties.Remove('Sensors')
    }
    $capture = [pscustomobject]@{
        ImageType = 0
        Width = $Width
        Height = $Height
        FOV_Degrees = 90
        LumenGIEnable = $false
        LumenReflectionEnable = $false
        ForceUpdate = [bool]$ForceUpdate
    }
    $settings | Add-Member -NotePropertyName CameraDefaults -NotePropertyValue ([pscustomobject]@{ CaptureSettings = @($capture) }) -Force
    Write-JsonFile $settings $settingsInfo.Path

    $ue = Get-UeRoot
    if (-not $ue) { throw 'UE 5.8.1 was not found.' }
    $editor = Join-Path $ue 'Engine\Binaries\Win64\UnrealEditor.exe'
    $project = Join-Path $script:RepoRoot 'unreal\IndraCosysDemo\IndraCosysDemo.uproject'
    $ueLog = Join-Path $runDirectory 'unreal\Unreal.log'
    $sensorProfile = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ros2\sensor-profile.json') -Raw | ConvertFrom-Json
    $arguments = @(
        $project,
        $environmentManifest.map_path,
        '-game', '-windowed', '-Unattended', '-NoSplash',
        "-ResX=$ViewportWidth", "-ResY=$ViewportHeight",
        "-abslog=$ueLog", "-settings=$($settingsInfo.Path)",
        "-IndraRenderProfile=$RenderProfile", "-IndraEnvironment=$($environmentManifest.id)"
    )
    if (-not $DisableAsyncCamera) {
        $arguments += @(
            '-IndraAsyncCamera', '-IndraCameraName=0',
            "-IndraCameraHz=$([double]$sensorProfile.camera.producer_hz)",
            "-IndraCameraWidth=$Width", "-IndraCameraHeight=$Height"
        )
    }
    if ($Offscreen) { $arguments += '-RenderOffscreen' }
    $ueProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $project) -PassThru
    Save-ProcessState $ueProcess 'unreal' $runDirectory

    Write-Step "Waiting for Cosys RPC at $($settingsInfo.Network.WindowsIp):$($script:Config.ports.cosys_rpc_tcp)"
    $deadline = (Get-Date).AddMinutes(10)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($ueProcess.HasExited) { throw "UnrealEditor exited with code $($ueProcess.ExitCode); see $ueLog" }
        $listener = Get-NetTCPConnection -LocalPort $script:Config.ports.cosys_rpc_tcp -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $ueProcess.Id } | Select-Object -First 1
        if ($listener) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "Cosys RPC was not ready within 10 minutes; see $ueLog" }

    # The ArduCopter backend waits for its UDP peer on the game thread. Start SITL
    # before requesting images so the benchmark measures a live flight topology.
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
    $sitlCommand = "'$sitlLauncher' '$ardupilot' '$runWsl' '$location' '$($script:Config.sitl_instance)' '$($settingsInfo.Network.WindowsIp)' '$($script:Config.ports.mission_planner_tcp)'"
    $sitlStart = Invoke-Wsl -Command $sitlCommand -AllowFailure
    if ($sitlStart.ExitCode -ne 0) { throw "Unable to launch ArduCopter SITL: $($sitlStart.Output -join ' ')" }
    Start-Sleep -Seconds 3
    $pidCheck = Invoke-Wsl -Command "test -s '$runWsl/sitl/wsl.pid' && kill -0 `$(cat '$runWsl/sitl/wsl.pid')" -AllowFailure
    if ($pidCheck.ExitCode -ne 0) { throw "ArduCopter SITL exited during startup; see $runDirectory\sitl\sitl.log" }

    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        $gpuCsv = Join-Path $runDirectory 'gpu-metrics.csv'
        $gpuArguments = @(
            '--query-gpu=timestamp,utilization.gpu,utilization.memory,memory.used,clocks.current.graphics,power.draw',
            '--format=csv,nounits', '--loop-ms=250', "--filename=$gpuCsv"
        )
        $gpuMonitor = Start-Process -FilePath $nvidiaSmi.Source -ArgumentList $gpuArguments -WindowStyle Hidden -PassThru
    } else {
        Write-Warn 'GPU telemetry' 'nvidia-smi.exe was not found; the camera result remains valid without GPU utilization evidence'
    }

    if ($WindowsClient) {
        $benchmark = Join-Path $script:RepoRoot 'scripts\wsl\camera_benchmark.py'
        $output = Join-Path $runDirectory 'camera-benchmark.json'
        $previousPythonPath = $env:PYTHONPATH
        try {
            $env:PYTHONPATH = Join-Path $script:RepoRoot 'third_party\Cosys-AirSim\PythonClient'
            $clientArguments = @($benchmark, '--host', '127.0.0.1', '--port', $script:Config.ports.cosys_rpc_tcp, '--duration', $DurationSeconds, '--min-raw-fps', $MinRawFps, '--min-sustained-raw-fps', $MinSustainedRawFps, '--output', $output)
            if ($SaveSamples) { $clientArguments += '--save-samples' }
            & python @clientArguments 2>&1 |
                Tee-Object -FilePath (Join-Path $runDirectory 'camera-benchmark.log') | ForEach-Object { Write-Host $_ }
            $benchmarkExitCode = $LASTEXITCODE
        } finally {
            $env:PYTHONPATH = $previousPythonPath
        }
        if ($benchmarkExitCode -ne 0) { throw "Camera benchmark failed with code $benchmarkExitCode." }
    } else {
        $benchmark = Convert-ToWslPath (Join-Path $script:RepoRoot 'scripts\wsl\camera_benchmark.py')
        $output = Convert-ToWslPath (Join-Path $runDirectory 'camera-benchmark.json')
        $pythonPath = Convert-ToWslPath (Join-Path $script:RepoRoot 'third_party\Cosys-AirSim\PythonClient')
        $sampleArgument = if ($SaveSamples) { ' --save-samples' } else { '' }
        $command = "source ~/venv-ardupilot/bin/activate && PYTHONPATH='$pythonPath' python3 '$benchmark' --host '$($settingsInfo.Network.WindowsIp)' --port $($script:Config.ports.cosys_rpc_tcp) --duration $DurationSeconds --min-raw-fps $MinRawFps --min-sustained-raw-fps $MinSustainedRawFps --output '$output'$sampleArgument"
        $result = Invoke-Wsl -Command $command -AllowFailure
        $result.Output | Tee-Object -FilePath (Join-Path $runDirectory 'camera-benchmark.log') | ForEach-Object { Write-Host $_ }
        if ($result.ExitCode -ne 0) { throw "Camera benchmark failed with code $($result.ExitCode)." }
    }
    Write-Host "Camera benchmark complete: $runDirectory" -ForegroundColor Green
} finally {
    if ($gpuMonitor -and -not $gpuMonitor.HasExited) {
        Stop-Process -Id $gpuMonitor.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $gpuMonitor.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    Stop-RecordedProcesses $runDirectory
    Remove-Item -LiteralPath (Join-Path $script:RuntimeRoot 'active-run.txt') -Force -ErrorAction SilentlyContinue
}
