<#
.SYNOPSIS
  Helpers for the in-headset marks (votv_marks.dll), dot-sourced by run-vr.ps1 and check-run.ps1.
  Marks go to <repo>\marks\<yyyy-MM-dd_HH-mm-ss_mmm>\ (mark.json, mirror.jpg, eye_* on SteamVR runs).

.EXAMPLE
  .\scripts\marks.ps1 -Note "keypad highlight too high"      # adds note.txt to the newest mark
  .\scripts\marks.ps1 -Note "..." -Mark 2026-11-27_02-20-15_123
#>
param([string]$Note, [string]$Mark)

$script:MarksRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:MarksDir = Join-Path $script:MarksRepo 'marks'

# run-vr.ps1: put the plugin in the profile for this run and point its settings at the dev folder.
function Install-MarksPlugin([string]$profileDir, [scriptblock]$log) {
    $dll = Join-Path $script:MarksRepo 'build\votv_marks\votv_marks.dll'
    $dst = Join-Path $profileDir 'plugins\votv_marks.dll'
    if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $dll)) { & $log 'marks plugin: not installed (not built: scripts\build-marks.ps1)'; return }
    New-Item -ItemType Directory -Force (Split-Path $dst), $script:MarksDir | Out-Null
    Copy-Item $dll $dst -Force
    $cfg = Join-Path $profileDir 'scripts\votv_marks.txt'
    if (Test-Path $cfg) {
        $mirror = Join-Path $script:MarksRepo 'tools\mirror_capture_build\openvr_mirror_capture.exe'
        $t = [System.IO.File]::ReadAllText($cfg)
        $t = [regex]::Replace($t, '(?m)^mark_dir=.*$', "mark_dir=$($script:MarksDir)")
        if (Test-Path $mirror) { $t = [regex]::Replace($t, '(?m)^mark_mirror_exe=.*$', "mark_mirror_exe=$mirror") }
        [System.IO.File]::WriteAllText($cfg, $t)
    }
    & $log "marks plugin installed: votv_marks.dll sha256 $((Get-FileHash $dll -Algorithm SHA256).Hash.Substring(0,12)); marks dir: $($script:MarksDir) (left grip + right stick click, or F8)"
}

function Remove-MarksPlugin([string]$profileDir) {
    $dst = Join-Path $profileDir 'plugins\votv_marks.dll'
    if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
}

# check-run.ps1: marks made between two times. Returns objects with Path, Time, Trigger, Note, Summary.
function Get-MarksBetween([datetime]$from, [datetime]$to) {
    if (-not (Test-Path $script:MarksDir)) { return @() }
    Get-ChildItem $script:MarksDir -Directory | Where-Object { $_.Name -match '^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_\d{3}$' } | ForEach-Object {
        $t = [datetime]::ParseExact($_.Name, 'yyyy-MM-dd_HH-mm-ss_fff', $null)
        if ($t -lt $from -or $t -gt $to) { return }
        $j = $null
        try { $j = Get-Content (Join-Path $_.FullName 'mark.json') -Raw | ConvertFrom-Json } catch { }
        $note = if ($j -and $j.note) { $j.note } else { '' }
        $nf = Join-Path $_.FullName 'note.txt'
        if (Test-Path $nf) { $note = (($note, (Get-Content $nf -Raw).Trim()) | Where-Object { $_ }) -join ' / ' }
        $sum = if ($j) {
            $g = $j.game
            $gz = if ($g.gaze_trace.hit) { "$($g.gaze_trace.actor) @$([int]$g.gaze_trace.distance_cm)cm" } else { 'no hit' }
            "world $($g.world) | look_at $($g.look_at_actor) | gaze $gz | shot $(if ($j.screenshot.ok) { 'ok' } else { 'missing' })"
        } else { 'mark.json missing or unreadable' }
        [pscustomobject]@{ Path = $_.FullName; Time = $t; Trigger = $(if ($j) { $j.trigger } else { '?' }); Note = $note; Summary = $sum }
    } | Sort-Object Time
}

# Log context per mark (the AI reads this first): UEVR log lines from 7 s before to 3 s after each mark.
function Write-MarkLogContext($marks, [string]$uevrLog, [string]$out) {
    $lines = if (Test-Path $uevrLog) { Get-Content $uevrLog } else { @() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $marks) {
        [void]$sb.AppendLine("==== mark $($m.Time.ToString('HH:mm:ss.fff')) | $($m.Trigger) | $($m.Summary)$(if ($m.Note) { ' | note: ' + $m.Note })")
        [void]$sb.AppendLine("     $($m.Path)")
        $a = $m.Time.AddSeconds(-7); $b = $m.Time.AddSeconds(3)
        foreach ($l in $lines) {
            if ($l -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]') {
                $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null)
                if ($t -ge $a -and $t -le $b) { [void]$sb.AppendLine($l) }
            }
        }
    }
    $sb.ToString() | Set-Content -Path $out -Encoding utf8
}

if ($Note) {
    $target = if ($Mark) { Join-Path $script:MarksDir $Mark } else { Get-ChildItem $script:MarksDir -Directory | Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName }
    if (-not $target -or -not (Test-Path $target)) { throw "no mark folder found ($target)" }
    Add-Content -Path (Join-Path $target 'note.txt') -Value $Note -Encoding utf8
    Write-Host "note added to $target"
}
