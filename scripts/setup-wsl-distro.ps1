[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$DistroName = 'INDRA-COSYS-SIM'
)

$ErrorActionPreference = 'Stop'
$ubuntuVersion = '24.04.4'
$imageName = "ubuntu-$ubuntuVersion-wsl-amd64.wsl"
$imageUrl = "https://releases.ubuntu.com/noble/$imageName"
$imageSha256 = '9b2f7730dc68227dd04a9f3e5eab86ad85caf556b8606ad94f1f29ff5c4fd3f5'

$installed = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() }
if ($installed -contains $DistroName) {
    & wsl.exe -d $DistroName -u root -- test -f /etc/os-release
    if ($LASTEXITCODE -ne 0) { throw "WSL distribution '$DistroName' exists but is not healthy." }
} else {
    $runtimeImages = Join-Path $RepoRoot '.runtime\wsl-images'
    $imagePath = Join-Path $runtimeImages $imageName
    $janusRoot = Split-Path -Parent $RepoRoot
    $installPath = Join-Path (Join-Path $janusRoot 'WSL') $DistroName
    New-Item -ItemType Directory -Force -Path $runtimeImages, $installPath | Out-Null

    if (-not (Test-Path -LiteralPath $imagePath)) {
        Write-Host "Downloading the pinned Ubuntu $ubuntuVersion WSL image..."
        & curl.exe --fail --location --output $imagePath $imageUrl
        if ($LASTEXITCODE -ne 0) { throw "Unable to download $imageUrl" }
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $imagePath).Hash.ToLowerInvariant()
    if ($actualHash -ne $imageSha256) {
        throw "Ubuntu WSL image checksum mismatch: expected $imageSha256, found $actualHash"
    }

    Write-Host "Importing isolated WSL distribution '$DistroName' into $installPath..."
    & wsl.exe --import $DistroName $installPath $imagePath --version 2
    if ($LASTEXITCODE -ne 0) { throw "Unable to import WSL distribution '$DistroName'." }
}

$osRelease = ((& wsl.exe -d $DistroName -u root -- cat /etc/os-release) -join "`n")
if ($LASTEXITCODE -ne 0 -or $osRelease -notmatch '(?m)^VERSION_ID="?24\.04"?$') {
    throw "Imported WSL distribution '$DistroName' is not Ubuntu 24.04."
}

$bootstrap = @'
set -euo pipefail
if ! id indra >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash indra
fi
usermod -aG sudo indra
printf '%s\n' 'indra ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-indra-cosys-sim
chmod 0440 /etc/sudoers.d/90-indra-cosys-sim
printf '%s\n' '[user]' 'default=indra' '[boot]' 'systemd=true' >/etc/wsl.conf
'@
& wsl.exe -d $DistroName -u root -- bash -lc $bootstrap
if ($LASTEXITCODE -ne 0) { throw "Unable to configure the isolated WSL user in '$DistroName'." }
& wsl.exe --terminate $DistroName
if ($LASTEXITCODE -ne 0) { throw "Unable to restart WSL distribution '$DistroName'." }
& wsl.exe -d $DistroName -- bash -lc 'test "$(id -un)" = indra'
if ($LASTEXITCODE -ne 0) { throw "WSL distribution '$DistroName' did not select the indra user." }
