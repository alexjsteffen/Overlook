<#
.SYNOPSIS
    Builds, tests, and packages the native Win32 / Fluent / GStreamer Overlook client on Windows.
.DESCRIPTION
    Supports Swift 6.x installed via Scoop ($env:USERPROFILE\scoop\apps\swift\current)
    or the official Swift for Windows installer, Visual Studio 2022+ C++ tools,
    and GStreamer 1.0 MSVC x86_64 (runtime + devel).
.PARAMETER Configuration
    Build configuration: 'debug' or 'release' (default: 'release').
.PARAMETER Version
    Three- or four-part numeric version embedded into Overlook.exe version info (default: '1.0.2').
.PARAMETER GStreamerRoot
    Optional path to the GStreamer 1.0 MSVC x86_64 installation root.
.PARAMETER Test
    Run OverlookCoreTests unit tests after building.
.PARAMETER SmokeTest
    Run Overlook.exe smoke tests (--certificate-response-smoke-test, --sidebar-smoke-test, --native-smoke-test, --smoke-test, --capture-smoke-test).
.PARAMETER Package
    Stage a self-contained portable distribution in dist\Overlook-Windows-x64 and zip it.
#>
[CmdletBinding()]
param(
    [ValidateSet("debug", "release")]
    [string]$Configuration = "release",
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
    [string]$Version = "1.0.2",
    [string]$GStreamerRoot = "",
    [switch]$Test,
    [switch]$SmokeTest,
    [switch]$Package
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $ScriptDir
try {
    Write-Host "==> Overlook Windows Build (Native Win32 + Swift + GStreamer WebRTC)" -ForegroundColor Cyan

    # 1. Locate Swift (Scoop or system PATH) & repair Scoop's flattened Swift 6.4+ layout
    $ScoopSwiftAppDir = Join-Path $env:USERPROFILE "scoop\apps\swift"
    $ScoopSwiftRoot   = Join-Path $ScoopSwiftAppDir "current"

    if (Test-Path -LiteralPath $ScoopSwiftRoot) {
        $ScoopToolchainBin = Join-Path $ScoopSwiftRoot "Toolchains\usr\bin"
        $ScoopRuntimeBin   = Join-Path $ScoopSwiftRoot "Runtimes\usr\bin"
        $ScoopLegacyBin    = Join-Path $ScoopSwiftRoot "usr\bin"
        $ScoopSdkRoot      = Join-Path $ScoopSwiftRoot "Platforms\Windows.platform\Developer\SDKs\Windows.sdk"

        foreach ($binDir in @($ScoopRuntimeBin, $ScoopToolchainBin, $ScoopLegacyBin)) {
            if ((Test-Path -LiteralPath $binDir) -and ($env:PATH -notlike "*$binDir*")) {
                $env:PATH = "$binDir;$env:PATH"
            }
        }

        if ((Test-Path -LiteralPath $ScoopSdkRoot) -and (-not $env:SDKROOT)) {
            $env:SDKROOT = $ScoopSdkRoot
            Write-Host "    Set SDKROOT: $env:SDKROOT" -ForegroundColor Gray
        }

        try {
            $ParentPlatforms = Join-Path $ScoopSwiftAppDir "Platforms"
            $CurrentPlatforms = Join-Path $ScoopSwiftRoot "Platforms"
            if ((Test-Path -LiteralPath $CurrentPlatforms) -and (-not (Test-Path -LiteralPath $ParentPlatforms))) {
                New-Item -ItemType Junction -Path $ParentPlatforms -Target $CurrentPlatforms -ErrorAction SilentlyContinue | Out-Null
            }
            $AssertsDir = Join-Path $ScoopSwiftRoot "Toolchains\0.0.0+Asserts"
            $AssertsUsr = Join-Path $AssertsDir "usr"
            $CurrentUsr = Join-Path $ScoopSwiftRoot "Toolchains\usr"
            if ((Test-Path -LiteralPath $CurrentUsr) -and (-not (Test-Path -LiteralPath $AssertsUsr))) {
                New-Item -ItemType Directory -Force -Path $AssertsDir -ErrorAction SilentlyContinue | Out-Null
                New-Item -ItemType Junction -Path $AssertsUsr -Target $CurrentUsr -ErrorAction SilentlyContinue | Out-Null
            }
            $ParentToolchains = Join-Path $ScoopSwiftAppDir "Toolchains"
            $CurrentToolchains = Join-Path $ScoopSwiftRoot "Toolchains"
            if ((Test-Path -LiteralPath $CurrentToolchains) -and (-not (Test-Path -LiteralPath $ParentToolchains))) {
                New-Item -ItemType Junction -Path $ParentToolchains -Target $CurrentToolchains -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            # Ignore junction errors; --build-system native below does not require them.
        }
    }

    $SwiftCmd = Get-Command swift.exe -ErrorAction SilentlyContinue
    if (-not $SwiftCmd) {
        throw "swift.exe not found on PATH or in Scoop ($ScoopSwiftRoot). Install via 'scoop install swift'."
    }
    Write-Host "    Using Swift: $($SwiftCmd.Source)" -ForegroundColor Gray
    & $SwiftCmd.Source --version

    # 2. Ensure Visual Studio C++ & Windows SDK environment is active
    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if ((Test-Path -LiteralPath $VsWhere) -and (-not $env:WindowsSdkDir)) {
        $VsInstallDir = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $VsInstallDir) {
            $VsInstallDir = & $VsWhere -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        }
        if ($VsInstallDir) {
            $VcVars = Join-Path $VsInstallDir "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path -LiteralPath $VcVars) {
                Write-Host "    Importing Visual Studio x64 environment from $VcVars" -ForegroundColor Gray
                cmd /c "`"$VcVars`" >nul && set" | ForEach-Object {
                    if ($_ -match "^([^=]+)=(.*)$") {
                        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
                    }
                }
            }
        }
    }

    # 3. Locate GStreamer 1.0 MSVC x86_64 SDK (runtime + devel)
    $GstCandidates = [System.Collections.Generic.List[string]]::new()
    if ($GStreamerRoot) { $GstCandidates.Add($GStreamerRoot) }
    if ($env:GSTREAMER_1_0_ROOT_MSVC_X86_64) { $GstCandidates.Add($env:GSTREAMER_1_0_ROOT_MSVC_X86_64) }
    if ($env:GSTREAMER_1_0_ROOT_X86_64) { $GstCandidates.Add($env:GSTREAMER_1_0_ROOT_X86_64) }
    $GstCandidates.Add("C:\Program Files\gstreamer\1.0\msvc_x86_64")
    $GstCandidates.Add("C:\gstreamer\1.0\msvc_x86_64")
    $GstCandidates.Add((Join-Path $ScriptDir ".deps\gstreamer\PFiles64\gstreamer\1.0\msvc_x86_64"))
    $GstCandidates.Add((Join-Path $ScriptDir ".deps\gstreamer\gstreamer\1.0\msvc_x86_64"))
    $GstCandidates.Add((Join-Path $ScriptDir ".deps\gstreamer\1.0\msvc_x86_64"))

    $ResolvedGstRoot = $null
    foreach ($candidate in $GstCandidates) {
        if (-not $candidate) { continue }
        $norm = $candidate.TrimEnd('\')
        if ((Test-Path -LiteralPath (Join-Path $norm "include\gstreamer-1.0\gst\webrtc\webrtc.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "include\glib-2.0\glib.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\glib-2.0\include\glibconfig.h")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\gstreamer-1.0.lib")) -and
            (Test-Path -LiteralPath (Join-Path $norm "lib\gstreamer-1.0\gstwebrtc.dll"))) {
            $ResolvedGstRoot = $norm
            break
        }
    }
    if (-not $ResolvedGstRoot) {
        throw "GStreamer 1.0 MSVC x86_64 runtime + devel SDK not found. Install both gstreamer-1.0-msvc-x86_64 and gstreamer-1.0-devel-msvc-x86_64 or pass -GStreamerRoot <path>."
    }
    Write-Host "    Using GStreamer: $ResolvedGstRoot" -ForegroundColor Gray

    $GstInc     = Join-Path $ResolvedGstRoot "include\gstreamer-1.0"
    $GlibInc    = Join-Path $ResolvedGstRoot "include\glib-2.0"
    $GlibCfgInc = Join-Path $ResolvedGstRoot "lib\glib-2.0\include"
    $GstLib     = Join-Path $ResolvedGstRoot "lib"
    $GstBin     = Join-Path $ResolvedGstRoot "bin"
    $GstPlugins = Join-Path $ResolvedGstRoot "lib\gstreamer-1.0"

    # 4. Sync shared OverlookCore sources from ..\Linux if present
    $LinuxCore = Join-Path $ScriptDir "..\Linux\Sources\OverlookCore"
    $WinCore = Join-Path $ScriptDir "Sources\OverlookCore"
    if (Test-Path -LiteralPath $LinuxCore) {
        New-Item -ItemType Directory -Force -Path $WinCore | Out-Null
        Copy-Item -Force (Join-Path $LinuxCore "*.swift") $WinCore
    }
    $LinuxTests = Join-Path $ScriptDir "..\Linux\Tests\OverlookCoreTests"
    $WinTests = Join-Path $ScriptDir "Tests\OverlookCoreTests"
    if (Test-Path -LiteralPath $LinuxTests) {
        New-Item -ItemType Directory -Force -Path $WinTests | Out-Null
        Copy-Item -Force (Join-Path $LinuxTests "*.swift") $WinTests
    }

    # 5. Compile icon, manifest, and version resource into .build\Overlook.res
    $RcPath = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter rc.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq "x64" } | Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $RcPath) { throw "Windows SDK resource compiler (rc.exe) not found" }

    $VerObj = [version]$Version
    $VerMajor = $VerObj.Major
    $VerMinor = $VerObj.Minor
    $VerPatch = $VerObj.Build
    $VerRev = [Math]::Max(0, $VerObj.Revision)

    New-Item -ItemType Directory -Force (Join-Path $ScriptDir ".build") | Out-Null
    $IconResource = Join-Path $ScriptDir ".build\Overlook.res"
    & $RcPath /nologo /I (Join-Path $ScriptDir "packaging") `
        /d "OL_VER_MAJOR=$VerMajor" /d "OL_VER_MINOR=$VerMinor" /d "OL_VER_PATCH=$VerPatch" /d "OL_VER_REV=$VerRev" /d "OL_VER_RAW=$Version" `
        /fo $IconResource (Join-Path $ScriptDir "packaging\Overlook.rc")
    if ($LASTEXITCODE -ne 0) { throw "Windows resource compilation failed" }

    $CommonSwiftArgs = @("--build-system", "native", "-c", $Configuration)
    $GstCompileArgs = @(
        "-Xcc", "-I$GstInc",
        "-Xcc", "-I$GlibInc",
        "-Xcc", "-I$GlibCfgInc",
        "-Xlinker", "/LIBPATH:$GstLib"
    )
    $BuildArgs = $CommonSwiftArgs + $GstCompileArgs + @(
        "-Xlinker", $IconResource,
        "-Xlinker", "/SUBSYSTEM:WINDOWS",
        "-Xlinker", "/ENTRY:mainCRTStartup"
    )
    $TestArgs = $CommonSwiftArgs + $GstCompileArgs

    $BinDir = (& $SwiftCmd.Source build @CommonSwiftArgs --show-bin-path).Trim()
    $ExePath = Join-Path $BinDir "Overlook.exe"

    # 6. Run unit tests before the final GUI link so `swift test` cannot overwrite Overlook.exe with CUI/empty-resource defaults
    if ($Test) {
        Write-Host "==> Running OverlookCoreTests..." -ForegroundColor Cyan
        & $SwiftCmd.Source test @TestArgs
        if ($LASTEXITCODE -ne 0) {
            throw "swift test failed with exit code $LASTEXITCODE"
        }
        if (Test-Path -LiteralPath $ExePath) {
            Remove-Item -LiteralPath $ExePath -Force
        }
    }

    # 7. Build Overlook (GUI subsystem + embedded icon/manifest/version resource)
    Write-Host "==> Building Overlook ($Configuration)..." -ForegroundColor Cyan
    & $SwiftCmd.Source build @BuildArgs --product Overlook
    if ($LASTEXITCODE -ne 0) {
        throw "swift build failed with exit code $LASTEXITCODE"
    }

    # Remove obsolete Python WebRTC runtime directory if present
    $LegacyWebRtcDir = Join-Path $BinDir "webrtc"
    if (Test-Path -LiteralPath $LegacyWebRtcDir) {
        Remove-Item -LiteralPath $LegacyWebRtcDir -Recurse -Force
    }

    # Build runtime DLL search paths (GStreamer bin -> Swift runtimes -> MSVC CRT redist)
    $SwiftBinDir = Split-Path -Parent $SwiftCmd.Source
    $SwiftInstallRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $SwiftBinDir))
    $DllSearchDirs = [System.Collections.Generic.List[string]]::new()
    $DllSearchDirs.Add($GstBin)
    foreach ($cand in @(
        (Join-Path $ScoopSwiftRoot "Runtimes\usr\bin"),
        (Join-Path $ScoopSwiftRoot "Toolchains\usr\bin"),
        (Join-Path $ScoopSwiftRoot "usr\bin"),
        $SwiftBinDir
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand) -and (-not $DllSearchDirs.Contains($cand))) {
            $DllSearchDirs.Add($cand)
        }
    }
    if (Test-Path -LiteralPath (Join-Path $SwiftInstallRoot "Runtimes")) {
        Get-ChildItem -LiteralPath (Join-Path $SwiftInstallRoot "Runtimes") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $rtUsrBin = Join-Path $_.FullName "usr\bin"
            if ((Test-Path -LiteralPath $rtUsrBin) -and (-not $DllSearchDirs.Contains($rtUsrBin))) {
                $DllSearchDirs.Add($rtUsrBin)
            }
        }
    }
    if ($env:VCToolsRedistDir) {
        Get-ChildItem -LiteralPath (Join-Path $env:VCToolsRedistDir "x64") -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $DllSearchDirs.Contains($_.FullName)) {
                $DllSearchDirs.Add($_.FullName)
            }
        }
    }

    $ObjDump = Get-Command llvm-objdump.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $ObjDump) {
        $CandidateObjDump = Join-Path $SwiftBinDir "llvm-objdump.exe"
        if (Test-Path -LiteralPath $CandidateObjDump) { $ObjDump = $CandidateObjDump }
    }
    $DumpBin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $ObjDump -and -not $DumpBin) {
        throw "Neither llvm-objdump.exe nor dumpbin.exe found to resolve runtime DLL dependencies."
    }

    function Get-DirectDllImports {
        param([string]$BinaryPath)
        $imports = [System.Collections.Generic.List[string]]::new()
        if ($ObjDump) {
            $out = & $ObjDump -p $BinaryPath 2>$null
            foreach ($line in $out) {
                if ($line -match 'DLL Name:\s*(\S+)') { $imports.Add($matches[1]) }
            }
        } else {
            $out = & $DumpBin /nologo /dependents $BinaryPath 2>$null
            foreach ($line in $out) {
                if ($line -match '^\s+([A-Za-z0-9_.\-+]+\.dll)\s*$') { $imports.Add($matches[1]) }
            }
        }
        return $imports
    }

    function Stage-RuntimeDependencies {
        param([string]$TargetDir, [string]$TargetExe)
        $RequiredPlugins = @(
            "gstcoreelements.dll", "gstapp.dll", "gstplayback.dll", "gsttypefindfunctions.dll",
            "gstautodetect.dll", "gstwebrtc.dll", "gstnice.dll", "gstdtls.dll", "gstsrtp.dll",
            "gstrtp.dll", "gstrtpmanager.dll", "gstudp.dll", "gstvideoconvertscale.dll",
            "gstvideoparsersbad.dll", "gstvpx.dll", "gstopenh264.dll", "gstisomp4.dll",
            "gstvideotestsrc.dll"
        )
        $OptionalPlugins = @(
            "gstd3d11.dll", "gstmediafoundation.dll", "gstlibav.dll", "gstsctp.dll", "gstx264.dll"
        )

        $PluginTarget = Join-Path $TargetDir "gstreamer-plugins"
        if (Test-Path -LiteralPath $PluginTarget) {
            Remove-Item -LiteralPath $PluginTarget -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $PluginTarget | Out-Null

        foreach ($p in $RequiredPlugins) {
            $src = Join-Path $GstPlugins $p
            if (-not (Test-Path -LiteralPath $src)) {
                throw "Missing required GStreamer plugin: $src"
            }
            Copy-Item -Force $src $PluginTarget
        }
        foreach ($p in $OptionalPlugins) {
            $src = Join-Path $GstPlugins $p
            if (Test-Path -LiteralPath $src) {
                Copy-Item -Force $src $PluginTarget
            }
        }

        $queue = [System.Collections.Generic.Queue[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue.Enqueue($TargetExe)
        Get-ChildItem -LiteralPath $PluginTarget -Filter "*.dll" | ForEach-Object {
            $queue.Enqueue($_.FullName)
        }

        $copiedCount = 0
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            foreach ($dllName in (Get-DirectDllImports -BinaryPath $current)) {
                if (-not $seen.Add($dllName)) { continue }
                foreach ($searchDir in $DllSearchDirs) {
                    $candidate = Join-Path $searchDir $dllName
                    if (Test-Path -LiteralPath $candidate) {
                        Copy-Item -Force $candidate $TargetDir
                        $queue.Enqueue($candidate)
                        $copiedCount++
                        break
                    }
                }
            }
        }
        Write-Host "    Staged $copiedCount runtime DLLs and $((Get-ChildItem -LiteralPath $PluginTarget -Filter '*.dll').Count) GStreamer plugins into $TargetDir" -ForegroundColor Gray
    }

    Stage-RuntimeDependencies -TargetDir $BinDir -TargetExe $ExePath

    function Invoke-OverlookSmokeTest {
        param([string]$Executable, [string[]]$Arguments)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Executable, ($Arguments -join ' '))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor Yellow }
        if ($proc.ExitCode -ne 0) {
            throw "Smoke test ($($Arguments -join ' ')) failed with exit code $($proc.ExitCode)"
        }
    }

    # 8. Run smoke tests if requested
    if ($SmokeTest -and (Test-Path -LiteralPath $ExePath)) {
        Write-Host "==> Running Overlook smoke tests..." -ForegroundColor Cyan
        Invoke-OverlookSmokeTest -Executable $ExePath -Arguments @("--certificate-response-smoke-test")
        Invoke-OverlookSmokeTest -Executable $ExePath -Arguments @("--sidebar-smoke-test")
        Invoke-OverlookSmokeTest -Executable $ExePath -Arguments @("--native-smoke-test")
        Invoke-OverlookSmokeTest -Executable $ExePath -Arguments @("--smoke-test")
        Invoke-OverlookSmokeTest -Executable $ExePath -Arguments @("--capture-smoke-test", "--non-interactive")
    }

    # 9. Stage portable distribution if requested
    if ($Package) {
        $DistRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\dist\Overlook-Windows-x64"))
        $ZipPath  = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\dist\Overlook-Windows-x64.zip"))
        $ExpectedDistParent = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\dist"))
        if ([System.IO.Path]::GetDirectoryName($DistRoot) -ne $ExpectedDistParent) {
            throw "Unexpected distribution path: $DistRoot"
        }

        Write-Host "==> Staging distribution in $DistRoot..." -ForegroundColor Cyan
        if (Test-Path -LiteralPath $DistRoot) { Remove-Item -LiteralPath $DistRoot -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $DistRoot | Out-Null

        Copy-Item -Force $ExePath $DistRoot
        Stage-RuntimeDependencies -TargetDir $DistRoot -TargetExe (Join-Path $DistRoot "Overlook.exe")

        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        Compress-Archive -Path "$DistRoot\*" -DestinationPath $ZipPath
        Write-Host "==> Packaged portable archive: $ZipPath" -ForegroundColor Green
    }

    Write-Host "==> Done! Binary: $ExePath" -ForegroundColor Green
} finally {
    Pop-Location
}
