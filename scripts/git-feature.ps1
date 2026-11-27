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
    sync    Bring origin/dev into local dev (fast-forward or merge commit; STATUS.md merges by
            union, see .gitattributes). Files on disk that the incoming commits change are
            updated only where no thread has edited them; where a thread has, its edits are kept
            and the incoming change is merged in (stops, touching nothing, on a real conflict).
            merge -Push runs sync first, so a moved origin/dev is not a push failure.
    status  Show feature branches not yet in dev, and on-disk changes not yet in dev.

  main is never written here: it moves only when the user says a release is ready.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 commit -Branch feature/vr-menu -Message "Menu camera fix" -Paths profile\VotV-Win64-Shipping\scripts\votv_menu_camera.lua,STATUS.md -Push
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 merge -Branch feature/vr-menu -Push
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 sync -Push
  powershell -ExecutionPolicy Bypass -File scripts\git-feature.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('commit', 'merge', 'sync', 'status')]
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

function Get-Blob([string]$spec) {
    $b = & git rev-parse -q --verify "$spec" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($b | Select-Object -First 1).Trim()
}
function Save-Rev([string]$spec, [string]$dest) {
    # Byte-exact, with the checkout filters (CRLF) applied; cmd redirection keeps PowerShell from re-encoding.
    cmd /c "git cat-file --filters `"$spec`" > `"$dest`""
    if ($LASTEXITCODE -ne 0) { throw "could not read $spec" }
}
function Sync-Dev {
    $env:GCM_INTERACTIVE = 'never'
    $remoteRef = "refs/remotes/origin/$Base"
    $fetched = $false
    foreach ($wait in 0, 2, 4, 8) {
        if ($wait) { Start-Sleep -Seconds $wait }
        & git fetch -q origin "+refs/heads/${Base}:$remoteRef"
        if ($LASTEXITCODE -eq 0) { $fetched = $true; break }
    }
    if (-not $fetched) { throw "fetch of origin/$Base failed" }
    $local = Get-Ref $Base
    $remote = (Invoke-Git rev-parse $remoteRef | Select-Object -First 1).Trim()
    & git merge-base --is-ancestor $remote $local
    if ($LASTEXITCODE -eq 0) { Write-Output "$Base already contains origin/$Base"; return }
    & git merge-base --is-ancestor $local $remote
    if ($LASTEXITCODE -eq 0) {
        $new = $remote; Write-Output "fast-forward $Base to origin/$Base ($remote)"
    } else {
        $mt = & git merge-tree --write-tree --name-only $local $remote
        if ($LASTEXITCODE -ne 0) {
            Write-Output "CONFLICT bringing origin/$Base into ${Base}:"; $mt | Select-Object -Skip 1 | Write-Output
            throw "sync stopped, nothing changed: resolve on a feature branch (or ask the repo thread)"
        }
        $new = New-Commit (($mt | Select-Object -First 1).Trim()) @($local, $remote) "Merge origin/$Base into $Base"
        Write-Output "merged origin/$Base into $Base as $new"
    }
    $changed = @(& git diff --no-renames --name-only $local $new)
    $onDev = ((& git symbolic-ref -q --short HEAD) -eq $Base)
    Invoke-Git update-ref -m "git-feature sync" "refs/heads/$Base" $new $local | Out-Null
    if (-not $onDev) { return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("git-feature-sync-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $kept = @()
    try {
        foreach ($path in $changed) {
            $oldBlob = Get-Blob "${local}:$path"
            $newBlob = Get-Blob "${new}:$path"
            $full = Join-Path $repo $path
            $diskBlob = $null
            if (Test-Path -LiteralPath $full -PathType Leaf) { $diskBlob = (& git hash-object -- $path | Select-Object -First 1).Trim() }
            if ($diskBlob -eq $oldBlob) {
                # nobody edited it here: take the incoming version
                if ($newBlob) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
                    Save-Rev "${new}:$path" $full
                } elseif ($diskBlob) { Remove-Item -LiteralPath $full -Force }
                Write-Output "  updated on disk: $path"
            } elseif ($diskBlob -eq $newBlob) {
                # already identical
            } elseif ($diskBlob -and $oldBlob -and $newBlob) {
                # a thread edited it: three-way merge its edits with the incoming change
                $b = Join-Path $tmp 'base'; $t = Join-Path $tmp 'theirs'; $o = Join-Path $tmp 'out'
                Save-Rev "${local}:$path" $b; Save-Rev "${new}:$path" $t
                $union = if ((& git check-attr merge -- $path) -match 'merge: union') { '--union' } else { '' }
                cmd /c "git merge-file -p $union `"$full`" `"$b`" `"$t`" > `"$o`""
                if ($LASTEXITCODE -eq 0) { Copy-Item -LiteralPath $o -Destination $full -Force; Write-Output "  merged into on-disk edits: $path" }
                else { $kept += $path; Write-Output "  LEFT AS IS (conflicts with on-disk edits): $path" }
            } else { $kept += $path; Write-Output "  LEFT AS IS (added/deleted on both sides): $path" }
        }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Invoke-Git reset -q | Out-Null
    if ($kept.Count) { Write-Output "WARNING: commit these only after bringing in $Base's version by hand: $($kept -join ', ')" }
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

    'sync' {
        Sync-Dev
        if ($Push) { Push-Branches @($Base) }
    }

    'merge' {
        Assert-FeatureBranch
        if ($Push) { Sync-Dev }
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
