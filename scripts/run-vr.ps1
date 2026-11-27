<#
.SYNOPSIS
  Launch Voices of the Void with -d3d11, inject UEVR (OpenXR) and collect logs after the game exits.

.DESCRIPTION
  Stage A test run (stereo + head tracking, existing controls, HUD on a floating panel).
  Nothing is written to the game folder. UEVR is injected at runtime; its profile lives in
  %APPDATA%\UnrealVRMod\VotV-Win64-Shipping. The repo baseline profile (profile\VotV-Win64-Shipping\config.txt)
  is copied there only when no profile config exists yet, or when -ResetProfile is given, so tweaks made
  in UEVR's in-game menu (which autosaves) survive between runs. Each run's logs land in logs\<timestamp>\.

  UEVRInjector 1.05 has one command-line flag, --attach=<process name> (found by reading the injector's
  strings, 2026-11-27). The runtime comes from Frontend_RequestedRuntime in the profile config and the
  OpenXR/OpenVR radio button in the injector window.

.EXAMPLE
  .\scripts\run-vr.ps1
  .\scripts\run-vr.ps1 -InjectDelaySeconds 30 -ResetProfile
#>
[CmdletBinding()]
param(
    [string]$GameDir = 'F:\Games\Voices of the Void',
    [string]$UevrDir = '',                     # default: <repo>\tools\UEVR\1.05\UEVR (set below; $PSScriptRoot is empty in param defaults under Windows PowerShell 5.1 -File)
    [ValidateSet('Bootstrap', 'Shipping')]
    [string]$LaunchExe = 'Bootstrap',          # Bootstrap = VotV.exe (forwards args), Shipping = the shipping exe directly
    [string[]]$GameArgs = @('-d3d11'),
    [int]$ProcessWaitSeconds = 90,             # bound: wait for VotV-Win64-Shipping to appear
    [int]$WindowWaitSeconds = 120,             # bound: wait for its main window
    [int]$InjectDelaySeconds = 15,             # extra settle time after the window appears, before injecting
    [int]$MaxRunMinutes = 0,                   # 0 = no limit; otherwise the game is closed after this long
    [string]$InjectorSettingsDir = 'UEVRInjector_Path_ykqoahobqtdhw1tefpiz54ewenoq31mv',  # this injector copy's saved-settings folder under %LOCALAPPDATA%\praydog
    [ValidateSet('OpenXR', 'OpenVR')]
    [string]$Runtime = 'OpenXR',               # OpenXR = Virtual Desktop (default, primary); OpenVR = SteamVR parallel test, this run only
    [string]$Feature = 'baseline',             # what this run tests (feature or issue name), for check-run.ps1 and the runtime matrix
    [int]$EyeCaptureEverySeconds = 20,         # SteamVR runs: both-eye mirror snap this often (0 = no eye capture)
    [int]$EyeCaptureFirstDelaySeconds = 30,    # after injection, before the first snap
    [int]$EyeCaptureMax = 30,                  # bound on snaps per run
    [switch]$LeaveSteamVR,                     # SteamVR runs: keep SteamVR open afterwards (default: close it if this run started it)
    [switch]$DisableVdOculusLayer,             # OpenXR runs: turn off Virtual Desktop's OculusXR compatibility API layer for the game (tried for the quit crash 2026-11-27: no effect, so off by default)
    [switch]$ResetProfile,
    [switch]$NoInject,                         # flat run with the same launch path, for A/B
    [switch]$Controls,                         # install the motion-controller plugin (votv_controls.dll) for this run (opt-in while under test)
    [switch]$LateInject,                       # start flat (menus via Virtual Desktop's own desktop laser), inject UEVR when F10 is pressed (or -LateInjectAfterSeconds)
    [int]$LateInjectTimeoutMinutes = 60,       # bound on the wait for F10
    [switch]$Pointer,                          # install the flat-menu laser pointer (votv_pointer.dll, menu thread) for this run (opt-in while under test)
    [switch]$NoMarks,                          # don't install the marks plugin (votv_marks.dll, on by default: left grip + right stick click or F8 drops a mark into <repo>\marks\; passive until pressed)
    [switch]$DryRun                            # run every pre-launch check and fix, then stop without launching
)

$ErrorActionPreference = 'Stop'
$procName   = 'VotV-Win64-Shipping'
$scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo       = (Resolve-Path (Join-Path $scriptDir '..')).Path
if (-not $UevrDir) { $UevrDir = Join-Path $repo 'tools\UEVR\1.05\UEVR' }
$profileDir = Join-Path $env:APPDATA "UnrealVRMod\$procName"
$baseline   = Join-Path $repo "profile\$procName\config.txt"
$stamp      = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$runDir     = Join-Path $repo "logs\$stamp"
New-Item -ItemType Directory -Force $runDir | Out-Null
$runLog     = Join-Path $runDir 'run.txt'

function Write-RunLog([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg
    Write-Host $line
    Add-Content -Path $runLog -Value $line -Encoding utf8
}

$injCfg = Join-Path $env:LOCALAPPDATA "praydog\$InjectorSettingsDir\1.0.0.0\user.config"
$profCfg = Join-Path $profileDir 'config.txt'

function Set-InjectorRadio([bool]$xr) {
    # Only this injector copy's settings file; never other UEVR installs.
    $x = [xml](Get-Content $injCfg -Raw)
    $changed = $false
    foreach ($s in $x.SelectNodes('//setting')) {
        $v = $null
        if ($s.name -eq 'OpenXRRadio') { $v = [string]$xr }
        if ($s.name -eq 'OpenVRRadio') { $v = [string](-not $xr) }
        if ($v -and $s.value -ne $v) { $s.value = $v; $changed = $true }
    }
    $name = if ($xr) { 'OpenXR' } else { 'OpenVR' }
    if ($changed) { $x.Save($injCfg); Write-RunLog "injector radio set to $name" } else { Write-RunLog "injector radio already $name" }
}

function Set-ProfileKey([string]$key, [string]$want) {
    $t = [System.IO.File]::ReadAllText($profCfg)
    $re = '(?m)^' + [regex]::Escape($key) + '=(.*)$'
    if ($t -match $re) {
        if ($Matches[1].Trim() -eq $want) { return }
        $t = [regex]::Replace($t, $re, "$key=$want")
    } else { $t = $t.TrimEnd() + "`r`n$key=$want`r`n" }
    [System.IO.File]::WriteAllText($profCfg, $t)
    Write-RunLog "profile $key set to $want"
}

function Set-ProfileRuntime([string]$want) {
    $t = [System.IO.File]::ReadAllText($profCfg)
    if ($t -match '(?m)^Frontend_RequestedRuntime=(.*)$') {
        if ($Matches[1].Trim() -ne $want) {
            $t = $t -replace '(?m)^Frontend_RequestedRuntime=.*$', "Frontend_RequestedRuntime=$want"
            [System.IO.File]::WriteAllText($profCfg, $t)
            Write-RunLog "profile runtime set to $want"
        }
    } else {
        [System.IO.File]::AppendAllText($profCfg, "`r`nFrontend_RequestedRuntime=$want`r`n")
        Write-RunLog "profile runtime set to $want"
    }
}

$mirrorExe = Join-Path $repo 'tools\mirror_capture_build\openvr_mirror_capture.exe'
$python = Join-Path $repo '.venv\Scripts\python.exe'
$frameCheck = Join-Path $repo '.agents\skills\vr-mod-test-harness\scripts\frame_check.py'
$eyeDir = Join-Path $runDir 'eyes'
$activeMarker = Join-Path $repo 'logs\.active-run.json'   # present while a run owns the game; left behind if the window was closed mid-run
$steamProcs = @('vrmonitor', 'vrdashboard', 'vrcompositor', 'vrwebhelper', 'vrserver')

function Test-SteamVR { [bool](Get-Process -Name 'vrserver' -ErrorAction SilentlyContinue) }

function Repair-UnfinishedRun {
    # A run whose window was closed before its finally block ran (seen 2026-11-27 00:25 and 00:28) left
    # its marker: copy what it missed and, if it was a SteamVR run, put the OpenXR default back.
    if (-not (Test-Path $activeMarker)) { return }
    $m = Get-Content $activeMarker -Raw | ConvertFrom-Json
    Write-RunLog "previous run $($m.stamp) ($($m.runtime)) did not finish its cleanup; recovering it"
    $old = $m.runDir
    if (Test-Path $old) {
        foreach ($f in @('log.txt', 'config.txt', 'cameras.txt', 'imgui.ini')) {
            $src = Join-Path $profileDir $f; $dst = Join-Path $old ("uevr_" + $f)
            if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item $src $dst }
        }
    }
    if ($m.runtime -ne 'OpenXR') {
        if (Test-Path $injCfg) { Set-InjectorRadio $true }
        if (Test-Path $profCfg) { Set-ProfileRuntime 'openxr_loader.dll' }
    }
    if (Test-Path $old) { Add-Content -Path (Join-Path $old 'run.txt') -Encoding utf8 -Value ('[{0}] recovered by run {1}: logs copied afterwards{2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $stamp, $(if ($m.runtime -ne 'OpenXR') { ', OpenXR default restored' } else { '' })) }
    Remove-Item $activeMarker -Force
}

function Invoke-EyeChecks {
    # frame_check every snap pair against the SteamVR idle frame (reject); one line per pair in eyes\verdicts.txt.
    $vf = Join-Path $eyeDir 'verdicts.txt'
    $rej = Join-Path $eyeDir 'reject_left.ppm'
    if (Test-Path $rej) { Add-Content $vf -Encoding utf8 -Value "reject $rej" }
    foreach ($l in Get-ChildItem $eyeDir -Filter 's*_left.ppm' | Sort-Object Name) {
        $id = $l.Name -replace '_left\.ppm$', ''
        $r = Join-Path $eyeDir "${id}_right.ppm"
        $meta = Join-Path $eyeDir "$id.json"
        $cons = if ((Test-Path $meta) -and ((Get-Content $meta -Raw) -match '"consistent":true')) { 'true' } else { 'false' }
        $fcArgs = @('-I', $frameCheck, $l.FullName, $r)
        if (Test-Path $rej) { $fcArgs += @('--reject', $rej) }
        $v = (& $python @fcArgs 2>&1 | Select-Object -Last 1)
        Add-Content $vf -Encoding utf8 -Value "$id consistent=$cons $v"
    }
    $n = @(Get-Content $vf -ErrorAction SilentlyContinue | Where-Object { $_ -match 'VERDICT PASS' }).Count
    Write-RunLog "eye checks: $n PASS lines in $vf"
}

$injector = $null
$game = $null
$radioTouched = $false
$eyeJob = $null
$steamBefore = $false
$ownsMarker = $false
try {
    # One run owns the game install.
    if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
        throw "$procName is already running. Close it first (one run owns the game)."
    }
    if (Get-Process -Name 'UEVRInjector' -ErrorAction SilentlyContinue) {
        throw 'UEVRInjector is already running. Close it first.'
    }
    Write-RunLog "feature: $Feature"
    Repair-UnfinishedRun

    $shipping = Join-Path $GameDir "VotV\Binaries\Win64\$procName.exe"
    $exe = if ($LaunchExe -eq 'Bootstrap') { Join-Path $GameDir 'VotV.exe' } else { $shipping }
    $injExe = Join-Path (Resolve-Path $UevrDir).Path 'UEVRInjector.exe'
    foreach ($p in @($exe, $shipping, $injExe)) { if (-not (Test-Path $p)) { throw "Missing: $p" } }

    # Startup banner: which build, which UEVR, which settings.
    $exeHash  = (Get-FileHash $shipping -Algorithm SHA256).Hash.ToLower()
    $uevrRev  = (Get-Content (Join-Path $UevrDir 'revision.txt') -ErrorAction SilentlyContinue) -join ''
    Write-RunLog "run $stamp | game exe sha256 $exeHash | UEVR dir $UevrDir rev $uevrRev"
    # UEVR hooks DX11/DX12 only; the game also offers Vulkan (in-game RHI manager / launcher choice). The
    # command-line RHI flag overrides the saved choice, so always pass one and never pass -vulkan.
    $rhiFlags = '^-(d3d11|dx11|d3d12|dx12)$'
    $dropped = @($GameArgs | Where-Object { $_ -match '^-(vulkan|opengl|sm5vulkan)$' })
    if ($dropped) { $GameArgs = @($GameArgs | Where-Object { $_ -notmatch '^-(vulkan|opengl|sm5vulkan)$' }); Write-RunLog "WARNING: removed $($dropped -join ' ') from the game arguments (UEVR supports DX11/DX12 only)" }
    if (-not ($GameArgs | Where-Object { $_ -match $rhiFlags })) { $GameArgs = @($GameArgs) + '-d3d11'; Write-RunLog 'no DX flag in the game arguments: added -d3d11' }
    Write-RunLog "launch $exe $($GameArgs -join ' ') | inject=$(-not $NoInject) delay=${InjectDelaySeconds}s"
    $knownHash = '5e690d8f62fe6ce5b9d46815dd05ced45e52a4f110e91f0b6248bbacbe96f6cc'
    if ($exeHash -ne $knownHash) { Write-RunLog "WARNING: game exe differs from the build in RESEARCH.md §0 ($knownHash)" }
    # Other mod loaders next to the exe (Thunderstore shimloader / UE4SS as dwmapi.dll, UE4SS.dll, ...):
    # untested together with UEVR, and some early 0.9.0 builds crash on them (docs/MODDING-WIKI.md).
    $win64 = Split-Path $shipping
    $extra = @(Get-ChildItem $win64 -Force | Where-Object { $_.Name -ne "$procName.exe" } | ForEach-Object Name)
    Write-RunLog "game Win64 folder extras: $(if ($extra) { $extra -join ', ' } else { 'none' })"
    $loaders = @($extra | Where-Object { $_ -match '^(dwmapi|UE4SS|xinput1_3|version|winmm|dinput8|d3d11|dxgi)\.dll$|^(ue4ss|shimloader)$' })
    if ($loaders) { Write-RunLog "WARNING: mod loader files next to the game exe: $($loaders -join ', '). UEVR together with them is untested." }

    # Profile: seed from the repo baseline only if missing (or on request).
    New-Item -ItemType Directory -Force $profileDir | Out-Null
    $profCfg = Join-Path $profileDir 'config.txt'
    if ($ResetProfile -or -not (Test-Path $profCfg)) {
        if (Test-Path $profCfg) { Copy-Item $profCfg (Join-Path $runDir 'config.before-reset.txt') }
        Copy-Item $baseline $profCfg -Force
        Write-RunLog "profile config seeded from $baseline"
    }
    Copy-Item $profCfg (Join-Path $runDir 'config.start.txt')
    # UEVR Lua scripts: the repo's profile\<exe>\scripts is the source; copied over each run (files only
    # added/overwritten, never deleted, so scripts added in the profile by hand survive).
    $repoScripts = Join-Path $repo "profile\$procName\scripts"
    if (Test-Path $repoScripts) {
        $dstScripts = Join-Path $profileDir 'scripts'
        New-Item -ItemType Directory -Force $dstScripts | Out-Null
        # Recursive (subfolders such as scripts\votv\ hold require() modules; UEVR only auto-runs top-level .lua).
        $synced = Get-ChildItem $repoScripts -File -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($repoScripts.Length).TrimStart('\')
            $dst = Join-Path $dstScripts $rel
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            Copy-Item $_.FullName $dst -Force
            $rel
        }
        Write-RunLog "UEVR scripts synced: $($synced -join ', ')"
    }
    # Motion-controller plugin (controls thread): build/votv_controls/votv_controls.dll -> profile plugins folder,
    # this run only (removed again in the finally block). Opt-in with -Controls while it is under test, so other threads' runs stay unchanged.
    $ctlDll = Join-Path $repo 'build\votv_controls\votv_controls.dll'
    $ctlDst = Join-Path $profileDir 'plugins\votv_controls.dll'
    if (Test-Path $ctlDst) { Remove-Item $ctlDst -Force -ErrorAction SilentlyContinue }
    if ($Controls -and (Test-Path $ctlDll)) {
        New-Item -ItemType Directory -Force (Split-Path $ctlDst) | Out-Null
        Copy-Item $ctlDll $ctlDst -Force
        Write-RunLog "controls plugin installed: votv_controls.dll sha256 $((Get-FileHash $ctlDll -Algorithm SHA256).Hash.Substring(0,12))"
    } else { Write-RunLog "controls plugin: not installed ($(if (-not $Controls) { 'no -Controls' } else { 'not built' }))" }
    # Marks plugin (mark thread): screenshot + state JSON on a button, into <repo>\marks\. This run only.
    . (Join-Path $scriptDir 'marks.ps1')
    if ($NoMarks -or $NoInject) { Remove-MarksPlugin $profileDir; Write-RunLog "marks plugin: not installed ($(if ($NoMarks) { '-NoMarks' } else { 'flat run' }))" } else { Install-MarksPlugin $profileDir ${function:Write-RunLog} }
    # Flat-menu laser pointer (menu thread): build/votv_pointer/votv_pointer.dll -> profile plugins folder, this run
    # only (removed in the finally block). Opt-in with -Pointer while it is under test.
    $ptrDll = Join-Path $repo 'build\votv_pointer\votv_pointer.dll'
    $ptrDst = Join-Path $profileDir 'plugins\votv_pointer.dll'
    if (Test-Path $ptrDst) { Remove-Item $ptrDst -Force -ErrorAction SilentlyContinue }
    if ($LateInject -and $Pointer) { Write-RunLog 'pointer plugin: -Pointer ignored with -LateInject (menus use Virtual Desktop''s desktop laser)' }
    if ($Pointer -and -not $LateInject -and (Test-Path $ptrDll)) {
        New-Item -ItemType Directory -Force (Split-Path $ptrDst) | Out-Null
        Copy-Item $ptrDll $ptrDst -Force
        Write-RunLog "pointer plugin installed: votv_pointer.dll sha256 $((Get-FileHash $ptrDll -Algorithm SHA256).Hash.Substring(0,12))"
    } else { Write-RunLog "pointer plugin: not installed ($(if (-not $Pointer) { 'no -Pointer' } elseif ($LateInject) { '-LateInject' } else { 'not built' }))" }
    # Runtime: the repo baseline is the source of truth (the injector rewrites the AppData copy).
    # -Runtime OpenVR is a per-run override (SteamVR parallel test); the default stays OpenXR and
    # is restored in the finally block.
    $rt = Select-String -Path $baseline -Pattern '^Frontend_RequestedRuntime=(.*)$' | Select-Object -First 1
    $baseRt = if ($rt) { $rt.Matches[0].Groups[1].Value } else { 'openxr_loader.dll' }
    $wantRt = if ($Runtime -eq 'OpenVR') { 'openvr_api.dll' } else { 'openxr_loader.dll' }
    $wantXr = ($wantRt -eq 'openxr_loader.dll')
    Set-ProfileRuntime $wantRt
    # UEVR's own menu stays closed at start (user 2026-11-27 02:11: "if I need it I will open it myself").
    # UEVR only honours MenuOpen=false when RememberMenuState is on, and it saves MenuOpen on exit, so set both every run.
    Set-ProfileKey 'FrameworkConfig_RememberMenuState' 'true'
    Set-ProfileKey 'FrameworkConfig_MenuOpen' 'false'
    Write-RunLog "runtime wanted: $wantRt (-Runtime $Runtime; baseline $baseRt)"

    # The injector writes its OpenXR/OpenVR radio button into the profile at injection. Its saved radio
    # state is in %LOCALAPPDATA%\praydog\<InjectorSettingsDir>\1.0.0.0\user.config, a folder named after
    # this injector's path (created by a graceful close; set up 2026-11-27). Only that file is touched.
    # With OpenXR wanted and no such file, refuse to inject: the injector would default to OpenVR/SteamVR.
    if (-not $NoInject) {
        if (Test-Path $injCfg) {
            Set-InjectorRadio $wantXr
            $radioTouched = $true
        } elseif ($wantXr) {
            throw "No saved injector settings at $injCfg, so the injector would pick OpenVR (SteamVR). Open $injExe once, select OpenXR, close it with X, then rerun."
        }
    }
    # Active OpenXR runtime (system setting; read only). User preference 2026-11-26: no SteamVR.
    $xrRt = (Get-ItemProperty 'HKLM:\SOFTWARE\Khronos\OpenXR\1' -ErrorAction SilentlyContinue).ActiveRuntime
    Write-RunLog "active OpenXR runtime: $(if ($xrRt) { $xrRt } else { 'none set' })"
    if ($wantXr -and $xrRt -match 'steam') { Write-RunLog 'WARNING: the active OpenXR runtime is SteamVR. Set Virtual Desktop as the OpenXR runtime (VD Streamer settings) to avoid SteamVR.' }
    if (Get-Process -Name 'vrserver' -ErrorAction SilentlyContinue) { Write-RunLog 'note: SteamVR (vrserver) is already running' }
    if ($DryRun) { Write-RunLog 'dry run: all pre-launch checks done, not launching'; return }
    $uevrLog = Join-Path $profileDir 'log.txt'
    $uevrLogStart = if (Test-Path $uevrLog) { (Get-Item $uevrLog).LastWriteTime } else { [datetime]::MinValue }

    $steamBefore = Test-SteamVR
    @{ stamp = $stamp; runDir = $runDir; runtime = $Runtime; feature = $Feature; started = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -Path $activeMarker -Encoding utf8
    $ownsMarker = $true

    # Virtual Desktop installs an implicit OpenXR API layer ("Compatibility layer for OculusXR Plugin",
    # openxr-oculus-compatibility.dll). UEVR doesn't need it. Turning it off (its manifest's disable_environment,
    # this game process only) did NOT stop the quit crash (run 2026-11-27_01-40-29): VirtualDesktop.LibOVRRT64_1.dll
    # is loaded by VD's runtime itself. Opt-in switch for A/B only.
    if ($wantXr -and -not $NoInject -and $DisableVdOculusLayer) {
        $env:DISABLE_XR_APILAYER_VIRTUALDESKTOP_OCULUS_COMPATIBILITY = '1'
        Write-RunLog 'VD OculusXR compatibility layer disabled for this run (-DisableVdOculusLayer)'
    }

    # Launch the game.
    Start-Process -FilePath $exe -ArgumentList $GameArgs -WorkingDirectory (Split-Path $exe) | Out-Null
    $deadline = (Get-Date).AddSeconds($ProcessWaitSeconds)
    while (-not ($game = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        if ((Get-Date) -gt $deadline) { throw "$procName did not start within ${ProcessWaitSeconds}s" }
        Start-Sleep -Milliseconds 500
    }
    Write-RunLog "game process pid $($game.Id)"

    $deadline = (Get-Date).AddSeconds($WindowWaitSeconds)
    while ($true) {
        $game.Refresh()
        if ($game.HasExited) { throw "game exited before its window appeared (exit code $($game.ExitCode))" }
        if ($game.MainWindowHandle -ne [IntPtr]::Zero) { break }
        if ((Get-Date) -gt $deadline) { throw "no game window within ${WindowWaitSeconds}s" }
        Start-Sleep -Milliseconds 500
    }
    Write-RunLog "game window up: '$($game.MainWindowTitle)'"

    if (-not $NoInject -and $LateInject) {
        # Late inject (user plan 2026-11-27): the game runs flat until the user is past the menus, so Virtual
        # Desktop shows it on its desktop view with VD's own laser pointer (it moves the real mouse). The shipping
        # build writes no VotV.log (Saved\Logs is empty), so there is no map-load line to wait for: the user
        # presses F10 (read with GetAsyncKeyState, works whatever window has focus) once the save has loaded.
        Add-Type -Namespace VotvLate -Name Keys -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);' -ErrorAction SilentlyContinue
        Write-RunLog "late inject: game is flat; press F10 once your save has loaded (waiting up to ${LateInjectTimeoutMinutes} min)"
        $deadline = (Get-Date).AddMinutes($LateInjectTimeoutMinutes)
        $pressed = $false
        while ((Get-Date) -lt $deadline) {
            $game.Refresh()
            if ($game.HasExited) { throw 'game exited before F10 (late inject)' }
            if (([VotvLate.Keys]::GetAsyncKeyState(0x79) -band 0x8000) -ne 0) { $pressed = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $pressed) { throw "late inject: no F10 within $LateInjectTimeoutMinutes min" }
        Write-RunLog 'late inject: F10 pressed, injecting in 3 s'
        Start-Sleep -Seconds 3
    }
    if (-not $NoInject) {
        if (-not $LateInject) { Start-Sleep -Seconds $InjectDelaySeconds }
        $game.Refresh()
        if ($game.HasExited) { throw 'game exited during the inject delay' }
        $injector = Start-Process -FilePath $injExe -ArgumentList "--attach=$procName" -WorkingDirectory (Split-Path $injExe) -PassThru
        Write-RunLog "UEVRInjector started (pid $($injector.Id)) with --attach=$procName"

        # Confirm injection from UEVR's own log (bounded wait); a missing entry is reported, not assumed.
        $deadline = (Get-Date).AddSeconds(60)
        $seen = $false
        while ((Get-Date) -lt $deadline -and -not $game.HasExited) {
            if ((Test-Path $uevrLog) -and (Get-Item $uevrLog).LastWriteTime -gt $uevrLogStart) {
                if (Select-String -Path $uevrLog -Pattern 'UnrealVR entry' -Quiet) { $seen = $true; break }
            }
            Start-Sleep -Seconds 1
            $game.Refresh()
        }
        Write-RunLog $(if ($seen) { 'UEVR log shows "UnrealVR entry": backend loaded' } else { 'WARNING: no fresh UEVR log within 60s; check the injector window' })
        $deadline = (Get-Date).AddSeconds(30)
        $req = $null
        while (-not $req -and (Get-Date) -lt $deadline -and -not $game.HasExited) {
            $req = Select-String -Path $uevrLog -Pattern 'Requested runtime: (\S+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
            if (-not $req) { Start-Sleep -Seconds 1; $game.Refresh() }
        }
        if ($req) {
            $got = $req.Matches[0].Groups[1].Value
            Write-RunLog "UEVR requested runtime: $got"
            if ($got -ne $wantRt) { Write-RunLog "WARNING: UEVR requested $got but this run wanted $wantRt; the injector's radio button overrode it" }
        }

        # SteamVR runs: snap both eyes from the compositor mirror every few seconds in the background
        # (bounded), checked with frame_check after the game exits. OpenXR (VDXR) has no such mirror.
        if (-not $wantXr -and $EyeCaptureEverySeconds -gt 0) {
            if (-not (Test-Path $mirrorExe)) { Write-RunLog "eye capture skipped: $mirrorExe missing" }
            else {
                New-Item -ItemType Directory -Force $eyeDir | Out-Null
                $eyeJob = Start-Job -ArgumentList $mirrorExe, $eyeDir, $game.Id, $EyeCaptureFirstDelaySeconds, $EyeCaptureEverySeconds, $EyeCaptureMax -ScriptBlock {
                    param($exe, $dir, $gamePid, $first, $every, $max)
                    $stop = Join-Path $dir 'capture.stop'
                    $t = (Get-Date).AddSeconds($first)
                    for ($i = 0; $i -lt $max; ) {
                        if (Test-Path $stop) { break }
                        if (-not (Get-Process -Id $gamePid -ErrorAction SilentlyContinue)) { break }
                        if ((Get-Date) -lt $t) { Start-Sleep -Milliseconds 500; continue }
                        $id = 's{0:D3}' -f $i
                        $o = & $exe (Join-Path $dir $id) snap 4 2>&1
                        ($o | Out-String).Trim() | Set-Content (Join-Path $dir "$id.json")
                        $i++
                        $t = (Get-Date).AddSeconds($every)
                    }
                }
                Write-RunLog "eye capture started: first snap after ${EyeCaptureFirstDelaySeconds}s, every ${EyeCaptureEverySeconds}s, at most $EyeCaptureMax, into $eyeDir"
            }
        }
        if ($wantXr) {
            # User preference: OpenXR runs never start SteamVR. Record whether it happened anyway.
            Start-Sleep -Seconds 5
            $now = Test-SteamVR
            $svState = if ($now -and -not $steamBefore) { 'started' } elseif ($now) { 'was-already-running' } else { 'not-running' }
            Write-RunLog "SteamVR during run: $svState"
            if ($svState -eq 'started') { Write-RunLog 'WARNING: SteamVR started during an OpenXR run' }
            # Which XR modules are in the game process (proves whether the VD layer switch took effect).
            try {
                $game.Refresh()
                $xrMods = @($game.Modules | Where-Object { $_.ModuleName -match 'openxr|LibOVRRT|oculus' } | ForEach-Object ModuleName)
                $gfx = @($game.Modules | Where-Object { $_.ModuleName -match '^(d3d11|d3d12|vulkan-1)\.dll$' } | ForEach-Object ModuleName)
                Write-RunLog "render modules in game: $(if ($gfx) { $gfx -join ', ' } else { 'none' })"
                Write-RunLog "XR modules in game: $(if ($xrMods) { $xrMods -join ', ' } else { 'none' })"
            } catch { Write-RunLog "XR modules in game: unknown ($($_.Exception.Message))" }
        }
    }

    # Wait for the game to exit (optionally bounded).
    if ($MaxRunMinutes -gt 0) {
        if (-not $game.WaitForExit($MaxRunMinutes * 60 * 1000)) {
            Write-RunLog "MaxRunMinutes ($MaxRunMinutes) reached; closing the game"
            $game.CloseMainWindow() | Out-Null
            if (-not $game.WaitForExit(20000)) { $game.Kill() }
        }
    } else {
        $game.WaitForExit()
    }
    $game.Refresh()
    Write-RunLog "game exited (code $($game.ExitCode))"
}
catch {
    Write-RunLog "ERROR: $($_.Exception.Message)"
}
finally {
    # Always clean up: the injector goes away with the run. Nothing was put in the game folder.
    # Close gracefully first so the injector saves its settings (user.config), then force.
    foreach ($p in @(Get-Process -Name 'UEVRInjector' -ErrorAction SilentlyContinue)) {
        $p.CloseMainWindow() | Out-Null
        if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Get-Process -Name 'UEVRInjector' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Controls plugin: the run's trace goes with the logs; the DLL leaves the profile with the run.
    $ctlTrace = Join-Path $profileDir 'votv_controls_trace.txt'
    if (Test-Path $ctlTrace) { Move-Item $ctlTrace (Join-Path $runDir 'votv_controls_trace.txt') -Force -ErrorAction SilentlyContinue }
    $ctlDst2 = Join-Path $profileDir 'plugins\votv_controls.dll'
    if (Test-Path $ctlDst2) { Remove-Item $ctlDst2 -Force -ErrorAction SilentlyContinue }
    $mkDst = Join-Path $profileDir 'plugins\votv_marks.dll'
    if (Test-Path $mkDst) { Remove-Item $mkDst -Force -ErrorAction SilentlyContinue }
    # Pointer plugin: trace goes with the logs; the DLL leaves the profile with the run.
    $ptrTrace = Join-Path $profileDir 'votv_pointer_trace.txt'
    if (Test-Path $ptrTrace) { Move-Item $ptrTrace (Join-Path $runDir 'votv_pointer_trace.txt') -Force -ErrorAction SilentlyContinue }
    $ptrDst2 = Join-Path $profileDir 'plugins\votv_pointer.dll'
    if (Test-Path $ptrDst2) { Remove-Item $ptrDst2 -Force -ErrorAction SilentlyContinue }
    foreach ($f in @('log.txt', 'config.txt', 'cameras.txt', 'imgui.ini')) {
        $src = Join-Path $profileDir $f
        # log.txt only if UEVR wrote it during this run (else it is an older run's log: false PASS risk).
        if ($f -eq 'log.txt' -and (Test-Path $src) -and (Get-Item $src).LastWriteTime -lt (Get-Item $runLog).CreationTime) {
            Write-RunLog 'UEVR log.txt not copied: not written during this run'
            continue
        }
        if (Test-Path $src) { Copy-Item $src (Join-Path $runDir ("uevr_" + $f)) -Force }
    }
    $gameLogs = Join-Path $env:LOCALAPPDATA 'VotV\Saved\Logs'
    if (Test-Path $gameLogs) {
        Get-ChildItem $gameLogs -File | Where-Object { $_.LastWriteTime -gt (Get-Item $runLog).CreationTime } |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $runDir ("game_" + $_.Name)) -Force }
    }
    $crashes = Join-Path $env:LOCALAPPDATA 'VotV\Saved\Crashes'
    if (Test-Path $crashes) {
        $new = Get-ChildItem $crashes -Directory | Where-Object { $_.LastWriteTime -gt (Get-Item $runLog).CreationTime }
        if ($new) { Write-RunLog "CRASH folder(s) written this run: $($new.Name -join ', ') (not copied: dumps stay out of the repo; add to the crash ledger)" }
    }
    # SteamVR runs: stop the eye capture, snap SteamVR's idle view as the known-bad frame, check every pair.
    if ($eyeJob) {
        try {
            Set-Content (Join-Path $eyeDir 'capture.stop') 'stop'
            Wait-Job $eyeJob -Timeout 30 | Out-Null
            Remove-Job $eyeJob -Force
            if (Test-SteamVR) {
                Start-Sleep -Seconds 5   # let the compositor drop the game's last frame
                $o = & $mirrorExe (Join-Path $eyeDir 'reject') snap 4 2>&1
                Write-RunLog "reject (SteamVR idle) snap: $(($o | Out-String).Trim())"
            } else { Write-RunLog 'reject snap skipped: SteamVR no longer running' }
            Invoke-EyeChecks
        } catch { Write-RunLog "WARNING: eye checks failed: $($_.Exception.Message)" }
    }
    # Close SteamVR if this run started it (a SteamVR run is a one-off; OpenXR is the default).
    if ($Runtime -ne 'OpenXR' -and -not $steamBefore -and -not $LeaveSteamVR -and -not $DryRun -and (Test-SteamVR)) {
        foreach ($p in @(Get-Process -Name 'vrmonitor' -ErrorAction SilentlyContinue)) { $p.CloseMainWindow() | Out-Null }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Test-SteamVR) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-SteamVR) { Get-Process -Name $steamProcs -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        Write-RunLog "SteamVR closed (this run started it): $(if (Test-SteamVR) { 'still running' } else { 'done' })"
    }
    # A SteamVR (OpenVR) run is a one-off: put the default back (after the injector has closed and
    # after the run's config was copied above).
    if ($Runtime -ne 'OpenXR') {
        try {
            if ($radioTouched -and (Test-Path $injCfg)) { Set-InjectorRadio $true }
            if (Test-Path $profCfg) { Set-ProfileRuntime 'openxr_loader.dll' }
            Write-RunLog 'default restored: OpenXR'
        } catch { Write-RunLog "WARNING: could not restore the OpenXR default: $($_.Exception.Message)" }
    }
    if ($ownsMarker) { Remove-Item $activeMarker -Force -ErrorAction SilentlyContinue }
    Write-RunLog "logs in $runDir"
    if (-not $DryRun) {
        Write-Host ''
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'check-run.ps1') $runDir
    }
}
