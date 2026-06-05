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

. (Join-Path $PSScriptRoot "Setup-Engine.ps1")

$catalog = @(

    @{
        Id            = "long-paths"
        Name          = "Long paths (core.longpaths)"
        RequiresAdmin = $true
        Check         = {
            (& git config --system core.longpaths 2>$null) -eq "true"
        }
        Apply         = {
            & git config --system core.longpaths true
        }
    }

    @{
        Id            = "default-branch"
        Name          = "Default branch name (init.defaultBranch = main)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global init.defaultBranch 2>$null) -eq "main"
        }
        Apply         = {
            & git config --global init.defaultBranch main
        }
    }

    @{
        Id            = "autocrlf"
        Name          = "Line endings (core.autocrlf = true)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global core.autocrlf 2>$null) -eq "true"
        }
        Apply         = {
            & git config --global core.autocrlf true
        }
    }

    @{
        Id            = "pull-rebase"
        Name          = "Pull strategy (pull.rebase = false)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global pull.rebase 2>$null) -eq "false"
        }
        Apply         = {
            & git config --global pull.rebase false
        }
    }

    @{
        Id            = "editor-vscode"
        Name          = "Default editor (core.editor = VS Code)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global core.editor 2>$null) -like "*code*"
        }
        Apply         = {
            & git config --global core.editor "code --wait"
        }
    }

    @{
        Id            = "diff-tool-vscode"
        Name          = "Diff tool (diff.tool = vscode)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global diff.tool 2>$null) -eq "vscode"
        }
        Apply         = {
            & git config --global diff.tool vscode
            & git config --global difftool.vscode.cmd 'code --wait --diff $LOCAL $REMOTE'
        }
    }

    @{
        Id            = "merge-tool-vscode"
        Name          = "Merge tool (merge.tool = vscode)"
        RequiresAdmin = $false
        Check         = {
            (& git config --global merge.tool 2>$null) -eq "vscode"
        }
        Apply         = {
            & git config --global merge.tool vscode
            & git config --global mergetool.vscode.cmd 'code --wait $MERGED'
        }
    }

)

Invoke-SetupStage -Stage $Stage -Context $Context -Topic "git" -Catalog $catalog
