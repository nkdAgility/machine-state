#Requires -Version 7.0

# -WhatIf behaviour:
#   Merge always runs (needed to compute what would happen).
#   Export and Build file writes are skipped (ShouldProcess-gated in resolver scripts).
#   Execute shows what would be installed/changed without doing it.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("capture", "apply", "sync", "status", "validate", "export", "merge", "build", "execute")]
    [string]$Action = "sync",

    [string]$MachineName,

    [string[]]$Script,

    [switch]$ExportOnly,

    [switch]$BuildOnly,

    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($VerboseOutput) {
    $VerbosePreference = "Continue"
}

$RepositoryRoot = $PSScriptRoot
$StateRoot = Join-Path $RepositoryRoot "state"
$MachineStateRoot = Join-Path $StateRoot "machines"
$ScriptsRoot = Join-Path $RepositoryRoot "scripts"
$WorkingRoot = Join-Path $RepositoryRoot "working"

$stateEnginePath = Join-Path $ScriptsRoot "State-Engine.ps1"
if (-not (Test-Path -LiteralPath $stateEnginePath)) {
    throw "State engine script not found: $stateEnginePath"
}

. $stateEnginePath

try {
    Initialize-YamlSupport

    if ($Action -eq "validate") {
        Invoke-StageValidate
        return
    }

    $resolvedMachineName = Resolve-MachineName -RequestedMachineName $MachineName
    $machineStatePath = Get-MachineStatePath -ResolvedMachineName $resolvedMachineName
    $machineState = Read-YamlFile -Path $machineStatePath
    $context = Get-MachineContext -ResolvedMachineName $resolvedMachineName -MachineStatePath $machineStatePath -MachineStateData $machineState

    # Filter to specific scripts if -Script was provided
    if ($Script -and $Script.Count -gt 0) {
        $machineState.scripts = @($machineState.scripts | Where-Object { $Script -contains $_ })
        if ($machineState.scripts.Count -eq 0) {
            throw "None of the specified script(s) '$($Script -join ', ')' are configured for machine '$resolvedMachineName'."
        }
        Write-Host "Running subset: $($machineState.scripts -join ', ')"
    }

    switch ($Action) {
        "status" {
            Invoke-StageStatus -Context $context -MachineState $machineState
        }
        "capture" {
            Invoke-StageCapture -Context $context
            if (-not $ExportOnly) {
                Invoke-StageIngest -Context $context -MachineState $machineState
            }
            # Auto-commit any captured changes
            $gitStatus = & git -C $context.RepositoryRoot status --porcelain 2>$null
            if ($gitStatus) {
                Write-Host ""
                Write-Host "  [capture] Committing captured state changes..."
                & git -C $context.RepositoryRoot add --all
                $machineName = $env:COMPUTERNAME
                & git -C $context.RepositoryRoot commit -m "capture: update state from $machineName"
                & git -C $context.RepositoryRoot push
                Write-Host "  [capture] Committed and pushed."
            } else {
                Write-Host "  [capture] No changes to commit."
            }
        }
        "apply" {
            Invoke-StageMerge -Context $context -MachineStateData $machineState
            Invoke-StageBuild -Context $context -MachineState $machineState
            if (-not $BuildOnly) {
                Invoke-StageExecute -Context $context -MachineState $machineState
            }
        }
        "sync" {
            if (-not $ExportOnly) {
                Invoke-StageExport -Context $context -MachineState $machineState
            }
            Invoke-StageMerge -Context $context -MachineStateData $machineState
            Invoke-StageBuild -Context $context -MachineState $machineState
            if (-not $BuildOnly) {
                Invoke-StageExecute -Context $context -MachineState $machineState
            }
        }
        # Legacy verbs for backward compatibility
        "export" {
            Invoke-StageExport -Context $context -MachineState $machineState
        }
        "merge" {
            Invoke-StageMerge -Context $context -MachineStateData $machineState
        }
        "build" {
            if (-not (Test-Path -LiteralPath $context.MergedStateYaml)) {
                Invoke-StageMerge -Context $context -MachineStateData $machineState
            }
            Invoke-StageBuild -Context $context -MachineState $machineState
        }
        "execute" {
            if (-not (Test-Path -LiteralPath $context.MergedStateYaml)) {
                Invoke-StageMerge -Context $context -MachineStateData $machineState
            }
            if ((Get-ChildItem -LiteralPath $context.BuildPath -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                Invoke-StageBuild -Context $context -MachineState $machineState
            }
            Invoke-StageExecute -Context $context -MachineState $machineState
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
