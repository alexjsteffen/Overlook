<#
.SYNOPSIS
    Builds, tests, and packages the native WinUI 3 Overlook client on Windows.
.DESCRIPTION
    Supports Swift installed via Scoop ($env:USERPROFILE\scoop\apps\swift\current)
    or the official Swift for Windows installer, along with Visual Studio 2022
    (Desktop development with C++ and Windows 10/11 SDK).
.PARAMETER Configuration
    Build configuration: 'debug' or 'release' (default: 'release').
.PARAMETER Test
    Run OverlookCoreTests unit tests after building.
.PARAMETER SmokeTest
    Run Overlook.exe smoke tests (--smoke-test and --capture-smoke-test).
.PARAMETER Package
    Stage a self-contained portable distribution in dist\Overlook-Windows-x64 and zip it.
#>
[CmdletBinding()]
param(
    [ValidateSet("debug", "release")]
    [string]$Configuration = "release",
    [switch]$Test,
    [switch]$SmokeTest,
    [switch]$Package
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "==> Overlook Windows Build (WinUI 3 + Swift + WinHTTP/GStreamer)" -ForegroundColor Cyan

# 1. Locate Swift (Scoop or system PATH)
$ScoopSwiftBin = Join-Path $env:USERPROFILE "scoop\apps\swift\current\usr\bin"
if ((Test-Path $ScoopSwiftBin) -and ($env:PATH -notlike "*$ScoopSwiftBin*")) {
    Write-Host "    Found Scoop Swift toolchain at $ScoopSwiftBin" -ForegroundColor Gray
    $env:PATH = "$ScoopSwiftBin;$env:PATH"
}

$SwiftCmd = Get-Command swift.exe -ErrorAction SilentlyContinue
if (-not $SwiftCmd) {
    throw "swift.exe not found on PATH or in Scoop ($ScoopSwiftBin). Install via 'scoop install swift'."
}
Write-Host "    Using Swift: $($SwiftCmd.Source)" -ForegroundColor Gray
& swift --version

# 2. Ensure Visual Studio C++ & Windows SDK environment is active
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if ((Test-Path $VsWhere) -and (-not $env:WindowsSdkDir)) {
    $VsInstallDir = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($VsInstallDir) {
        $VcVars = Join-Path $VsInstallDir "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $VcVars) {
            Write-Host "    Importing Visual Studio x64 environment from $VcVars" -ForegroundColor Gray
            cmd /c "`"$VcVars`" >nul && set" | ForEach-Object {
                if ($_ -match "^([^=]+)=(.*)$") {
                    [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
                }
            }
        }
    }
}

# 3. Sync shared OverlookCore sources from ..\Linux if present
$LinuxCore = Join-Path $ScriptDir "..\Linux\Sources\OverlookCore"
$WinCore = Join-Path $ScriptDir "Sources\OverlookCore"
if (Test-Path $LinuxCore) {
    New-Item -ItemType Directory -Force -Path $WinCore | Out-Null
    Copy-Item -Force (Join-Path $LinuxCore "*.swift") $WinCore
}
$LinuxTests = Join-Path $ScriptDir "..\Linux\Tests\OverlookCoreTests"
$WinTests = Join-Path $ScriptDir "Tests\OverlookCoreTests"
if (Test-Path $LinuxTests) {
    New-Item -ItemType Directory -Force -Path $WinTests | Out-Null
    Copy-Item -Force (Join-Path $LinuxTests "*.swift") $WinTests
}

# 4. Build Overlook
Write-Host "==> Building Overlook ($Configuration)..." -ForegroundColor Cyan
& swift build -c $Configuration
if ($LASTEXITCODE -ne 0) {
    throw "swift build failed with exit code $LASTEXITCODE"
}

$BinDir = (& swift build -c $Configuration --show-bin-path).Trim()
$ExePath = Join-Path $BinDir "Overlook.exe"

# Embed application manifest if mt.exe is available
$ManifestPath = Join-Path $ScriptDir "packaging\Overlook.exe.manifest"
$MtCmd = Get-Command mt.exe -ErrorAction SilentlyContinue
if ($MtCmd -and (Test-Path $ExePath) -and (Test-Path $ManifestPath)) {
    Write-Host "    Embedding Per-Monitor V2 DPI manifest into Overlook.exe" -ForegroundColor Gray
    & mt.exe -nologo -manifest $ManifestPath -outputresource:"$ExePath;#1"
}

# 5. Run unit tests if requested
if ($Test) {
    Write-Host "==> Running OverlookCoreTests..." -ForegroundColor Cyan
    & swift test -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "swift test failed with exit code $LASTEXITCODE"
    }
}

# 6. Run smoke tests if requested
if ($SmokeTest -and (Test-Path $ExePath)) {
    Write-Host "==> Running Overlook UI smoke tests..." -ForegroundColor Cyan
    & $ExePath --smoke-test
    if ($LASTEXITCODE -ne 0) { throw "UI smoke test failed ($LASTEXITCODE)" }
    & $ExePath --capture-smoke-test
    if ($LASTEXITCODE -ne 0) { throw "Capture dialog smoke test failed ($LASTEXITCODE)" }
}

# 7. Stage portable distribution if requested
if ($Package) {
    $DistRoot = Join-Path $ScriptDir "..\dist\Overlook-Windows-x64"
    $ZipPath = Join-Path $ScriptDir "..\dist\Overlook-Windows-x64.zip"
    Write-Host "==> Staging distribution in $DistRoot..." -ForegroundColor Cyan
    if (Test-Path $DistRoot) { Remove-Item -Recurse -Force $DistRoot }
    New-Item -ItemType Directory -Force -Path $DistRoot | Out-Null

    Copy-Item -Force $ExePath $DistRoot
    Copy-Item -Force $ManifestPath $DistRoot
    Get-ChildItem -Path $BinDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Force $_.FullName $DistRoot
    }

    # Copy Swift runtime DLLs when available
    $SwiftRuntimeDir = Join-Path $env:USERPROFILE "scoop\apps\swift\current\usr\bin"
    if (Test-Path $SwiftRuntimeDir) {
        Get-ChildItem -Path $SwiftRuntimeDir -Filter "swift*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Force $_.FullName $DistRoot
        }
        Get-ChildItem -Path $SwiftRuntimeDir -Filter "BlocksRuntime.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Force $_.FullName $DistRoot
        }
        Get-ChildItem -Path $SwiftRuntimeDir -Filter "dispatch.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Force $_.FullName $DistRoot
        }
        Get-ChildItem -Path $SwiftRuntimeDir -Filter "Foundation*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Force $_.FullName $DistRoot
        }
    }

    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    Compress-Archive -Path "$DistRoot\*" -DestinationPath $ZipPath
    Write-Host "==> Packaged portable archive: $ZipPath" -ForegroundColor Green
}

Write-Host "==> Done! Binary: $ExePath" -ForegroundColor Green
