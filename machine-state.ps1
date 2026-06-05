#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("capture", "apply", "sync", "status", "validate", "export", "merge", "build", "execute")]
    [string]$Action = "sync",

    [string]$MachineName,

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

    switch ($Action) {
        "status" {
            Invoke-StageStatus -Context $context -MachineState $machineState
        }
        "capture" {
            Invoke-StageExport -Context $context -MachineState $machineState
            if (-not $ExportOnly) {
                Invoke-StageIngest -Context $context -MachineState $machineState
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
            if (-not (Test-Path -LiteralPath $context.WingetImportPath)) {
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
