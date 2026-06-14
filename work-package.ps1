#Requires -Version 7.0

<#
.SYNOPSIS
    Start a work package — open its repos in VS Code and a Windows Terminal window
    with one named tab per repo.

.DESCRIPTION
    Work packages are declared in state YAML under the `workPackages:` section
    (see state/common-personal.yaml). This launcher reads the merged set for the
    current machine via the state engine, so packages stay state-driven.

    The repo root is added to the user PATH by the `machine-state-path` setup topic
    (state/win/windows-base.yaml), so once a machine has been set up you can run
    `work-package <id>` from anywhere.

.PARAMETER Name
    The id of the work package to start. Omit to list available packages.

.PARAMETER List
    List available work packages and exit (same as omitting -Name).

.EXAMPLE
    work-package
    Lists the available work packages.

.EXAMPLE
    work-package website
    Opens every repo in the 'website' package in VS Code and a Windows Terminal
    window with a named tab per repo.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Name,

    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The state engine relies on these script-scope paths (mirrors machine-state.ps1).
$RepositoryRoot   = $PSScriptRoot
$StateRoot        = Join-Path $RepositoryRoot "state"
$MachineStateRoot = Join-Path $StateRoot "machines"

. (Join-Path $RepositoryRoot "scripts\State-Engine.ps1")

Initialize-YamlSupport

$machineName      = Resolve-MachineName
$machineStatePath = Get-MachineStatePath -ResolvedMachineName $machineName
$packages         = @(Get-MergedWorkPackages -MachineStatePath $machineStatePath)

function Write-PackageList {
    if ($packages.Count -eq 0) {
        Write-Host "No work packages are defined for machine '$machineName'." -ForegroundColor Yellow
        Write-Host "Declare them under 'workPackages:' in a referenced state file (e.g. state/common-personal.yaml)."
        return
    }

    Write-Host ""
    Write-Host "Work packages for '$machineName':" -ForegroundColor Cyan
    Write-Host ""
    foreach ($pkg in $packages) {
        $id    = [string](Get-ObjectValue -Object $pkg -Name "id")
        $label = [string](Get-ObjectValue -Object $pkg -Name "name")
        $repos = @(Get-ObjectValue -Object $pkg -Name "repos")
        $count = $repos.Count
        Write-Host ("  {0,-16} {1} ({2} repo{3})" -f $id, $label, $count, $(if ($count -eq 1) { '' } else { 's' }))
    }
    Write-Host ""
    Write-Host "Start one with:  work-package <id>"
}

if ($List -or -not $Name) {
    Write-PackageList
    return
}

$package = $packages | Where-Object {
    [string](Get-ObjectValue -Object $_ -Name "id") -eq $Name
} | Select-Object -First 1

if (-not $package) {
    Write-Host "Unknown work package '$Name'." -ForegroundColor Red
    Write-PackageList
    exit 1
}

$label           = [string](Get-ObjectValue -Object $package -Name "name")
$terminalProfile = [string](Get-ObjectValue -Object $package -Name "terminalProfile")
if (-not $terminalProfile) { $terminalProfile = "PowerShell" }

$repos = @(Get-ObjectValue -Object $package -Name "repos") |
    ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) }

if ($repos.Count -eq 0) {
    Write-Host "Work package '$Name' has no repos to open." -ForegroundColor Yellow
    return
}

Write-Host "Starting work package '$label' ($($repos.Count) repos)..." -ForegroundColor Cyan

# Warn about any repo folders that are missing, but keep going.
$present = foreach ($repo in $repos) {
    if (Test-Path -LiteralPath $repo) {
        $repo
    } else {
        Write-Warning "Repo folder not found, skipping: $repo"
    }
}
$present = @($present)

if ($present.Count -eq 0) {
    Write-Host "None of the package's repo folders exist on this machine." -ForegroundColor Red
    exit 1
}

# Open each repo in VS Code (if available).
if (Get-Command code -ErrorAction SilentlyContinue) {
    foreach ($repo in $present) {
        Write-Host "  code $repo"
        & code $repo
    }
} else {
    Write-Warning "'code' not found on PATH — skipping VS Code. In VS Code run 'Shell Command: Install code command in PATH'."
}

# Open a single Windows Terminal window with one named tab per repo.
if (Get-Command wt -ErrorAction SilentlyContinue) {
    $wtArgs = [System.Collections.Generic.List[string]]::new()
    $first = $true
    foreach ($repo in $present) {
        $title = Split-Path -Path $repo -Leaf
        if (-not $first) { $wtArgs.Add(';') }   # wt tab separator (passed as its own argv token)
        $wtArgs.Add('new-tab')
        $wtArgs.Add('--profile'); $wtArgs.Add($terminalProfile)
        $wtArgs.Add('--title');   $wtArgs.Add($title)
        $wtArgs.Add('-d');        $wtArgs.Add($repo)
        $first = $false
    }
    Write-Host "  wt (opening $($present.Count) tabs)"
    & wt @wtArgs
} else {
    Write-Warning "'wt' (Windows Terminal) not found on PATH — skipping terminal tabs."
}

Write-Host "Done." -ForegroundColor Green
