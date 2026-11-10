<#
.SYNOPSIS
Checks dependencies, compiles Overlook, and creates a per-user NSIS installer.
.EXAMPLE
.\Windows\build-installer.ps1 -CheckOnly
.EXAMPLE
.\Windows\build-installer.ps1 -Test -Version 1.0.2
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')][string]$Version = '1.0.2',
    [string]$PythonExecutable = 'python.exe',
    [switch]$CheckOnly,
    [switch]$SkipBuild,
    [switch]$Test,
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
$InstallerScriptDir = $PSScriptRoot
$RepositoryDir = Split-Path -Parent $InstallerScriptDir
$DependencyChecks = [System.Collections.Generic.List[object]]::new()
function Add-DependencyCheck($Name, $Passed, $Detail, $Fix) {
    $DependencyChecks.Add([pscustomobject]@{ Name=$Name; Passed=[bool]$Passed; Detail=$Detail; Fix=$Fix })
}
function Find-BuildTool($Name, $Candidates) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    return $null
}
Add-DependencyCheck '64-bit Windows / PowerShell 5.1+' ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitProcess -and $PSVersionTable.PSVersion -ge [version]'5.1') $PSVersionTable.PSVersion 'Use 64-bit PowerShell on Windows.'
$NsisCompiler = Find-BuildTool 'makensis.exe' @(
    "$env:USERPROFILE\scoop\apps\nsis\current\makensis.exe",
    "${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe")
$NsisVersion = if ($NsisCompiler) { & $NsisCompiler /VERSION } else { '' }
Add-DependencyCheck 'NSIS 3 compiler' ($NsisCompiler -and $NsisVersion -match '^v?3\.') "$NsisCompiler $NsisVersion" 'Install NSIS 3: scoop bucket add extras; scoop install nsis (or use the NSIS installer).'
if (-not $SkipBuild) {
    $SwiftCompiler = Find-BuildTool 'swift.exe' @("$env:USERPROFILE\scoop\apps\swift\current\Toolchains\usr\bin\swift.exe")
    Add-DependencyCheck 'Swift for Windows' $SwiftCompiler $SwiftCompiler 'Install Swift 6: scoop install swift'
    $VsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $VsInstallPath = $null
    if (Test-Path -LiteralPath $VsWherePath) {
        $VsInstallPath = & $VsWherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $VsInstallPath) { $VsInstallPath = & $VsWherePath -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath }
    }
    $VcVarsPath = if ($VsInstallPath) { Join-Path $VsInstallPath 'VC\Auxiliary\Build\vcvars64.bat' } else { $null }
    Add-DependencyCheck 'Visual Studio C++ x64 tools' ($VcVarsPath -and (Test-Path -LiteralPath $VcVarsPath)) $VsInstallPath 'Install Visual Studio 2022 / Build Tools with Desktop development with C++ and MSVC x64/x86 tools.'
    $SdkBinDir = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $SdkVersions = @(Get-ChildItem -LiteralPath $SdkBinDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($tool in @('rc.exe', 'mt.exe')) {
        $SdkTool = Find-BuildTool $tool @($SdkVersions | ForEach-Object { Join-Path $_.FullName "x64\$tool" })
        Add-DependencyCheck "Windows SDK $tool" $SdkTool $SdkTool 'In Visual Studio Installer, add a Windows 10/11 SDK with the x64 resource and manifest tools.'
    }
    $PythonCompiler = Find-BuildTool $PythonExecutable @()
    $PythonStatus = $null
    if ($PythonCompiler) {
        $PythonProbe = @'
import importlib, importlib.metadata, json, struct, sys
missing = []
for module, distribution, expected in [('aiortc', 'aiortc', '1.14.0'), ('PyInstaller', 'pyinstaller', '6.16.0')]:
    try:
        importlib.import_module(module)
        found = importlib.metadata.version(distribution)
        if found != expected: missing.append(f'{distribution}=={expected} (found {found})')
    except Exception as exc:
        missing.append(f'{distribution}=={expected}: {exc}')
print(json.dumps(dict(version=sys.version.split()[0], executable=sys.executable, supported=(3,10) <= sys.version_info[:2] < (3,15) and struct.calcsize('P') == 8, missing=missing)))
'@
        try {
            $PythonOutput = & $PythonCompiler -c $PythonProbe 2>$null
            if ($LASTEXITCODE -eq 0) { $PythonStatus = $PythonOutput | ConvertFrom-Json }
        } catch { $PythonStatus = $null }
    }
    Add-DependencyCheck '64-bit Python 3.10-3.14' ($PythonStatus -and $PythonStatus.supported) "$PythonCompiler $($PythonStatus.version)" 'The pinned PyInstaller requires Python <3.15. Install a 64-bit Python 3.10-3.14 and select it with -PythonExecutable <path> (Scoop: scoop bucket add versions; scoop install python314).'
    Add-DependencyCheck 'Python WebRTC / bundler dependencies' ($PythonStatus -and $PythonStatus.missing.Count -eq 0) ($PythonStatus.missing -join '; ') "Install requirements with that interpreter: & '$PythonCompiler' -m pip install -r Windows/Helpers/requirements.txt. Select another interpreter with -PythonExecutable <path>."
    $RunningApp = @(Get-Process Overlook, overlook-webrtc -ErrorAction SilentlyContinue)
    Add-DependencyCheck 'App closed before rebuild' ($RunningApp.Count -eq 0) "$($RunningApp.Count) running processes" 'Close Overlook and its video session before rebuilding.'
}
Write-Host 'Overlook installer dependency check' -ForegroundColor Cyan
foreach ($check in $DependencyChecks) {
    if ($check.Passed) { Write-Host "[OK] $($check.Name) $($check.Detail)" -ForegroundColor Green }
    else { Write-Host "[MISSING] $($check.Name) $($check.Detail)`n  $($check.Fix)" -ForegroundColor Yellow }
}
$MissingChecks = @($DependencyChecks | Where-Object { -not $_.Passed })
if ($MissingChecks.Count) { throw "$($MissingChecks.Count) prerequisite check(s) failed. Install or fix the items listed above, then rerun." }
if ($CheckOnly) { return }
$NumericVersion = [version]$Version
$VersionParts = @($NumericVersion.Major, $NumericVersion.Minor, $NumericVersion.Build, [Math]::Max(0, $NumericVersion.Revision))
if (@($VersionParts | Where-Object { $_ -gt 65535 }).Count) { throw 'Each version component must be between 0 and 65535.' }
$FileVersion = $VersionParts -join '.'
Push-Location $RepositoryDir
$OriginalBuildPath = $env:PATH
try {
    if (-not $SkipBuild) {
        # The child build must use the same interpreter that passed preflight,
        # even when multiple Scoop Python installations are on the machine.
        $env:PATH = "$(Split-Path -Parent $PythonStatus.executable);$env:PATH"
        & (Join-Path $InstallerScriptDir 'build.ps1') -Configuration $Configuration -Test:$Test -SmokeTest:$SmokeTest -Package
    }
    $PayloadDir = Join-Path $RepositoryDir 'dist\Overlook-Windows-x64'
    foreach ($required in @('Overlook.exe', 'swiftCore.dll', 'Foundation.dll', 'webrtc\overlook-webrtc.exe', 'webrtc\_internal\base_library.zip')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PayloadDir $required))) { throw "Missing packaged file: $required. Run without -SkipBuild to compile a complete payload." }
    }
    if (-not (Get-ChildItem -LiteralPath (Join-Path $PayloadDir 'webrtc\_internal') -Filter 'python3*.dll')) { throw 'The packaged WebRTC Python runtime DLL is missing.' }
    $InstallerWorkDir = Join-Path $InstallerScriptDir '.build\installer'
    New-Item -ItemType Directory -Force -Path $InstallerWorkDir | Out-Null
    # Delete only owned files; preserve arbitrary user-added files during uninstall.
    $UninstallManifest = Join-Path $InstallerWorkDir 'uninstall-files.nsh'
    $UninstallLines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $PayloadDir -File -Recurse)) {
        $relative = $file.FullName.Substring($PayloadDir.Length + 1).Replace('$', '$$').Replace('"', '$\"')
        $UninstallLines.Add('Delete "$INSTDIR\app\' + $relative + '"')
    }
    foreach ($directory in (Get-ChildItem -LiteralPath $PayloadDir -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending)) {
        $relative = $directory.FullName.Substring($PayloadDir.Length + 1).Replace('$', '$$').Replace('"', '$\"')
        $UninstallLines.Add('RMDir "$INSTDIR\app\' + $relative + '"')
    }
    $UninstallLines.Add('RMDir "$INSTDIR\app"')
    [System.IO.File]::WriteAllLines($UninstallManifest, $UninstallLines, [System.Text.UTF8Encoding]::new($false))
    $InstallerOutput = Join-Path $RepositoryDir "dist\Overlook-$Version-Windows-x64-Setup.exe"
    & $NsisCompiler /V3 "/DAPP_VERSION=$Version" "/DFILE_VERSION=$FileVersion" "/DPAYLOAD_DIR=$PayloadDir" "/DUNINSTALL_MANIFEST=$UninstallManifest" "/DINSTALLER_OUTPUT=$InstallerOutput" (Join-Path $InstallerScriptDir 'packaging\Overlook.nsi')
    if ($LASTEXITCODE -ne 0) { throw "NSIS compilation failed ($LASTEXITCODE)." }
    Write-Host "Installer ready: $InstallerOutput" -ForegroundColor Green
    Write-Host 'This installer is unsigned. It includes the Swift and WebRTC runtimes; users do not need Python or Swift installed.'
} finally { $env:PATH = $OriginalBuildPath; Pop-Location }
