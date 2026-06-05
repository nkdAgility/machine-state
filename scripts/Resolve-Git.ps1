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

. (Join-Path $PSScriptRoot "Resolver-Common.ps1")

function Get-RepoFolderName {
    param([Parameter(Mandatory)][string]$Url)

    $name = $Url.TrimEnd("/")
    if ($name.EndsWith(".git")) { $name = $name.Substring(0, $name.Length - 4) }
    return $name.Split("/")[-1]
}

function Normalize-RepoUrl {
    param([Parameter(Mandatory)][string]$Url)

    $u = $Url.Trim().TrimEnd("/")
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    return $u.ToLowerInvariant()
}

function Expand-StatePath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

function Get-SafeProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-CloneRootFromMachineYaml {
    # Read cloneRoot directly from the machine YAML - safe to call before merge runs
    if (-not (Test-Path -LiteralPath $Context.MachineStatePath)) { return "" }
    $raw = Get-Content -LiteralPath $Context.MachineStatePath -Raw
    $machineYaml = $raw | ConvertFrom-Yaml
    $gitNode = if ($machineYaml -is [System.Collections.IDictionary]) { $machineYaml['git'] } else { Get-SafeProperty $machineYaml 'git' }
    if (-not $gitNode) { return "" }
    $cloneRoot = if ($gitNode -is [System.Collections.IDictionary]) { $gitNode['cloneRoot'] } else { Get-SafeProperty $gitNode 'cloneRoot' }
    if (-not $cloneRoot) { return "" }
    return Expand-StatePath ([string]$cloneRoot)
}

function Get-MergedGitConfig {
    $repos = @()
    $cloneRoot = ""

    if (Test-Path -LiteralPath $Context.MergedStateJson) {
        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $gitNode = Get-SafeProperty $mergedState 'git'
        if ($gitNode) {
            $rawRoot = Get-SafeProperty $gitNode 'cloneRoot'
            if ($rawRoot) { $cloneRoot = Expand-StatePath ([string]$rawRoot) }
            $rawRepos = Get-SafeProperty $gitNode 'repos'
            if ($rawRepos) { $repos = @($rawRepos) }
        }
    }

    # Fall back to machine YAML for cloneRoot if merge hasn't run yet
    if (-not $cloneRoot) {
        $cloneRoot = Get-CloneRootFromMachineYaml
    }

    return [pscustomobject]@{ CloneRoot = $cloneRoot; Repos = $repos }
}

switch ($Stage) {
    "Export" {
        Install-ToolIfMissing -Command git -WingetId Git.Git -DisplayName "Git"

        $config = Get-MergedGitConfig
        New-DirectoryIfMissing -Path $Context.ExportPath

        $found = @()

        if ($config.CloneRoot -and (Test-Path -LiteralPath $config.CloneRoot)) {
            foreach ($dir in Get-ChildItem -LiteralPath $config.CloneRoot -Directory) {
                $gitDir = Join-Path $dir.FullName ".git"
                if (-not (Test-Path -LiteralPath $gitDir)) { continue }

                $remoteUrl = (& git -C $dir.FullName remote get-url origin 2>$null)
                if (-not $remoteUrl) { $remoteUrl = "" }

                $branch = (& git -C $dir.FullName branch --show-current 2>$null)

                $found += [ordered]@{
                    path   = $dir.FullName
                    url    = $remoteUrl.Trim()
                    branch = if ($branch) { $branch.Trim() } else { "" }
                }
            }
        }

        $exportModel = [ordered]@{
            cloneRoot = $config.CloneRoot
            repos     = @($found | Sort-Object url)
        }

        if ($PSCmdlet.ShouldProcess($Context.GitExportPath, "Export git repos")) {
            $exportModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Context.GitExportPath -Encoding UTF8
        }

        Write-Host "$($found.Count) git repo(s) found under $($config.CloneRoot)"
    }

    "Build" {
        $config = Get-MergedGitConfig
        New-DirectoryIfMissing -Path $Context.BuildPath

        if (-not $config.CloneRoot) {
            Write-Host "No git.cloneRoot configured - skipping git build"
            return
        }

        # Load already-cloned repos from export
        $clonedUrls = @()
        if (Test-Path -LiteralPath $Context.GitExportPath) {
            $export = Get-Content -LiteralPath $Context.GitExportPath -Raw | ConvertFrom-Json
            $clonedUrls = @($export.repos | ForEach-Object { Normalize-RepoUrl $_.url })
        }

        $toClone   = @()
        $toPull    = @()
        $pulledUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # Desired repos: clone if missing, pull if present
        foreach ($repo in $config.Repos) {
            $url       = [string](Get-SafeProperty $repo 'url')
            $rawFolder = Get-SafeProperty $repo 'folder'
            $folder    = if ($rawFolder) { [string]$rawFolder } else { Get-RepoFolderName $url }
            $path      = Join-Path $config.CloneRoot $folder

            $alreadyOnDisk = (Test-Path -LiteralPath $path)
            if ($clonedUrls -contains (Normalize-RepoUrl $url) -or $alreadyOnDisk) {
                $toPull += [ordered]@{ url = $url; path = $path; folder = $folder; managed = $true }
                $pulledUrls.Add((Normalize-RepoUrl $url)) | Out-Null
            }
            else {
                $toClone += [ordered]@{ url = $url; path = $path; folder = $folder }
            }
        }

        # Extra local repos not in desired state: pull only, never clone
        if (Test-Path -LiteralPath $Context.GitExportPath) {
            $export = Get-Content -LiteralPath $Context.GitExportPath -Raw | ConvertFrom-Json
            foreach ($found in @($export.repos)) {
                if (-not $found.url) { continue }  # skip repos with no remote
                if (-not $pulledUrls.Contains((Normalize-RepoUrl $found.url))) {
                    $folder = Split-Path -Leaf $found.path
                    $toPull += [ordered]@{ url = $found.url; path = $found.path; folder = $folder; managed = $false }
                    $pulledUrls.Add($found.url) | Out-Null
                }
            }
        }

        $ops = [ordered]@{
            cloneRoot = $config.CloneRoot
            clone     = $toClone
            pull      = $toPull
        }

        if ($PSCmdlet.ShouldProcess($Context.GitOpsPath, "Write git ops manifest")) {
            $ops | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Context.GitOpsPath -Encoding UTF8
        }

        $extraCount = ($toPull | Where-Object { -not (Get-SafeProperty $_ 'managed') }).Count
        Write-Host "git: $($toClone.Count) to clone, $($toPull.Count) to pull ($extraCount local-only)"
    }

    "Execute" {
        Install-ToolIfMissing -Command git -WingetId Git.Git -DisplayName "Git"

        if (-not (Test-Path -LiteralPath $Context.GitOpsPath)) {
            throw "git ops manifest not found at '$($Context.GitOpsPath)'. Run build first."
        }

        $ops = Get-Content -LiteralPath $Context.GitOpsPath -Raw | ConvertFrom-Json

        $toClone = @($ops.clone)
        $toPull  = @($ops.pull)
        $total   = $toClone.Count + $toPull.Count
        $current = 0
        $failed  = @()

        if ($total -eq 0) {
            Write-Host "All git repos are cloned and up to date"
            return
        }

        New-DirectoryIfMissing -Path $ops.cloneRoot

        Write-Host ""
        Write-Host "==> $total git operation(s) to perform"
        Write-Host ""

        foreach ($repo in $toClone) {
            $current++
            $pct   = [int](($current - 1) / $total * 100)
            $label = "[$current/$total] Cloning $($repo.folder)  ($($repo.url))"
            Write-Progress -Activity "git" -Status $label -PercentComplete $pct
            Write-Host $label

            if ($PSCmdlet.ShouldProcess($repo.path, "git clone")) {
                & git clone $repo.url $repo.path
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "[$current/$total] Failed to clone $($repo.url) (exit code $LASTEXITCODE)"
                    $failed += $repo.url
                }
                else {
                    Write-Host "[$current/$total] Done"
                }
            }

            Write-Host ""
        }

        foreach ($repo in $toPull) {
            $current++
            $pct   = [int](($current - 1) / $total * 100)
            $label = "[$current/$total] Pulling $($repo.folder)"
            Write-Progress -Activity "git" -Status $label -PercentComplete $pct
            Write-Host $label

            if ($PSCmdlet.ShouldProcess($repo.path, "git pull")) {
                & git -C $repo.path pull --ff-only
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "[$current/$total] Failed to pull $($repo.path) (exit code $LASTEXITCODE)"
                    $failed += $repo.url
                }
                else {
                    Write-Host "[$current/$total] Done"
                }
            }

            Write-Host ""
        }

        Write-Progress -Activity "git" -Completed

        $succeeded = $total - $failed.Count
        Write-Host "==> git completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"
    }
}
