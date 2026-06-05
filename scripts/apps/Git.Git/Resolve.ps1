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

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

if ($Stage -eq "Execute" -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "git not found on PATH - skipping configuration"
    return
}

$catalog = @(

    @{
        Id            = "git-default-branch"
        Name          = "Git default branch name (main)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global init.defaultBranch 2>$null) -eq "main"
        }
        Apply         = {
            & git config --global init.defaultBranch main
        }
    }

    @{
        Id            = "git-autocrlf"
        Name          = "Git line endings (autocrlf = true)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global core.autocrlf 2>$null) -eq "true"
        }
        Apply         = {
            & git config --global core.autocrlf true
        }
    }

    @{
        Id            = "git-longpaths"
        Name          = "Git long path support"
        RequiresAdmin = $false
        Check         = {
            (& git config --global core.longpaths 2>$null) -eq "true"
        }
        Apply         = {
            & git config --global core.longpaths true
        }
    }

    @{
        Id            = "git-push-default"
        Name          = "Git push default (current)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global push.default 2>$null) -eq "current"
        }
        Apply         = {
            & git config --global push.default current
        }
    }

    @{
        Id            = "git-pull-rebase"
        Name          = "Git pull rebase (false — merge, not rebase)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global pull.rebase 2>$null) -eq "false"
        }
        Apply         = {
            & git config --global pull.rebase false
        }
    }

    @{
        Id            = "git-fetch-prune"
        Name          = "Git fetch prune (auto-prune remote tracking branches)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global fetch.prune 2>$null) -eq "true"
        }
        Apply         = {
            & git config --global fetch.prune true
        }
    }

)

Invoke-SetupStage -Stage $Stage -Context $Context -Topic "git" -Catalog $catalog
