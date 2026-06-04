#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("export", "merge", "build", "execute", "sync", "status", "validate")]
    [string]$Action = "sync",

    [string]$MachineName,

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

function Initialize-YamlSupport {
    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        return
    }

    $yamlModule = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
    if (-not $yamlModule) {
        throw "YAML support is required. Install module 'powershell-yaml' or use a PowerShell with ConvertFrom-Yaml and ConvertTo-Yaml available."
    }

    Import-Module powershell-yaml -ErrorAction Stop

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "YAML support could not be loaded. Ensure ConvertFrom-Yaml and ConvertTo-Yaml are available."
    }
}

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-AvailableMachineNames {
    if (-not (Test-Path -LiteralPath $MachineStateRoot)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $MachineStateRoot -Filter "*.yaml" |
        Sort-Object -Property BaseName |
        ForEach-Object { $_.BaseName }
}

function Resolve-MachineName {
    param(
        [string]$RequestedMachineName
    )

    $available = @(Get-AvailableMachineNames)
    if ($available.Count -eq 0) {
        throw "No machine state files were found under '$MachineStateRoot'."
    }

    if ($RequestedMachineName) {
        if ($available -contains $RequestedMachineName) {
            return $RequestedMachineName
        }

        throw "Unknown machine '$RequestedMachineName'. Available machines: $($available -join ', ')."
    }

    $detected = [string]$env:COMPUTERNAME
    if ($detected -and ($available -contains $detected)) {
        return $detected
    }

    Write-Host "Detected machine '$detected' does not match a configured machine."
    Write-Host "Available machines:"
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host "[$($i + 1)] $($available[$i])"
    }

    $selection = Read-Host "Choose a machine by number"
    $parsedSelection = 0
    if (-not [int]::TryParse($selection, [ref]$parsedSelection)) {
        throw "Invalid machine selection '$selection'."
    }

    $index = $parsedSelection - 1
    if ($index -lt 0 -or $index -ge $available.Count) {
        throw "Selection '$selection' is out of range."
    }

    return $available[$index]
}

function Get-MachineStatePath {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedMachineName
    )

    return Join-Path $MachineStateRoot ("{0}.yaml" -f $ResolvedMachineName)
}

function Read-YamlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "YAML file not found: $Path"
    }

    $yamlText = Get-Content -LiteralPath $Path -Raw
    $fromYamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction Stop

    if ($fromYamlCommand.Parameters.ContainsKey("Yaml")) {
        return ConvertFrom-Yaml -Yaml $yamlText
    }

    return $yamlText | ConvertFrom-Yaml
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Write-YamlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $toYamlCommand = Get-Command ConvertTo-Yaml -ErrorAction Stop
    if ($toYamlCommand.Parameters.ContainsKey("Data")) {
        $yaml = ConvertTo-Yaml -Data $Value
    }
    elseif ($toYamlCommand.Parameters.ContainsKey("InputObject")) {
        $yaml = ConvertTo-Yaml -InputObject $Value
    }
    else {
        $yaml = $Value | ConvertTo-Yaml
    }

    Set-Content -LiteralPath $Path -Value $yaml -Encoding UTF8
}

function Merge-PackageSource {
    param(
        [AllowNull()]
        [array]$Packages
    )

    $byId = @{}

    foreach ($package in @($Packages)) {
        $packageId = Get-ObjectValue -Object $package -Name "id"
        if ($null -eq $package -or -not $packageId) {
            continue
        }

        $byId[[string]$packageId] = $package
    }

    $result = @()
    foreach ($id in ($byId.Keys | Sort-Object)) {
        $result += $byId[$id]
    }

    return $result
}

function Get-SourcePackages {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    if ($null -eq $StateObject) {
        return @()
    }

    $wingetNode = Get-ObjectValue -Object $StateObject -Name "winget"
    if (-not $wingetNode) {
        return @()
    }

    $packagesNode = Get-ObjectValue -Object $wingetNode -Name "packages"
    if (-not $packagesNode) {
        return @()
    }

    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    return @($sourceNode)
}

function Merge-MachineState {
    param(
        [Parameter(Mandatory)]
        [string]$MachineStatePath
    )

    $machineState = Read-YamlFile -Path $MachineStatePath

    $wingetPackages = @()
    $msstorePackages = @()

    foreach ($relativePath in @($machineState.state)) {
        $resolvedSharedPath = Join-Path (Split-Path -Parent $MachineStatePath) $relativePath
        $sharedState = Read-YamlFile -Path $resolvedSharedPath

        $wingetPackages += @(Get-SourcePackages -StateObject $sharedState -SourceName "winget")
        $msstorePackages += @(Get-SourcePackages -StateObject $sharedState -SourceName "msstore")
    }

    $wingetPackages += @(Get-SourcePackages -StateObject $machineState -SourceName "winget")
    $msstorePackages += @(Get-SourcePackages -StateObject $machineState -SourceName "msstore")

    $merged = [ordered]@{
        name         = [string]$machineState.name
        platform     = [string]$machineState.platform
        architecture = [string]$machineState.architecture
        state        = @($machineState.state)
        scripts      = @($machineState.scripts)
        winget       = [ordered]@{
            packages = [ordered]@{
                winget  = Merge-PackageSource -Packages $wingetPackages
                msstore = Merge-PackageSource -Packages $msstorePackages
            }
        }
    }

    return [pscustomobject]$merged
}

function Get-MachineContext {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedMachineName,

        [Parameter(Mandatory)]
        [string]$MachineStatePath
    )

    $machineState = Read-YamlFile -Path $MachineStatePath
    $workingPath = Join-Path $WorkingRoot $ResolvedMachineName

    $context = [pscustomobject]@{
        MachineName      = $ResolvedMachineName
        Platform         = [string]$machineState.platform
        Architecture     = [string]$machineState.architecture
        RepositoryRoot   = $RepositoryRoot
        MachineStatePath = $MachineStatePath
        WorkingPath      = $workingPath
        ExportPath       = Join-Path $workingPath "export"
        MergePath        = Join-Path $workingPath "merge"
        BuildPath        = Join-Path $workingPath "build"
        LogsPath         = Join-Path $workingPath "logs"
        MergedStateYaml  = Join-Path (Join-Path $workingPath "merge") "machine-state.merged.yaml"
        MergedStateJson  = Join-Path (Join-Path $workingPath "merge") "machine-state.merged.json"
        WingetImportPath = Join-Path (Join-Path $workingPath "build") "winget.import.json"
        WingetExportPath = Join-Path (Join-Path $workingPath "export") "winget.export.json"
    }

    New-DirectoryIfMissing -Path $context.WorkingPath
    New-DirectoryIfMissing -Path $context.ExportPath
    New-DirectoryIfMissing -Path $context.MergePath
    New-DirectoryIfMissing -Path $context.BuildPath
    New-DirectoryIfMissing -Path $context.LogsPath

    return $context
}

function Invoke-ResolverScript {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,

        [Parameter(Mandatory)]
        [ValidateSet("Export", "Build", "Execute")]
        [string]$Stage,

        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $resolverPath = Join-Path $ScriptsRoot $ScriptName
    if (-not (Test-Path -LiteralPath $resolverPath)) {
        throw "Resolver script not found: $resolverPath"
    }

    & $resolverPath -Stage $Stage -Context $Context -WhatIf:$WhatIfPreference
}

function Invoke-StageExport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$MachineState
    )

    foreach ($scriptName in @($MachineState.scripts)) {
        Invoke-ResolverScript -ScriptName $scriptName -Stage Export -Context $Context
    }
}

function Invoke-StageMerge {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $mergedState = Merge-MachineState -MachineStatePath $Context.MachineStatePath

    Write-YamlFile -Path $Context.MergedStateYaml -Value $mergedState
    $mergedState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Context.MergedStateJson -Encoding UTF8
}

function Invoke-StageBuild {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$MachineState
    )

    foreach ($scriptName in @($MachineState.scripts)) {
        Invoke-ResolverScript -ScriptName $scriptName -Stage Build -Context $Context
    }
}

function Invoke-StageExecute {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$MachineState
    )

    foreach ($scriptName in @($MachineState.scripts)) {
        Invoke-ResolverScript -ScriptName $scriptName -Stage Execute -Context $Context
    }
}

function Invoke-StageStatus {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$MachineState
    )

    Write-Host "Machine Name: $($Context.MachineName)"
    Write-Host "Machine State: $($Context.MachineStatePath)"
    Write-Host "Platform: $($Context.Platform)"
    Write-Host "Architecture: $($Context.Architecture)"
    Write-Host "Referenced State Files:"
    foreach ($stateFile in @($MachineState.state)) {
        Write-Host "- $stateFile"
    }
    Write-Host "Scripts:"
    foreach ($scriptName in @($MachineState.scripts)) {
        Write-Host "- $scriptName"
    }
    Write-Host "Working Path: $($Context.WorkingPath)"
}

function Test-PackageShape {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [array]$Packages,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [Parameter(Mandatory)]
        [string]$Machine
    )

    foreach ($pkg in @($Packages)) {
        if ($null -eq $pkg) {
            throw "Null package entry found for source '$SourceName' in machine '$Machine'."
        }

        $id = Get-ObjectValue -Object $pkg -Name "id"
        if (-not $id) {
            throw "Package entry without 'id' in source '$SourceName' for machine '$Machine'."
        }

        $name = Get-ObjectValue -Object $pkg -Name "name"
        if (-not $name) {
            throw "Package '$id' without 'name' in source '$SourceName' for machine '$Machine'."
        }
    }
}

function Invoke-StageValidate {
    $available = @(Get-AvailableMachineNames)
    if ($available.Count -eq 0) {
        throw "No machine YAML files found under '$MachineStateRoot'."
    }

    foreach ($machine in $available) {
        $machinePath = Get-MachineStatePath -ResolvedMachineName $machine
        $machineState = Read-YamlFile -Path $machinePath

        if (-not $machineState.name -or -not $machineState.platform -or -not $machineState.architecture) {
            throw "Machine '$machine' is missing required fields (name/platform/architecture)."
        }

        foreach ($relativePath in @($machineState.state)) {
            $resolvedPath = Join-Path (Split-Path -Parent $machinePath) $relativePath
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                throw "Referenced state file not found for machine '$machine': $resolvedPath"
            }
        }

        foreach ($scriptName in @($machineState.scripts)) {
            $scriptPath = Join-Path $ScriptsRoot $scriptName
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                throw "Resolver script not found for machine '$machine': $scriptPath"
            }
        }

        $mergedState = Merge-MachineState -MachineStatePath $machinePath

        $mergedWinget = Get-ObjectValue -Object $mergedState -Name "winget"
        $mergedPackages = Get-ObjectValue -Object $mergedWinget -Name "packages"
        if ($mergedPackages -is [System.Collections.IDictionary]) {
            $packageSources = @($mergedPackages.Keys)
        }
        else {
            $packageSources = @($mergedPackages.PSObject.Properties.Name)
        }
        $invalidSources = $packageSources | Where-Object { $_ -notin @("winget", "msstore") }
        if ($invalidSources) {
            throw "Machine '$machine' contains invalid package sources: $($invalidSources -join ', ')."
        }

        Test-PackageShape -Packages @(Get-SourcePackages -StateObject $mergedState -SourceName "winget") -SourceName "winget" -Machine $machine
        Test-PackageShape -Packages @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore") -SourceName "msstore" -Machine $machine

        $allPackages = @(Get-SourcePackages -StateObject $mergedState -SourceName "winget") + @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore")
        $ids = @()
        foreach ($pkg in $allPackages) {
            $id = Get-ObjectValue -Object $pkg -Name "id"
            if ($id) {
                $ids += [string]$id
            }
        }
        if (($ids | Sort-Object -Unique).Count -ne $ids.Count) {
            throw "Duplicate package IDs remain after merge for machine '$machine'."
        }

        $context = Get-MachineContext -ResolvedMachineName $machine -MachineStatePath $machinePath

        Write-YamlFile -Path $context.MergedStateYaml -Value $mergedState
        $mergedState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $context.MergedStateJson -Encoding UTF8
        foreach ($scriptName in @($machineState.scripts)) {
            Invoke-ResolverScript -ScriptName $scriptName -Stage Build -Context $context
        }

        if (-not (Test-Path -LiteralPath $context.WingetImportPath)) {
            throw "Winget import JSON missing for machine '$machine': $($context.WingetImportPath)"
        }

        $json = Get-Content -LiteralPath $context.WingetImportPath -Raw | ConvertFrom-Json
        if (-not $json.Sources) {
            throw "Winget import JSON for machine '$machine' does not contain 'Sources'."
        }

        foreach ($source in @($json.Sources)) {
            foreach ($package in @($source.Packages)) {
                if (-not $package.PackageIdentifier) {
                    throw "Winget import JSON for machine '$machine' contains a package without PackageIdentifier."
                }
            }
        }
    }

    Write-Host "Validation completed successfully for $($available.Count) machine(s)."
}

try {
    Initialize-YamlSupport

    if ($Action -eq "validate") {
        Invoke-StageValidate
        return
    }

    $resolvedMachineName = Resolve-MachineName -RequestedMachineName $MachineName
    $machineStatePath = Get-MachineStatePath -ResolvedMachineName $resolvedMachineName
    $machineState = Read-YamlFile -Path $machineStatePath
    $context = Get-MachineContext -ResolvedMachineName $resolvedMachineName -MachineStatePath $machineStatePath

    switch ($Action) {
        "status" {
            Invoke-StageStatus -Context $context -MachineState $machineState
        }
        "export" {
            Invoke-StageExport -Context $context -MachineState $machineState
        }
        "merge" {
            Invoke-StageMerge -Context $context
        }
        "build" {
            if (-not (Test-Path -LiteralPath $context.MergedStateYaml)) {
                Invoke-StageMerge -Context $context
            }
            Invoke-StageBuild -Context $context -MachineState $machineState
        }
        "execute" {
            if (-not (Test-Path -LiteralPath $context.MergedStateYaml)) {
                Invoke-StageMerge -Context $context
            }
            if (-not (Test-Path -LiteralPath $context.WingetImportPath)) {
                Invoke-StageBuild -Context $context -MachineState $machineState
            }
            Invoke-StageExecute -Context $context -MachineState $machineState
        }
        "sync" {
            Invoke-StageExport -Context $context -MachineState $machineState
            Invoke-StageMerge -Context $context
            Invoke-StageBuild -Context $context -MachineState $machineState
            Invoke-StageExecute -Context $context -MachineState $machineState
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
