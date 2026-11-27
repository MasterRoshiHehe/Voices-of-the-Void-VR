<#
.SYNOPSIS
  Verdict for one test run folder (logs\<timestamp>\): did UEVR come up on the runtime the run asked for,
  did the run finish and clean up, and (SteamVR runs) did both eyes pass frame_check.

.DESCRIPTION
  Prints one line per check (PASS / FAIL / UNSURE) and a last line "VERDICT PASS|FAIL|INCONCLUSIVE (...)",
  and writes the same text to <run>\verdict.txt. Exit code 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
  run-vr.ps1 calls this at the end of every run; it can be rerun on any old run folder.
  On OpenXR (Virtual Desktop) there is no automatic eye capture, so the eye check stays UNSURE there:
  the headset or the user's description decides it.

.EXAMPLE
  .\scripts\check-run.ps1 logs\2026-11-27_00-43-09
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RunDir,
    [double]$MinEyePassFraction = 0.6,   # share of consistent eye pairs that must PASS
    [int]$MinEyePasses = 3               # and at least this many PASS pairs
)
$ErrorActionPreference = 'Stop'
$RunDir = (Resolve-Path $RunDir).Path
$runTxt = Join-Path $RunDir 'run.txt'
$uevrLog = Join-Path $RunDir 'uevr_log.txt'
$run = if (Test-Path $runTxt) { Get-Content $runTxt } else { @() }
$uevr = if (Test-Path $uevrLog) { Get-Content $uevrLog } else { @() }
$finished = [bool]($run | Select-String -Pattern '^\[[^\]]+\] logs in |recovered by')
if (-not $finished -and (Get-Process -Name 'VotV-Win64-Shipping' -ErrorAction SilentlyContinue)) {
    # Judging a live run gives false FAILs (its logs are copied at the end); write nothing.
    Write-Host "run $(Split-Path $RunDir -Leaf) is still in progress (game running, cleanup not done): no verdict yet"
    exit 2
}
$out = New-Object System.Collections.Generic.List[string]
function Add-Check([string]$state, [string]$name, [string]$detail) { $out.Add(('{0,-6} {1,-16} {2}' -f $state, $name, $detail)) }
function Find([string[]]$lines, [string]$pattern) { $lines | Select-String -Pattern $pattern | Select-Object -Last 1 }

# Which runtime this run wanted.
$wantLine = Find $run 'runtime wanted: (\S+)'
$want = if ($wantLine) { $wantLine.Matches[0].Groups[1].Value } else { $null }
$feature = (Find $run 'feature: (.*)$'); $feature = if ($feature) { $feature.Matches[0].Groups[1].Value.Trim() } else { 'unspecified' }
$noInject = [bool](Find $run 'inject=False')

if (-not $run) { Add-Check FAIL run-log "no run.txt in $RunDir" }
if ($noInject) {
    Add-Check UNSURE runtime 'flat run (-NoInject): no VR runtime expected'
} else {
    # 1. UEVR asked for the runtime this run wanted (the injector's radio can override the profile).
    $reqLine = Find $uevr 'Requested runtime: (\S+)'
    $req = if ($reqLine) { $reqLine.Matches[0].Groups[1].Value } else { $null }
    if (-not $want) { Add-Check UNSURE runtime-request "run.txt has no 'runtime wanted' line (run before 2026-11-27 00:43?); UEVR requested $req" }
    elseif (-not $req) { Add-Check FAIL runtime-request "UEVR log has no 'Requested runtime' line (not injected, or log not copied)" }
    elseif ($req -ne $want) { Add-Check FAIL runtime-request "wanted $want, UEVR requested $req" }
    else { Add-Check PASS runtime-request $req }

    # 2. The runtime actually came up.
    if ($req -eq 'openxr_loader.dll') {
        $sys = Find $uevr 'OpenXR system Name: (.*)$'
        if ($sys) { Add-Check PASS runtime-up "OpenXR session, system '$($sys.Matches[0].Groups[1].Value.Trim())'" }
        else { Add-Check FAIL runtime-up 'no "OpenXR system Name" in the UEVR log' }
    } elseif ($req -eq 'openvr_api.dll') {
        $ok = Find $uevr '\[OpenVR\.cpp|Made overlay with handle'
        $bad = Find $uevr 'VR_Init failed|Failed to initialize OpenVR'
        if ($ok -and -not $bad) { Add-Check PASS runtime-up 'OpenVR (SteamVR) initialised' }
        else { Add-Check FAIL runtime-up "OpenVR did not come up$(if ($bad) { ': ' + $bad.Line.Trim() })" }
    } else { Add-Check UNSURE runtime-up 'unknown runtime' }

    # 3. Render API (the launcher pins -d3d11).
    if (Find $uevr 'Hooked DirectX 11') { Add-Check PASS rhi 'DirectX 11 hooked (pinned with -d3d11)' }
    elseif (Find $uevr 'Hooked DirectX 12') { Add-Check UNSURE rhi 'only DirectX 12 hooked' }
    else { Add-Check FAIL rhi 'no DirectX hook in the UEVR log' }

    # 4. OpenXR runs must not start SteamVR (user preference 2026-11-26).
    $svr = Find $run 'SteamVR during run: (\S+)'
    if ($want -eq 'openxr_loader.dll') {
        if (-not $svr) { Add-Check UNSURE steamvr-free 'not recorded (run before 2026-11-27 01:30)' }
        elseif ($svr.Matches[0].Groups[1].Value -eq 'started') { Add-Check FAIL steamvr-free 'SteamVR started during an OpenXR run' }
        else { Add-Check PASS steamvr-free "SteamVR $($svr.Matches[0].Groups[1].Value)" }
    }
}

# 5. Run finished and cleaned up.
$err = Find $run 'ERROR: (.*)$'
if ($err) { Add-Check FAIL run-error $err.Matches[0].Groups[1].Value }
if (Find $run 'game exited') { Add-Check PASS game-exit (Find $run 'game exited').Line.Substring(15) }
elseif (-not $err) { Add-Check FAIL game-exit 'no "game exited" line' }
if (Find $run 'CRASH folder') { Add-Check FAIL crash ((Find $run 'CRASH folder').Line.Substring(15) + ' (crash ledger in STATUS.md)') }
else { Add-Check PASS crash 'no new crash folder' }
if (Find $run '^\[[^\]]+\] logs in ') { Add-Check PASS cleanup 'launcher cleanup finished' }
elseif (Find $run 'recovered by') { Add-Check UNSURE cleanup ((Find $run 'recovered by').Line.Substring(15)) }
else { Add-Check FAIL cleanup 'launcher cleanup did not finish (window closed early?); the next run recovers it' }
if ($want -eq 'openvr_api.dll') {
    if (Find $run 'default restored: OpenXR') { Add-Check PASS default-restored 'OpenXR default put back' }
    elseif (Find $run 'recovered by') { Add-Check PASS default-restored 'put back by a later run''s recovery' }
    else { Add-Check FAIL default-restored 'no "default restored" line' }
}

# 6. Eyes (SteamVR runs: mirror capture + frame_check; see run-vr.ps1).
$eyeFile = Join-Path $RunDir 'eyes\verdicts.txt'
if ($noInject) { }
elseif (Test-Path $eyeFile) {
    $rows = Get-Content $eyeFile | Where-Object { $_ -match '^s\d+' }
    $cons = @($rows | Where-Object { $_ -match 'consistent=true' })
    $pass = @($cons | Where-Object { $_ -match 'VERDICT PASS' }).Count
    $fail = @($cons | Where-Object { $_ -match 'VERDICT FAIL' }).Count
    $inc = $cons.Count - $pass - $fail
    $detail = "$pass PASS, $fail FAIL, $inc INCONCLUSIVE of $($cons.Count) same-frame pairs ($($rows.Count - $cons.Count) mixed-frame pairs skipped); $eyeFile"
    if (-not (Find (Get-Content $eyeFile) '^reject ')) { Add-Check UNSURE eyes "no reject (SteamVR idle) frame, so a PASS can't be told from another screen; $detail" }
    elseif ($cons.Count -gt 0 -and $pass -ge $MinEyePasses -and ($pass / $cons.Count) -ge $MinEyePassFraction) { Add-Check PASS eyes $detail }
    elseif ($fail -gt 0) { Add-Check FAIL eyes $detail }
    else { Add-Check UNSURE eyes $detail }
} elseif ($want -eq 'openvr_api.dll' -or (Find $uevr 'Requested runtime: openvr_api\.dll')) {
    Add-Check UNSURE eyes 'no eye capture in this run'
} else {
    Add-Check UNSURE eyes 'no automatic eye capture on OpenXR (VDXR): headset or user check'
}

$fails = @($out | Where-Object { $_ -like 'FAIL*' }).Count
$unsure = @($out | Where-Object { $_ -like 'UNSURE*' }).Count
$word = if ($fails) { 'FAIL' } elseif ($unsure) { 'INCONCLUSIVE' } else { 'PASS' }
$rtKey = if ($want) { $want } elseif (-not $noInject -and (Find $uevr 'Requested runtime: (\S+)')) { (Find $uevr 'Requested runtime: (\S+)').Matches[0].Groups[1].Value } else { $null }
$rtName = switch ($rtKey) { 'openxr_loader.dll' { 'OpenXR' } 'openvr_api.dll' { 'SteamVR' } default { 'unknown' } }
$out.Insert(0, "run $(Split-Path $RunDir -Leaf) | runtime $rtName | feature $feature")
$out.Add("VERDICT $word ($fails failed, $unsure unsure of $($out.Count - 1) checks)")
$out | Set-Content -Path (Join-Path $RunDir 'verdict.txt') -Encoding utf8
$out | ForEach-Object { Write-Host $_ }
exit $(if ($fails) { 1 } elseif ($unsure) { 2 } else { 0 })
