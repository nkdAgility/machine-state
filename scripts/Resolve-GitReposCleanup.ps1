#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Export", "Build", "Execute")]
    [string]$Stage,

    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CloneRoot {
    $gitExportPath = Join-Path $Context.ExportPath "git.export.json"
    if (Test-Path -LiteralPath $gitExportPath) {
        $export = Get-Content -LiteralPath $gitExportPath -Raw | ConvertFrom-Json
        if ($export.cloneRoot) { return $export.cloneRoot }
    }
    if (Test-Path -LiteralPath $Context.MergedStateJson) {
        $state = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $root  = $state.git.cloneRoot
        if ($root) { return [System.Environment]::ExpandEnvironmentVariables([string]$root) }
    }
    return ""
}

function Get-DefaultBranch {
    param([string]$RepoPath)
    $branch = (& git -C $RepoPath symbolic-ref refs/remotes/origin/HEAD --short 2>$null)
    if ($branch) { return $branch -replace "^origin/", "" }
    $branch = (& git -C $RepoPath branch -r 2>$null) |
        Select-String "origin/main" |
        ForEach-Object { $_.ToString().Trim() -replace "origin/", "" } |
        Select-Object -First 1
    if ($branch) { return [string]$branch }
    $branch = (& git -C $RepoPath branch -r 2>$null) |
        Select-String "origin/master" |
        ForEach-Object { $_.ToString().Trim() -replace "origin/", "" } |
        Select-Object -First 1
    return ($branch ? [string]$branch : $null)
}

function Get-BranchesToClean {
    param([string]$RepoPath)

    $main = Get-DefaultBranch -RepoPath $RepoPath
    if (-not $main) { return @{ Skip = $true } }

    $localBranches = @(& git -C $RepoPath branch 2>$null |
        ForEach-Object { $_.ToString().Trim() -replace "^\* ", "" } |
        Where-Object { $_ -and $_ -ne $main -and $_ -ne "main" -and $_ -ne "master" })

    $mergedBranches = @(& git -C $RepoPath branch --merged $main 2>$null |
        ForEach-Object { $_.ToString().Trim() -replace "^\* ", "" } |
        Where-Object { $_ -and $_ -ne $main -and $_ -ne "main" -and $_ -ne "master" })

    $remoteBranches = @(& git -C $RepoPath branch -r 2>$null |
        ForEach-Object { $_.ToString().Trim() -replace "^origin/", "" } |
        Where-Object { $_ -and $_ -notmatch "^HEAD" })

    $autoDelete = @()
    $needsReview = @()

    foreach ($branch in $localBranches) {
        if ($mergedBranches -contains $branch) {
            $autoDelete += [ordered]@{ branch = $branch; reason = "merged into $main" }
            continue
        }

        $ahead = [int](& git -C $RepoPath rev-list --count "$main..$branch" -- 2>$null)
        if ($ahead -eq 0) {
            $autoDelete += [ordered]@{ branch = $branch; reason = "no unique commits vs $main" }
            continue
        }

        if ($remoteBranches -notcontains $branch) {
            $needsReview += [ordered]@{ branch = $branch; reason = "$ahead unique commit(s), no remote tracking branch" }
        }
        # branches with unique commits AND a remote are kept silently
    }

    return @{
        Skip        = $false
        Main        = $main
        AutoDelete  = $autoDelete
        NeedsReview = $needsReview
    }
}

switch ($Stage) {

    "Export" {
        $cloneRoot = Get-CloneRoot
        if (-not $cloneRoot -or -not (Test-Path -LiteralPath $cloneRoot)) {
            Write-Host "git-cleanup: no clone root configured - skipping"
            return
        }

        $totalAuto   = 0
        $totalReview = 0

        foreach ($dir in Get-ChildItem -LiteralPath $cloneRoot -Directory) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName ".git"))) { continue }
            & git -C $dir.FullName fetch --prune --quiet 2>$null
            $result = Get-BranchesToClean -RepoPath $dir.FullName
            if ($result.Skip) { continue }
            $totalAuto   += $result.AutoDelete.Count
            $totalReview += $result.NeedsReview.Count
        }

        Write-Host "git-cleanup: $totalAuto branch(es) to auto-delete, $totalReview need manual review"
    }

    "Build" {
        # nothing to build - no intermediate manifest needed
    }

    "Execute" {
        $cloneRoot = Get-CloneRoot
        if (-not $cloneRoot -or -not (Test-Path -LiteralPath $cloneRoot)) {
            Write-Host "git-cleanup: no clone root configured - skipping"
            return
        }

        $deleted    = 0
        $skipped    = 0
        $reviewed   = @()

        Write-Host ""
        Write-Host "==> git-cleanup: pruning merged and redundant local branches"
        Write-Host ""

        foreach ($dir in Get-ChildItem -LiteralPath $cloneRoot -Directory) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName ".git"))) { continue }

            Write-Host "--- $($dir.Name)"

            & git -C $dir.FullName fetch --prune --quiet 2>$null

            $result = Get-BranchesToClean -RepoPath $dir.FullName
            if ($result.Skip) {
                Write-Host "    (no main/master branch found - skipped)"
                continue
            }

            # Checkout default branch before deleting others
            if ($result.AutoDelete.Count -gt 0) {
                & git -C $dir.FullName checkout $result.Main --quiet 2>$null
            }

            foreach ($entry in $result.AutoDelete) {
                if ($PSCmdlet.ShouldProcess("$($dir.Name)/$($entry.branch)", "git branch -d")) {
                    & git -C $dir.FullName branch -d $entry.branch 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    deleted  $($entry.branch)  ($($entry.reason))"
                        $deleted++
                    }
                    else {
                        Write-Warning "    failed to delete $($entry.branch)"
                        $skipped++
                    }
                }
            }

            foreach ($entry in $result.NeedsReview) {
                Write-Host "    review   $($entry.branch)  ($($entry.reason))"
                $reviewed += "$($dir.Name)/$($entry.branch): $($entry.reason)"
            }
        }

        Write-Host ""
        Write-Host "==> git-cleanup: $deleted deleted, $($reviewed.Count) need manual review$(if ($skipped -gt 0) { ", $skipped failed" })"

        if ($reviewed.Count -gt 0) {
            $logPath = Join-Path $Context.LogsPath "git-cleanup-review.txt"
            $reviewed | Set-Content -LiteralPath $logPath -Encoding UTF8
            Write-Host "    branches needing review logged to: $logPath"
        }
    }
}
