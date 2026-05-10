[CmdletBinding()]
param(
    [string]$InstallDir = $env:KILL_PORT_INSTALL_DIR
)

$ErrorActionPreference = "Stop"

$Repo = "renatogalera/kill-port"
$BaseUrl = "https://github.com/$Repo/releases/latest/download"

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "install.ps1 supports Windows only"
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\kill-port\bin"
}

$Arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$Cpu = switch ($Arch) {
    "X64" { "amd64" }
    "Arm64" { "arm64" }
    default { throw "Unsupported architecture: $Arch" }
}

$Asset = "kill-port-windows-$Cpu"
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("kill-port-install-" + [Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    $Archive = Join-Path $TempDir "$Asset.tar.gz"
    $Checksum = Join-Path $TempDir "$Asset.tar.gz.sha256"

    Write-Host "Downloading $Asset.tar.gz"
    Invoke-WebRequest -Uri "$BaseUrl/$Asset.tar.gz" -OutFile $Archive
    Invoke-WebRequest -Uri "$BaseUrl/$Asset.tar.gz.sha256" -OutFile $Checksum

    $Expected = ((Get-Content -Raw $Checksum).Trim() -split "\s+")[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) {
        throw "Checksum mismatch"
    }

    $Tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $Tar) {
        throw "tar.exe is required to extract the release archive"
    }

    & $Tar.Source -xzf $Archive -C $TempDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract $Archive"
    }

    $Binary = Join-Path $TempDir "$Asset\kill-port.exe"
    if (-not (Test-Path $Binary)) {
        throw "Archive does not contain kill-port.exe"
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Destination = Join-Path $InstallDir "kill-port.exe"
    Copy-Item -Force -Path $Binary -Destination $Destination

    $PathEntries = ($env:Path -split ";") | Where-Object { $_ }
    $InCurrentPath = $PathEntries | Where-Object {
        $_.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")
    }

    if (-not $InCurrentPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $UserEntries = @()
        if (-not [string]::IsNullOrWhiteSpace($UserPath)) {
            $UserEntries = $UserPath -split ";" | Where-Object { $_ }
        }

        $InUserPath = $UserEntries | Where-Object {
            $_.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")
        }

        if (-not $InUserPath) {
            $NewUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) {
                $InstallDir
            } else {
                "$UserPath;$InstallDir"
            }
            [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
        }

        $env:Path = "$env:Path;$InstallDir"
        Write-Host "Added $InstallDir to the user PATH. Open a new terminal if this one does not pick it up."
    }

    Write-Host "Installed kill-port to $Destination"
    & $Destination --version
}
finally {
    Remove-Item -Recurse -Force -Path $TempDir -ErrorAction SilentlyContinue
}
