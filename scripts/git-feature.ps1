<#
.SYNOPSIS
  Commit to a feature branch and merge it into dev without touching the shared working tree.

.DESCRIPTION
  Several agent threads edit files in this one folder at the same time, so nobody may switch
  branches here (a switch rewrites everyone's files). The folder stays checked out on dev.
  This script builds commits with a private temporary index and moves branch refs with
  compare-and-swap, so git never writes a file on disk:

    commit  Snapshot the listed paths, as they are on disk, onto feature/<topic>
            (created from dev if missing). Other paths keep the branch's previous content.
    merge   Merge feature/<topic> into dev (merge commit; stops on conflicts), then refresh
            the shared index from dev. Files on disk are not touched.
    status  Show feature branches not yet in dev, and on-disk changes not yet in dev.

  main is never written here: it moves only when the user says a release is ready.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 commit -Branch feature/vr-menu -Message "Menu camera fix" -Paths profile\VotV-Win64-Shipping\scripts\votv_menu_camera.lua,STATUS.md -Push
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 merge -Branch feature/vr-menu -Push
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('commit', 'merge', 'status')]
    [string]$Action,
    [string]$Branch = '',          # feature/<topic>
    [string]$Message = '',         # commit message (commit); merge uses "Merge <branch> into dev" unless given
    [string[]]$Paths = @(),        # repo-relative files or folders to snapshot (commit); deletions included
    [string]$Base = 'dev',         # branch a new feature branch starts from, and the merge target
    [switch]$Push                  # also push the branch(es) to origin
)
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    $out = & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $out
}
function New-Commit([string]$tree, [string[]]$parents, [string]$msg) {
    # Message via a UTF-8 (no BOM) file: piping or -m mangles newlines/quotes under Windows PowerShell 5.1.
    $msgFile = Join-Path ([IO.Path]::GetTempPath()) ("git-feature-" + [guid]::NewGuid().ToString('N') + ".msg")
    try {
        [IO.File]::WriteAllText($msgFile, $msg.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
        $pargs = @(); foreach ($p in $parents) { $pargs += @('-p', $p) }
        $c = & git commit-tree $tree @pargs -F $msgFile
        if ($LASTEXITCODE -ne 0 -or -not $c) { throw "commit-tree failed (exit $LASTEXITCODE)" }
        return ($c | Select-Object -First 1).Trim()
    } finally { Remove-Item $msgFile -Force -ErrorAction SilentlyContinue }
}
function Get-Ref([string]$name) {
    $sha = & git rev-parse -q --verify "refs/heads/$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($sha | Select-Object -First 1).Trim()
}
function Assert-FeatureBranch {
    if ($Branch -notmatch '^feature/[a-z0-9][a-z0-9._-]*$') {
        throw "-Branch must look like feature/<topic> (lowercase, digits, . _ -); got '$Branch'"
    }
}
function Push-Branches([string[]]$names) {
    $env:GCM_INTERACTIVE = 'never'   # fail instead of popping the credential manager's account picker at the user
    foreach ($n in $names) {
        $ok = $false
        foreach ($wait in 0, 2, 4, 8, 16) {
            if ($wait) { Start-Sleep -Seconds $wait }
            & git push -u origin "refs/heads/${n}:refs/heads/$n"
            if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        }
        if (-not $ok) { throw "push of $n failed after retries" }
    }
}

$repo = (Invoke-Git rev-parse --show-toplevel | Select-Object -First 1).Trim()
Set-Location $repo
if ($Base -in @('main')) { throw "-Base main is not allowed: main moves only on a user-approved release" }

switch ($Action) {
    'status' {
        $baseSha = Get-Ref $Base
        Write-Output "== feature branches not merged into $Base"
        & git branch --no-merged $Base --list 'feature/*' -v
        Write-Output "== files on disk that differ from $Base (uncommitted work in the shared folder)"
        & git status --short
        Write-Output "== HEAD: $((& git symbolic-ref -q --short HEAD))  $Base=$baseSha"
    }

    'commit' {
        Assert-FeatureBranch
        if (-not $Message) { throw "-Message is required" }
        $Paths = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # -File passes a,b as one string
        if ($Paths.Count -eq 0) { throw "-Paths is required: list only the files your thread changed" }
        $old = Get-Ref $Branch
        $parent = if ($old) { $old } else { Get-Ref $Base }
        if (-not $parent) { throw "base branch '$Base' not found" }

        $tmpIndex = Join-Path ([IO.Path]::GetTempPath()) ("git-feature-" + [guid]::NewGuid().ToString('N') + ".index")
        $savedIndex = $env:GIT_INDEX_FILE
        try {
            $env:GIT_INDEX_FILE = $tmpIndex
            Invoke-Git read-tree $parent | Out-Null
            Invoke-Git -c core.safecrlf=false add -A '--' @Paths | Out-Null
            & git diff --cached --quiet $parent
            if ($LASTEXITCODE -eq 0) { Write-Output "nothing to commit: $($Paths -join ', ') match $Branch"; return }
            Write-Output "== changes going onto $Branch"
            & git diff --cached --stat $parent
            $tree = (Invoke-Git write-tree | Select-Object -First 1).Trim()
        } finally {
            if ($savedIndex) { $env:GIT_INDEX_FILE = $savedIndex } else { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
            Remove-Item $tmpIndex -Force -ErrorAction SilentlyContinue
        }
        $commit = New-Commit $tree @($parent) $Message
        $expect = if ($old) { $old } else { '0000000000000000000000000000000000000000' }
        Invoke-Git update-ref -m "git-feature commit" "refs/heads/$Branch" $commit $expect | Out-Null
        Write-Output "committed $commit on $Branch"
        if ($Push) { Push-Branches @($Branch) }
    }

    'merge' {
        Assert-FeatureBranch
        $feat = Get-Ref $Branch
        $baseSha = Get-Ref $Base
        if (-not $feat) { throw "branch $Branch not found" }
        & git merge-base --is-ancestor $feat $baseSha
        if ($LASTEXITCODE -eq 0) { Write-Output "$Branch is already in $Base"; if ($Push) { Push-Branches @($Base) }; return }

        $mt = & git merge-tree --write-tree --name-only $baseSha $feat
        if ($LASTEXITCODE -ne 0) {
            Write-Output "CONFLICT merging $Branch into ${Base}:"
            $mt | Select-Object -Skip 1 | Write-Output
            throw "merge stopped: commit a resolution on $Branch (bring in $Base's version of those files, fix, commit), then merge again"
        }
        $tree = ($mt | Select-Object -First 1).Trim()
        if (-not $Message) { $Message = "Merge $Branch into $Base" }
        $commit = New-Commit $tree @($baseSha, $feat) $Message
        Invoke-Git update-ref -m "git-feature merge $Branch" "refs/heads/$Base" $commit $baseSha | Out-Null
        $head = & git symbolic-ref -q --short HEAD
        if ($head -eq $Base) { Invoke-Git reset -q | Out-Null }   # index follows dev; files on disk are not touched
        Write-Output "merged $Branch into $Base as $commit"
        if ($Push) { Push-Branches @($Branch, $Base) }
    }
}
