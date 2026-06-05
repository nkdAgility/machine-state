#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Initialize-YamlSupport {
    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        return
    }

    $yamlModule = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
    if (-not $yamlModule) {
        throw "YAML support is required. Install module 'powershell-yaml' or use a PowerShell with ConvertFrom-Yaml and ConvertTo-Yaml available."
    }

    # Suppress WhatIf noise from module alias creation
    $savedWhatIf = $WhatIfPreference
    $script:WhatIfPreference = $false
    try {
        Import-Module powershell-yaml -ErrorAction Stop
    }
    finally {
        $script:WhatIfPreference = $savedWhatIf
    }

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

function Get-SectionPackages {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,

        [Parameter(Mandatory)]
        [string]$SectionName,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    if ($null -eq $StateObject) {
        return @()
    }

    $sectionNode = Get-ObjectValue -Object $StateObject -Name $SectionName
    if (-not $sectionNode) {
        return @()
    }

    $packagesNode = Get-ObjectValue -Object $sectionNode -Name "packages"
    if (-not $packagesNode) {
        return @()
    }

    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    return @($sourceNode)
}

function Get-ExclusionIds {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    if ($null -eq $StateObject) {
        return @()
    }

    $exclusionsNode = Get-ObjectValue -Object $StateObject -Name "exclusions"
    if (-not $exclusionsNode) {
        return @()
    }

    $packagesNode = Get-ObjectValue -Object $exclusionsNode -Name "packages"
    if (-not $packagesNode) {
        return @()
    }

    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    $result = @()
    foreach ($id in @($sourceNode)) {
        if ($id) {
            $result += [string]$id
        }
    }

    return @($result | Sort-Object -Unique)
}

function Get-CombinedExclusionIds {
    param(
        [Parameter(Mandatory)]
        [array]$StateObjects,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $result = @()
    foreach ($stateObject in @($StateObjects)) {
        $result += @(Get-ExclusionIds -StateObject $stateObject -SourceName $SourceName)
    }

    return @($result | Sort-Object -Unique)
}

function Get-SetupTopicIds {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$StateObject,
        [Parameter(Mandatory)][string]$Topic
    )

    if ($null -eq $StateObject) { return @() }
    $setupNode = Get-ObjectValue -Object $StateObject -Name "setup"
    if (-not $setupNode) { return @() }
    $topicNode = Get-ObjectValue -Object $setupNode -Name $Topic
    if (-not $topicNode) { return @() }
    return @($topicNode | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Merge-SetupTopicIds {
    param([AllowNull()][array]$Ids)
    return @($Ids | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-GitRepos {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$StateObject
    )

    if ($null -eq $StateObject) { return @() }

    $gitNode = Get-ObjectValue -Object $StateObject -Name "git"
    if (-not $gitNode) { return @() }

    $reposNode = Get-ObjectValue -Object $gitNode -Name "repos"
    if (-not $reposNode) { return @() }

    return @($reposNode)
}

function Merge-GitRepos {
    param(
        [AllowNull()]
        [array]$Repos
    )

    $byUrl = @{}
    foreach ($repo in @($Repos)) {
        $url = Get-ObjectValue -Object $repo -Name "url"
        if ($null -eq $repo -or -not $url) { continue }
        $byUrl[[string]$url.ToLowerInvariant()] = $repo
    }

    $result = @()
    foreach ($key in ($byUrl.Keys | Sort-Object)) {
        $result += $byUrl[$key]
    }
    return $result
}

function Merge-MachineState {
    param(
        [Parameter(Mandatory)]
        [string]$MachineStatePath,

        [object]$MachineStateData = $null
    )

    $machineState = if ($null -ne $MachineStateData) { $MachineStateData } else { Read-YamlFile -Path $MachineStatePath }
    $stateObjects = @()

    $wingetPackages  = @()
    $msstorePackages = @()
    $npmPackages     = @()
    $uvPackages      = @()
    $gitRepos        = @()
    $setupWindows    = @()
    $setupGit        = @()

    foreach ($relativePath in @($machineState.state)) {
        $resolvedSharedPath = Join-Path (Split-Path -Parent $MachineStatePath) $relativePath
        $sharedState = Read-YamlFile -Path $resolvedSharedPath
        $stateObjects += $sharedState

        $wingetPackages  += @(Get-SourcePackages -StateObject $sharedState -SourceName "winget")
        $msstorePackages += @(Get-SourcePackages -StateObject $sharedState -SourceName "msstore")
        $npmPackages     += @(Get-SectionPackages -StateObject $sharedState -SectionName "node" -SourceName "npm")
        $uvPackages      += @(Get-SectionPackages -StateObject $sharedState -SectionName "uv" -SourceName "uv")
        $gitRepos        += @(Get-GitRepos -StateObject $sharedState)
        $setupWindows    += @(Get-SetupTopicIds -StateObject $sharedState -Topic "windows")
        $setupGit        += @(Get-SetupTopicIds -StateObject $sharedState -Topic "git")
    }

    $stateObjects += $machineState

    $wingetPackages  += @(Get-SourcePackages -StateObject $machineState -SourceName "winget")
    $msstorePackages += @(Get-SourcePackages -StateObject $machineState -SourceName "msstore")
    $npmPackages     += @(Get-SectionPackages -StateObject $machineState -SectionName "node" -SourceName "npm")
    $uvPackages      += @(Get-SectionPackages -StateObject $machineState -SectionName "uv" -SourceName "uv")
    $gitRepos        += @(Get-GitRepos -StateObject $machineState)
    $setupWindows    += @(Get-SetupTopicIds -StateObject $machineState -Topic "windows")
    $setupGit        += @(Get-SetupTopicIds -StateObject $machineState -Topic "git")

    # cloneRoot is machine-specific — read from machine YAML only
    $machineGitNode = Get-ObjectValue -Object $machineState -Name "git"
    $cloneRoot = if ($machineGitNode) { [string](Get-ObjectValue -Object $machineGitNode -Name "cloneRoot") } else { "" }

    $wingetExclusions = @(Get-CombinedExclusionIds -StateObjects $stateObjects -SourceName "winget")
    $msstoreExclusions = @(Get-CombinedExclusionIds -StateObjects $stateObjects -SourceName "msstore")
    $npmExclusions = @(Get-CombinedExclusionIds -StateObjects $stateObjects -SourceName "npm")
    $uvExclusions = @(Get-CombinedExclusionIds -StateObjects $stateObjects -SourceName "uv")

    $mergedWingetPackages = @(Merge-PackageSource -Packages $wingetPackages)
    $mergedMsstorePackages = @(Merge-PackageSource -Packages $msstorePackages)
    $mergedNpmPackages = @(Merge-PackageSource -Packages $npmPackages)
    $mergedUvPackages = @(Merge-PackageSource -Packages $uvPackages)
    $mergedGitRepos = @(Merge-GitRepos -Repos $gitRepos)

    if ($wingetExclusions.Count -gt 0) {
        $mergedWingetPackages = @(
            $mergedWingetPackages |
                Where-Object {
                    $id = Get-ObjectValue -Object $_ -Name "id"
                    $id -and ([string]$id -notin $wingetExclusions)
                }
        )
    }

    if ($msstoreExclusions.Count -gt 0) {
        $mergedMsstorePackages = @(
            $mergedMsstorePackages |
                Where-Object {
                    $id = Get-ObjectValue -Object $_ -Name "id"
                    $id -and ([string]$id -notin $msstoreExclusions)
                }
        )
    }

    if ($npmExclusions.Count -gt 0) {
        $mergedNpmPackages = @(
            $mergedNpmPackages |
                Where-Object {
                    $id = Get-ObjectValue -Object $_ -Name "id"
                    $id -and ([string]$id -notin $npmExclusions)
                }
        )
    }

    if ($uvExclusions.Count -gt 0) {
        $mergedUvPackages = @(
            $mergedUvPackages |
                Where-Object {
                    $id = Get-ObjectValue -Object $_ -Name "id"
                    $id -and ([string]$id -notin $uvExclusions)
                }
        )
    }

    $merged = [ordered]@{
        name         = [string]$machineState.name
        platform     = [string]$machineState.platform
        architecture = [string]$machineState.architecture
        state        = @($machineState.state)
        scripts      = @($machineState.scripts)
        exclusions   = [ordered]@{
            packages = [ordered]@{
                winget  = $wingetExclusions
                msstore = $msstoreExclusions
                npm     = $npmExclusions
                uv      = $uvExclusions
            }
        }
        winget       = [ordered]@{
            packages = [ordered]@{
                winget  = $mergedWingetPackages
                msstore = $mergedMsstorePackages
            }
        }
        node         = [ordered]@{
            packages = [ordered]@{
                npm = $mergedNpmPackages
            }
        }
        uv           = [ordered]@{
            packages = [ordered]@{
                uv = $mergedUvPackages
            }
        }
        git          = [ordered]@{
            cloneRoot = $cloneRoot
            repos     = $mergedGitRepos
        }
        setup        = [ordered]@{
            windows = @(Merge-SetupTopicIds -Ids $setupWindows)
            git     = @(Merge-SetupTopicIds -Ids $setupGit)
        }
    }

    return [pscustomobject]$merged
}

function Get-MachineContext {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedMachineName,

        [Parameter(Mandatory)]
        [string]$MachineStatePath,

        [object]$MachineStateData = $null
    )

    $machineState = if ($null -ne $MachineStateData) { $MachineStateData } else { Read-YamlFile -Path $MachineStatePath }
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
        NodeImportPath   = Join-Path (Join-Path $workingPath "build") "node.npm.import.json"
        NodeExportPath   = Join-Path (Join-Path $workingPath "export") "node.npm.export.json"
        UvImportPath     = Join-Path (Join-Path $workingPath "build") "uv.tools.import.json"
        UvExportPath     = Join-Path (Join-Path $workingPath "export") "uv.tools.export.json"
        GitExportPath    = Join-Path (Join-Path $workingPath "export") "git.export.json"
        GitOpsPath       = Join-Path (Join-Path $workingPath "build") "git.ops.json"
    }

    New-DirectoryIfMissing -Path $context.WorkingPath
    New-DirectoryIfMissing -Path $context.ExportPath
    New-DirectoryIfMissing -Path $context.MergePath
    New-DirectoryIfMissing -Path $context.BuildPath
    New-DirectoryIfMissing -Path $context.LogsPath

    return $context
}

function Get-MachineContextReadOnly {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedMachineName,

        [Parameter(Mandatory)]
        [string]$MachineStatePath
    )

    $machineState = Read-YamlFile -Path $MachineStatePath
    $workingPath = Join-Path $WorkingRoot $ResolvedMachineName

    return [pscustomobject]@{
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
        NodeImportPath   = Join-Path (Join-Path $workingPath "build") "node.npm.import.json"
        NodeExportPath   = Join-Path (Join-Path $workingPath "export") "node.npm.export.json"
        UvImportPath     = Join-Path (Join-Path $workingPath "build") "uv.tools.import.json"
        UvExportPath     = Join-Path (Join-Path $workingPath "export") "uv.tools.export.json"
    }
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

    # All stages respect WhatIf; Merge always runs (forced via Invoke-StageMerge)
    # so that Execute can compute what would happen even in WhatIf mode.
    $passWhatIf = $WhatIfPreference
    & $resolverPath -Stage $Stage -Context $Context -WhatIf:$passWhatIf
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

function Invoke-StageIngest {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$MachineState
    )

    # Get the primary common state file path
    $commonStateRelative = @($MachineState.state) | Select-Object -First 1
    if (-not $commonStateRelative) {
        Write-Warning "No shared state files configured - cannot ingest packages"
        return
    }

    $commonStatePath = Join-Path (Split-Path -Parent $Context.MachineStatePath) $commonStateRelative
    if (-not (Test-Path -LiteralPath $commonStatePath)) {
        Write-Warning "Common state file not found: $commonStatePath"
        return
    }

    $commonState = Read-YamlFile -Path $commonStatePath
    $mergedState = Merge-MachineState -MachineStatePath $Context.MachineStatePath

    # Get existing package IDs from merged state
    $existingWingetIds = @(Get-SourcePackages -StateObject $mergedState -SourceName "winget" | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })
    $existingMsstoreIds = @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore" | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })
    $existingNpmIds = @(Get-SectionPackages -StateObject $mergedState -SectionName "node" -SourceName "npm" | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })
    $existingUvIds = @(Get-SectionPackages -StateObject $mergedState -SectionName "uv" -SourceName "uv" | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })

    # Get all exclusions
    $wingetExclusions = @(Get-CombinedExclusionIds -StateObjects @($commonState, $MachineState) -SourceName "winget")
    $msstoreExclusions = @(Get-CombinedExclusionIds -StateObjects @($commonState, $MachineState) -SourceName "msstore")

    $newPackages = @{
        winget  = @()
        msstore = @()
        npm     = @()
        uv      = @()
    }

    # Parse winget export
    if (Test-Path -LiteralPath $Context.WingetExportPath) {
        $wingetExport = Get-Content -LiteralPath $Context.WingetExportPath -Raw | ConvertFrom-Json

        foreach ($source in @($wingetExport.Sources)) {
            $sourceName = $source.SourceDetails.Name
            if ($sourceName -notin @("winget", "msstore")) { continue }

            foreach ($pkg in @($source.Packages)) {
                $pkgId = $pkg.PackageIdentifier
                if (-not $pkgId) { continue }

                # Skip if excluded
                if ($sourceName -eq "winget" -and $pkgId -in $wingetExclusions) { continue }
                if ($sourceName -eq "msstore" -and $pkgId -in $msstoreExclusions) { continue }

                # Skip if already exists
                if ($sourceName -eq "winget" -and $pkgId -in $existingWingetIds) { continue }
                if ($sourceName -eq "msstore" -and $pkgId -in $existingMsstoreIds) { continue }

                $newPackages[$sourceName] += [ordered]@{
                    id       = $pkgId
                    name     = $pkgId
                    required = $true
                }
            }
        }
    }

    # Parse npm export
    if (Test-Path -LiteralPath $Context.NodeExportPath) {
        $npmExport = Get-Content -LiteralPath $Context.NodeExportPath -Raw | ConvertFrom-Json
        foreach ($pkg in @($npmExport.packages)) {
            $pkgId = if ($pkg -is [string]) { $pkg } else { $pkg.id }
            if (-not $pkgId -or $pkgId -in $existingNpmIds) { continue }
            $newPackages["npm"] += [ordered]@{
                id       = $pkgId
                name     = $pkgId
                required = $true
            }
        }
    }

    # Parse uv export
    if (Test-Path -LiteralPath $Context.UvExportPath) {
        $uvExport = Get-Content -LiteralPath $Context.UvExportPath -Raw | ConvertFrom-Json
        foreach ($pkg in @($uvExport.packages)) {
            $pkgId = if ($pkg -is [string]) { $pkg } else { $pkg.id }
            if (-not $pkgId -or $pkgId -in $existingUvIds) { continue }
            $newPackages["uv"] += [ordered]@{
                id       = $pkgId
                name     = $pkgId
                required = $true
            }
        }
    }

    # Count new packages
    $totalNew = $newPackages["winget"].Count + $newPackages["msstore"].Count + $newPackages["npm"].Count + $newPackages["uv"].Count
    if ($totalNew -eq 0) {
        Write-Host "No new packages to ingest"
        return
    }

    Write-Host "Found $totalNew new package(s) to add to state:"
    if ($newPackages["winget"].Count -gt 0) { Write-Host "  winget: $($newPackages["winget"].Count)" }
    if ($newPackages["msstore"].Count -gt 0) { Write-Host "  msstore: $($newPackages["msstore"].Count)" }
    if ($newPackages["npm"].Count -gt 0) { Write-Host "  npm: $($newPackages["npm"].Count)" }
    if ($newPackages["uv"].Count -gt 0) { Write-Host "  uv: $($newPackages["uv"].Count)" }

    # Update common state with new packages
    $updated = $false

    # Winget packages
    if ($newPackages["winget"].Count -gt 0) {
        $wingetNode = Get-ObjectValue -Object $commonState -Name "winget"
        if (-not $wingetNode) {
            $commonState["winget"] = [ordered]@{ packages = [ordered]@{ winget = @() } }
            $wingetNode = $commonState["winget"]
        }
        $packagesNode = Get-ObjectValue -Object $wingetNode -Name "packages"
        if (-not $packagesNode) {
            $wingetNode["packages"] = [ordered]@{ winget = @() }
            $packagesNode = $wingetNode["packages"]
        }
        $wingetList = @(Get-ObjectValue -Object $packagesNode -Name "winget")
        $wingetList += $newPackages["winget"]
        $packagesNode["winget"] = @($wingetList | Sort-Object { Get-ObjectValue -Object $_ -Name "id" })
        $updated = $true
    }

    # Msstore packages
    if ($newPackages["msstore"].Count -gt 0) {
        $wingetNode = Get-ObjectValue -Object $commonState -Name "winget"
        if (-not $wingetNode) {
            $commonState["winget"] = [ordered]@{ packages = [ordered]@{ msstore = @() } }
            $wingetNode = $commonState["winget"]
        }
        $packagesNode = Get-ObjectValue -Object $wingetNode -Name "packages"
        if (-not $packagesNode) {
            $wingetNode["packages"] = [ordered]@{ msstore = @() }
            $packagesNode = $wingetNode["packages"]
        }
        $msstoreList = @(Get-ObjectValue -Object $packagesNode -Name "msstore")
        $msstoreList += $newPackages["msstore"]
        $packagesNode["msstore"] = @($msstoreList | Sort-Object { Get-ObjectValue -Object $_ -Name "id" })
        $updated = $true
    }

    # Npm packages
    if ($newPackages["npm"].Count -gt 0) {
        $nodeNode = Get-ObjectValue -Object $commonState -Name "node"
        if (-not $nodeNode) {
            $commonState["node"] = [ordered]@{ packages = [ordered]@{ npm = @() } }
            $nodeNode = $commonState["node"]
        }
        $packagesNode = Get-ObjectValue -Object $nodeNode -Name "packages"
        if (-not $packagesNode) {
            $nodeNode["packages"] = [ordered]@{ npm = @() }
            $packagesNode = $nodeNode["packages"]
        }
        $npmList = @(Get-ObjectValue -Object $packagesNode -Name "npm")
        $npmList += $newPackages["npm"]
        $packagesNode["npm"] = @($npmList | Sort-Object { Get-ObjectValue -Object $_ -Name "id" })
        $updated = $true
    }

    # UV packages
    if ($newPackages["uv"].Count -gt 0) {
        $uvNode = Get-ObjectValue -Object $commonState -Name "uv"
        if (-not $uvNode) {
            $commonState["uv"] = [ordered]@{ packages = [ordered]@{ uv = @() } }
            $uvNode = $commonState["uv"]
        }
        $packagesNode = Get-ObjectValue -Object $uvNode -Name "packages"
        if (-not $packagesNode) {
            $uvNode["packages"] = [ordered]@{ uv = @() }
            $packagesNode = $uvNode["packages"]
        }
        $uvList = @(Get-ObjectValue -Object $packagesNode -Name "uv")
        $uvList += $newPackages["uv"]
        $packagesNode["uv"] = @($uvList | Sort-Object { Get-ObjectValue -Object $_ -Name "id" })
        $updated = $true
    }

    if ($updated) {
        Write-YamlFile -Path $commonStatePath -Value $commonState
        Write-Host "Updated: $commonStatePath"
    }
}

function Invoke-StageMerge {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [object]$MachineStateData = $null
    )

    # Merge must run even in WhatIf mode so Execute stage can read the result
    $savedWhatIf = $WhatIfPreference
    $script:WhatIfPreference = $false

    try {
        $mergedState = Merge-MachineState -MachineStatePath $Context.MachineStatePath -MachineStateData $MachineStateData
        Write-YamlFile -Path $Context.MergedStateYaml -Value $mergedState
        $mergedState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Context.MergedStateJson -Encoding UTF8
    }
    finally {
        $script:WhatIfPreference = $savedWhatIf
    }
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
    Write-Host "Exclusions (winget):"
    foreach ($id in @(Get-ExclusionIds -StateObject $MachineState -SourceName "winget")) {
        Write-Host "- $id"
    }
    Write-Host "Exclusions (msstore):"
    foreach ($id in @(Get-ExclusionIds -StateObject $MachineState -SourceName "msstore")) {
        Write-Host "- $id"
    }
    Write-Host "Exclusions (npm):"
    foreach ($id in @(Get-ExclusionIds -StateObject $MachineState -SourceName "npm")) {
        Write-Host "- $id"
    }
    Write-Host "Exclusions (uv):"
    foreach ($id in @(Get-ExclusionIds -StateObject $MachineState -SourceName "uv")) {
        Write-Host "- $id"
    }
    Write-Host "Working Path: $($Context.WorkingPath)"
}

function Test-ExclusionShape {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$ExclusionIds,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [Parameter(Mandatory)]
        [string]$Machine
    )

    foreach ($id in @($ExclusionIds)) {
        if (-not $id) {
            throw "Blank exclusion ID in source '$SourceName' for machine '$Machine'."
        }
    }
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

    $seenMachineWinget = @{}
    $seenMachineMsstore = @{}
    $seenMachineNpm = @{}
    $seenMachineUv = @{}
    $seenMachineExclusionWinget = @{}
    $seenMachineExclusionMsstore = @{}
    $seenMachineExclusionNpm = @{}
    $seenMachineExclusionUv = @{}

    foreach ($machine in $available) {
        $machinePath = Get-MachineStatePath -ResolvedMachineName $machine
        $machineState = Read-YamlFile -Path $machinePath

        if (-not $machineState.name -or -not $machineState.platform -or -not $machineState.architecture) {
            throw "Machine '$machine' is missing required fields (name/platform/architecture)."
        }

        $machineWingetIds = @(
            Get-SourcePackages -StateObject $machineState -SourceName "winget" |
                ForEach-Object { Get-ObjectValue -Object $_ -Name "id" } |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )

        foreach ($id in $machineWingetIds) {
            if ($seenMachineWinget.ContainsKey($id)) {
                throw "Duplicate machine winget package '$id' found in machine files '$($seenMachineWinget[$id])' and '$machine'. Move it to shared state instead."
            }

            $seenMachineWinget[$id] = $machine
        }

        $machineMsstoreIds = @(
            Get-SourcePackages -StateObject $machineState -SourceName "msstore" |
                ForEach-Object { Get-ObjectValue -Object $_ -Name "id" } |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )

        foreach ($id in $machineMsstoreIds) {
            if ($seenMachineMsstore.ContainsKey($id)) {
                throw "Duplicate machine msstore package '$id' found in machine files '$($seenMachineMsstore[$id])' and '$machine'. Move it to shared state instead."
            }

            $seenMachineMsstore[$id] = $machine
        }

        $machineNpmIds = @(
            Get-SectionPackages -StateObject $machineState -SectionName "node" -SourceName "npm" |
                ForEach-Object { Get-ObjectValue -Object $_ -Name "id" } |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )

        foreach ($id in $machineNpmIds) {
            if ($seenMachineNpm.ContainsKey($id)) {
                throw "Duplicate machine npm package '$id' found in machine files '$($seenMachineNpm[$id])' and '$machine'. Move it to shared state instead."
            }

            $seenMachineNpm[$id] = $machine
        }

        $machineUvIds = @(
            Get-SectionPackages -StateObject $machineState -SectionName "uv" -SourceName "uv" |
                ForEach-Object { Get-ObjectValue -Object $_ -Name "id" } |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )

        foreach ($id in $machineUvIds) {
            if ($seenMachineUv.ContainsKey($id)) {
                throw "Duplicate machine uv package '$id' found in machine files '$($seenMachineUv[$id])' and '$machine'. Move it to shared state instead."
            }

            $seenMachineUv[$id] = $machine
        }

        $resolvedStateFiles = @()
        foreach ($relativePath in @($machineState.state)) {
            $resolvedPath = Join-Path (Split-Path -Parent $machinePath) $relativePath
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                throw "Referenced state file not found for machine '$machine': $resolvedPath"
            }

            $resolvedStateFiles += $resolvedPath
        }

        foreach ($scriptName in @($machineState.scripts)) {
            $scriptPath = Join-Path $ScriptsRoot $scriptName
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                throw "Resolver script not found for machine '$machine': $scriptPath"
            }
        }

        Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $machineState -SourceName "winget") -SourceName "winget" -Machine $machine
        Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $machineState -SourceName "msstore") -SourceName "msstore" -Machine $machine
        Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $machineState -SourceName "npm") -SourceName "npm" -Machine $machine
        Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $machineState -SourceName "uv") -SourceName "uv" -Machine $machine

        foreach ($id in @(Get-ExclusionIds -StateObject $machineState -SourceName "winget")) {
            if ($seenMachineExclusionWinget.ContainsKey($id)) {
                throw "Duplicate machine winget exclusion '$id' found in machine files '$($seenMachineExclusionWinget[$id])' and '$machine'. Put shared exclusions in a shared YAML file instead."
            }

            $seenMachineExclusionWinget[$id] = $machine
        }

        foreach ($id in @(Get-ExclusionIds -StateObject $machineState -SourceName "msstore")) {
            if ($seenMachineExclusionMsstore.ContainsKey($id)) {
                throw "Duplicate machine msstore exclusion '$id' found in machine files '$($seenMachineExclusionMsstore[$id])' and '$machine'. Put shared exclusions in a shared YAML file instead."
            }

            $seenMachineExclusionMsstore[$id] = $machine
        }

        foreach ($id in @(Get-ExclusionIds -StateObject $machineState -SourceName "npm")) {
            if ($seenMachineExclusionNpm.ContainsKey($id)) {
                throw "Duplicate machine npm exclusion '$id' found in machine files '$($seenMachineExclusionNpm[$id])' and '$machine'. Put shared exclusions in a shared YAML file instead."
            }

            $seenMachineExclusionNpm[$id] = $machine
        }

        foreach ($id in @(Get-ExclusionIds -StateObject $machineState -SourceName "uv")) {
            if ($seenMachineExclusionUv.ContainsKey($id)) {
                throw "Duplicate machine uv exclusion '$id' found in machine files '$($seenMachineExclusionUv[$id])' and '$machine'. Put shared exclusions in a shared YAML file instead."
            }

            $seenMachineExclusionUv[$id] = $machine
        }

        foreach ($stateFile in $resolvedStateFiles) {
            $sharedState = Read-YamlFile -Path $stateFile
            Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $sharedState -SourceName "winget") -SourceName "winget" -Machine $machine
            Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $sharedState -SourceName "msstore") -SourceName "msstore" -Machine $machine
            Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $sharedState -SourceName "npm") -SourceName "npm" -Machine $machine
            Test-ExclusionShape -ExclusionIds @(Get-ExclusionIds -StateObject $sharedState -SourceName "uv") -SourceName "uv" -Machine $machine
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
        Test-PackageShape -Packages @(Get-SectionPackages -StateObject $mergedState -SectionName "node" -SourceName "npm") -SourceName "npm" -Machine $machine
        Test-PackageShape -Packages @(Get-SectionPackages -StateObject $mergedState -SectionName "uv" -SourceName "uv") -SourceName "uv" -Machine $machine

        $allPackages = @(
            @(Get-SourcePackages -StateObject $mergedState -SourceName "winget") +
            @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore") +
            @(Get-SectionPackages -StateObject $mergedState -SectionName "node" -SourceName "npm") +
            @(Get-SectionPackages -StateObject $mergedState -SectionName "uv" -SourceName "uv")
        )
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

    }

    Write-Host "Validation completed successfully for $($available.Count) machine(s)."
}

