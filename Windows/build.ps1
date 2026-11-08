<#
.SYNOPSIS
    Builds, tests, and packages the native Win32 / Fluent Overlook client on Windows.
.DESCRIPTION
    Supports Swift 6.x installed via Scoop ($env:USERPROFILE\scoop\apps\swift\current)
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

Write-Host "==> Overlook Windows Build (Win32 + Swift + WinHTTP/GStreamer)" -ForegroundColor Cyan

# 1. Locate Swift (Scoop or system PATH) & fix Scoop's flattened Swift 6.4+ layout
$ScoopSwiftAppDir = Join-Path $env:USERPROFILE "scoop\apps\swift"
$ScoopSwiftRoot   = Join-Path $ScoopSwiftAppDir "current"

if (Test-Path $ScoopSwiftRoot) {
    $ScoopToolchainBin = Join-Path $ScoopSwiftRoot "Toolchains\usr\bin"
    $ScoopRuntimeBin   = Join-Path $ScoopSwiftRoot "Runtimes\usr\bin"
    $ScoopLegacyBin    = Join-Path $ScoopSwiftRoot "usr\bin"
    $ScoopSdkRoot      = Join-Path $ScoopSwiftRoot "Platforms\Windows.platform\Developer\SDKs\Windows.sdk"

    foreach ($binDir in @($ScoopRuntimeBin, $ScoopToolchainBin, $ScoopLegacyBin)) {
        if ((Test-Path $binDir) -and ($env:PATH -notlike "*$binDir*")) {
            $env:PATH = "$binDir;$env:PATH"
        }
    }

    if ((Test-Path $ScoopSdkRoot) -and (-not $env:SDKROOT)) {
        $env:SDKROOT = $ScoopSdkRoot
        Write-Host "    Set SDKROOT: $env:SDKROOT" -ForegroundColor Gray
    }

    # Scoop flattens 'Toolchains\<ver>+Asserts\usr' into 'Toolchains\usr', which causes
    # Swift 6.4+'s new SwiftBuild engine to walk 4 parent directories up from swift.exe
    # into 'scoop\apps\swift\' instead of 'scoop\apps\swift\current\'.
    # Create non-destructive directory junctions so both '--build-system native' and
    # '--build-system swiftbuild' resolve Platforms and Toolchains cleanly.
    try {
        $ParentPlatforms = Join-Path $ScoopSwiftAppDir "Platforms"
        $CurrentPlatforms = Join-Path $ScoopSwiftRoot "Platforms"
        if ((Test-Path $CurrentPlatforms) -and (-not (Test-Path $ParentPlatforms))) {
            New-Item -ItemType Junction -Path $ParentPlatforms -Target $CurrentPlatforms -ErrorAction SilentlyContinue | Out-Null
        }
        $AssertsDir = Join-Path $ScoopSwiftRoot "Toolchains\0.0.0+Asserts"
        $AssertsUsr = Join-Path $AssertsDir "usr"
        $CurrentUsr = Join-Path $ScoopSwiftRoot "Toolchains\usr"
        if ((Test-Path $CurrentUsr) -and (-not (Test-Path $AssertsUsr))) {
            New-Item -ItemType Directory -Force -Path $AssertsDir -ErrorAction SilentlyContinue | Out-Null
            New-Item -ItemType Junction -Path $AssertsUsr -Target $CurrentUsr -ErrorAction SilentlyContinue | Out-Null
        }
        $ParentToolchains = Join-Path $ScoopSwiftAppDir "Toolchains"
        $CurrentToolchains = Join-Path $ScoopSwiftRoot "Toolchains"
        if ((Test-Path $CurrentToolchains) -and (-not (Test-Path $ParentToolchains))) {
            New-Item -ItemType Junction -Path $ParentToolchains -Target $CurrentToolchains -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        # Ignore junction creation errors; --build-system native below does not require them.
    }
}

$SwiftCmd = Get-Command swift.exe -ErrorAction SilentlyContinue
if (-not $SwiftCmd) {
    throw "swift.exe not found on PATH or in Scoop ($ScoopSwiftRoot). Install via 'scoop install swift'."
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

# Use '--build-system native' to bypass Swift 6.4's SwiftBuild toolchain path bug on Scoop
$BuildArgs = @("--build-system", "native", "-c", $Configuration)

# Compile the Explorer/taskbar/window icon into the executable.
$RcPath = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter rc.exe -Recurse |
    Where-Object { $_.Directory.Name -eq "x64" } | Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $RcPath) { throw "Windows SDK resource compiler (rc.exe) not found" }
New-Item -ItemType Directory -Force (Join-Path $ScriptDir ".build") | Out-Null
$IconResource = Join-Path $ScriptDir ".build\Overlook.res"
& $RcPath /nologo /I (Join-Path $ScriptDir "packaging") /fo $IconResource (Join-Path $ScriptDir "packaging\Overlook.rc")
if ($LASTEXITCODE -ne 0) { throw "Icon resource compilation failed" }
$BuildArgs += @("-Xlinker", $IconResource)

# 4. Build Overlook
Write-Host "==> Building Overlook ($Configuration)..." -ForegroundColor Cyan
& swift build @BuildArgs
if ($LASTEXITCODE -ne 0) {
    throw "swift build failed with exit code $LASTEXITCODE"
}

$BinDir = (& swift build @BuildArgs --show-bin-path).Trim()
$ExePath = Join-Path $BinDir "Overlook.exe"

# Embed application manifest if mt.exe is available
$ManifestPath = Join-Path $ScriptDir "packaging\Overlook.exe.manifest"
$MtCmd = Get-Command mt.exe -ErrorAction SilentlyContinue
if (-not $MtCmd) {
    # Scoop shells can find Swift without importing the Windows SDK bin folder.
    $SdkBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $MtPath = Get-ChildItem -Path $SdkBin -Filter mt.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq "x64" } |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if ($MtPath) { $MtCmd = Get-Command $MtPath }
}
if ($MtCmd -and (Test-Path $ExePath) -and (Test-Path $ManifestPath)) {
    Write-Host "    Embedding Per-Monitor V2 DPI manifest into Overlook.exe" -ForegroundColor Gray
    & $MtCmd.Source -nologo -manifest $ManifestPath -outputresource:"$ExePath;#1"
    if ($LASTEXITCODE -ne 0) { throw "Application manifest embedding failed ($LASTEXITCODE)" }
}

# 5. Run unit tests if requested
if ($Test) {
    Write-Host "==> Running OverlookCoreTests..." -ForegroundColor Cyan
    & swift test @BuildArgs
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

    # Copy Swift runtime DLLs from Scoop (Runtimes\usr\bin or Toolchains\usr\bin)
    $RuntimeCandidateDirs = @(
        (Join-Path $ScoopSwiftRoot "Runtimes\usr\bin"),
        (Join-Path $ScoopSwiftRoot "Toolchains\usr\bin"),
        (Join-Path $ScoopSwiftRoot "usr\bin")
    )
    foreach ($rtDir in $RuntimeCandidateDirs) {
        if (Test-Path $rtDir) {
            foreach ($pattern in @("swift*.dll", "BlocksRuntime.dll", "dispatch.dll", "Foundation*.dll", "_Foundation*.dll")) {
                Get-ChildItem -Path $rtDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item -Force $_.FullName $DistRoot
                }
            }
        }
    }

    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    Compress-Archive -Path "$DistRoot\*" -DestinationPath $ZipPath
    Write-Host "==> Packaged portable archive: $ZipPath" -ForegroundColor Green
}

Write-Host "==> Done! Binary: $ExePath" -ForegroundColor Green
