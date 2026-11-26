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
    [string]$GStreamerRoot = '',
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
    $DependencyChecks.Add([pscustomobject]@{ Name = $Name; Passed = [bool]$Passed; Detail = $Detail; Fix = $Fix })
}

function Find-BuildTool($Name, $Candidates) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Find-WorkingNsisCompiler {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add("$env:USERPROFILE\scoop\apps\nsis\current\makensis.exe")
    $cmd = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }
    $candidates.Add("${env:ProgramFiles(x86)}\NSIS\makensis.exe")
    $candidates.Add("$env:ProgramFiles\NSIS\makensis.exe")

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not $seen.Add($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $versions = @(& $candidate /VERSION 2>$null)
            if ($LASTEXITCODE -eq 0 -and $versions.Count -gt 0 -and $versions[0] -match '^v?3\.') {
                return [pscustomobject]@{ Path = $candidate; Version = $versions[0].Trim() }
            }
        } catch {
        }
    }
    return $null
}

function Resolve-GStreamerSdkRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($GStreamerRoot) { $candidates.Add($GStreamerRoot) }
    if ($env:GSTREAMER_1_0_ROOT_MSVC_X86_64) { $candidates.Add($env:GSTREAMER_1_0_ROOT_MSVC_X86_64) }
    if ($env:GSTREAMER_1_0_ROOT_X86_64) { $candidates.Add($env:GSTREAMER_1_0_ROOT_X86_64) }
    $candidates.Add("C:\Program Files\gstreamer\1.0\msvc_x86_64")
    $candidates.Add("C:\gstreamer\1.0\msvc_x86_64")
    $candidates.Add((Join-Path $InstallerScriptDir ".deps\gstreamer\PFiles64\gstreamer\1.0\msvc_x86_64"))
    $candidates.Add((Join-Path $InstallerScriptDir ".deps\gstreamer\gstreamer\1.0\msvc_x86_64"))
    $candidates.Add((Join-Path $InstallerScriptDir ".deps\gstreamer\1.0\msvc_x86_64"))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $norm = $candidate.TrimEnd('\')
        if ((Test-Path -LiteralPath (Join-Path $norm "include\gstreamer-1.0\gst\webrtc\webrtc.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "include\glib-2.0\glib.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\glib-2.0\include\glibconfig.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\gstreamer-1.0.lib")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\gstreamer-1.0\gstwebrtc.dll"))) {
            return $norm
        }
    }
    return $null
}

Add-DependencyCheck '64-bit Windows / PowerShell 5.1+' ($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitProcess -and $PSVersionTable.PSVersion -ge [version]'5.1') $PSVersionTable.PSVersion 'Use 64-bit PowerShell on Windows.'

$NsisInfo = Find-WorkingNsisCompiler
$NsisCompiler = if ($NsisInfo) { $NsisInfo.Path } else { $null }
$NsisDetail = if ($NsisInfo) { "$($NsisInfo.Path) $($NsisInfo.Version)" } else { '' }
Add-DependencyCheck 'NSIS 3 compiler' ($null -ne $NsisInfo) $NsisDetail 'Install NSIS 3: scoop bucket add extras; scoop install nsis (or use the official NSIS 3 installer).'

$ResolvedGstRoot = $null
if (-not $SkipBuild) {
    $SwiftCompiler = Find-BuildTool 'swift.exe' @("$env:USERPROFILE\scoop\apps\swift\current\Toolchains\usr\bin\swift.exe")
    Add-DependencyCheck 'Swift for Windows' $SwiftCompiler $SwiftCompiler 'Install Swift 6: scoop install swift'

    $VsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $VsInstallPath = $null
    if (Test-Path -LiteralPath $VsWherePath) {
        $VsInstallPath = & $VsWherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $VsInstallPath) {
            $VsInstallPath = & $VsWherePath -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        }
    }
    $VcVarsPath = if ($VsInstallPath) { Join-Path $VsInstallPath 'VC\Auxiliary\Build\vcvars64.bat' } else { $null }
    Add-DependencyCheck 'Visual Studio C++ x64 tools' ($VcVarsPath -and (Test-Path -LiteralPath $VcVarsPath)) $VsInstallPath 'Install Visual Studio 2022 / Build Tools with Desktop development with C++ and MSVC x64/x86 tools.'

    $SdkBinDir = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $SdkVersions = @(Get-ChildItem -LiteralPath $SdkBinDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $RcTool = Find-BuildTool 'rc.exe' @($SdkVersions | ForEach-Object { Join-Path $_.FullName "x64\rc.exe" })
    Add-DependencyCheck 'Windows SDK rc.exe' $RcTool $RcTool 'In Visual Studio Installer, add a Windows 10/11 SDK with the x64 resource compiler.'

    $ResolvedGstRoot = Resolve-GStreamerSdkRoot
    Add-DependencyCheck 'GStreamer 1.0 MSVC x86_64 SDK' $ResolvedGstRoot $ResolvedGstRoot 'Install GStreamer 1.0 MSVC x86_64 runtime + devel MSIs (or pass -GStreamerRoot <path>).'

    $RunningApp = @(Get-Process Overlook -ErrorAction SilentlyContinue)
    Add-DependencyCheck 'App closed before rebuild' ($RunningApp.Count -eq 0) "$($RunningApp.Count) running processes" 'Close Overlook before rebuilding.'
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
try {
    if (-not $SkipBuild) {
        & (Join-Path $InstallerScriptDir 'build.ps1') -Configuration $Configuration -Version $Version -GStreamerRoot $ResolvedGstRoot -Test:$Test -SmokeTest:$SmokeTest -Package
    }
    $PayloadDir = [System.IO.Path]::GetFullPath((Join-Path $RepositoryDir 'dist\Overlook-Windows-x64'))
    foreach ($required in @(
        'Overlook.exe',
        'swiftCore.dll',
        'Foundation.dll',
        'VCRUNTIME140.dll',
        'gstreamer-1.0-0.dll',
        'gstreamer-plugins\gstwebrtc.dll',
        'gstreamer-plugins\gstnice.dll',
        'gstreamer-plugins\gstdtls.dll',
        'gstreamer-plugins\gstsrtp.dll'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $PayloadDir $required))) {
            throw "Missing packaged file: $required. Run without -SkipBuild to compile a complete payload."
        }
    }

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
    Write-Host 'This installer is unsigned. It includes the Swift and GStreamer WebRTC runtimes; users do not need Swift or GStreamer installed.'
} finally {
    Pop-Location
}
