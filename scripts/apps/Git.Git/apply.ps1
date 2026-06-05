#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "git not found on PATH - skipping configuration"
    return
}

$catalog = @(
    @{
        Id            = "default-branch"
        Name          = "Git default branch name (main)"
        RequiresAdmin = $false
        Check         = { (& git config --global init.defaultBranch 2>$null) -eq "main" }
        Apply         = { & git config --global init.defaultBranch main }
    }
    @{
        Id            = "autocrlf"
        Name          = "Git line endings (autocrlf = true)"
        RequiresAdmin = $false
        Check         = { (& git config --global core.autocrlf 2>$null) -eq "true" }
        Apply         = { & git config --global core.autocrlf true }
    }
    @{
        Id            = "long-paths"
        Name          = "Git long path support"
        RequiresAdmin = $false
        Check         = { (& git config --global core.longpaths 2>$null) -eq "true" }
        Apply         = { & git config --global core.longpaths true }
    }
    @{
        Id            = "push-default"
        Name          = "Git push default (current)"
        RequiresAdmin = $false
        Check         = { (& git config --global push.default 2>$null) -eq "current" }
        Apply         = { & git config --global push.default current }
    }
    @{
        Id            = "pull-rebase"
        Name          = "Git pull rebase (false — merge, not rebase)"
        RequiresAdmin = $false
        Check         = { (& git config --global pull.rebase 2>$null) -eq "false" }
        Apply         = { & git config --global pull.rebase false }
    }
    @{
        Id            = "fetch-prune"
        Name          = "Git fetch prune (auto-prune remote tracking branches)"
        RequiresAdmin = $false
        Check         = { (& git config --global fetch.prune 2>$null) -eq "true" }
        Apply         = { & git config --global fetch.prune true }
    }
    @{
        Id            = "editor-vscode"
        Name          = "Git editor (VS Code)"
        RequiresAdmin = $false
        Check         = { (& git config --global core.editor 2>$null) -eq "code --wait" }
        Apply         = { & git config --global core.editor "code --wait" }
    }
    @{
        Id            = "diff-tool-vscode"
        Name          = "Git diff tool (VS Code)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global diff.tool 2>$null) -eq "vscode" -and
            (& git config --global difftool.vscode.cmd 2>$null) -eq 'code --wait --diff $LOCAL $REMOTE'
        }
        Apply         = {
            & git config --global diff.tool vscode
            & git config --global difftool.vscode.cmd 'code --wait --diff $LOCAL $REMOTE'
        }
    }
    @{
        Id            = "merge-tool-vscode"
        Name          = "Git merge tool (VS Code)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global merge.tool 2>$null) -eq "vscode" -and
            (& git config --global mergetool.vscode.cmd 2>$null) -eq 'code --wait $MERGED'
        }
        Apply         = {
            & git config --global merge.tool vscode
            & git config --global mergetool.vscode.cmd 'code --wait $MERGED'
        }
    }
)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "git" -Catalog $catalog
