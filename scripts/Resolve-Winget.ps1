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

function Invoke-AppResolver {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [ValidateSet("Export", "Build", "Execute")]
        [string]$ResolverStage,

        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $resolverPath = Join-Path $PSScriptRoot "apps\$PackageId\Resolve.ps1"
    if (-not (Test-Path -LiteralPath $resolverPath)) { return }

    Write-Host ""
    Write-Host "--- $ResolverStage : apps\$PackageId\Resolve.ps1 ---" -ForegroundColor Cyan
    & $resolverPath -Stage $ResolverStage -Context $Context -WhatIf:$WhatIfPreference
}

function Invoke-AllAppResolvers {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Export", "Build", "Execute")]
        [string]$ResolverStage,

        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $appsRoot = Join-Path $PSScriptRoot "apps"
    if (-not (Test-Path -LiteralPath $appsRoot)) { return }

    foreach ($resolverFile in (Get-ChildItem -LiteralPath $appsRoot -Filter "Resolve.ps1" -Recurse)) {
        $packageId = $resolverFile.Directory.Name
        Invoke-AppResolver -PackageId $packageId -ResolverStage $ResolverStage -Context $Context
    }
}

function Assert-WingetAvailable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Winget was not found on PATH. Install Winget before running stage '$Stage'."
    }
}

function Get-WingetVersion {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $version = (& winget --version 2>$null | Select-Object -First 1)
        if ($version) {
            return $version.TrimStart("v")
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-SourcePackages {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $wingetNode = Get-ObjectValue -Object $StateObject -Name "winget"
    $packagesNode = Get-ObjectValue -Object $wingetNode -Name "packages"
    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    return @($sourceNode)
}

function New-WingetSourceBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [array]$Packages
    )

    $sourceDetails = if ($Name -eq "winget") {
        [ordered]@{
            Argument   = "https://cdn.winget.microsoft.com/cache"
            Identifier = "Microsoft.Winget.Source_8wekyb3d8bbwe"
            Name       = "winget"
            Type       = "Microsoft.PreIndexed.Package"
        }
    }
    else {
        [ordered]@{
            Argument   = "https://storeedgefd.dsx.mp.microsoft.com/v9.0"
            Identifier = "StoreEdgeFD"
            Name       = "msstore"
            Type       = "Microsoft.Rest"
        }
    }

    $packageItems = @()
    foreach ($pkg in @($Packages)) {
        $packageId = Get-ObjectValue -Object $pkg -Name "id"
        if ($null -eq $pkg -or -not $packageId) {
            continue
        }

        $packageItems += [ordered]@{
            PackageIdentifier = [string]$packageId
        }
    }

    return [ordered]@{
        Packages      = $packageItems
        SourceDetails = $sourceDetails
    }
}

switch ($Stage) {
    "Export" {
        Assert-WingetAvailable
        New-DirectoryIfMissing -Path $Context.ExportPath

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.ExportPath "winget.export.json"), "Export Winget state")) {
            $unavailablePath = Join-Path $Context.ExportPath "winget.unavailable.json"
            $licensePath     = Join-Path $Context.ExportPath "winget.license-required.json"
            $exportLogPath   = Join-Path $Context.LogsPath  "winget.export.log"

            New-DirectoryIfMissing -Path $Context.LogsPath

            # Capture both stdout and stderr so nothing leaks to the console
            $stdoutFile = [System.IO.Path]::GetTempFileName()
            $stderrFile = [System.IO.Path]::GetTempFileName()
            try {
                & winget export --output (Join-Path $Context.ExportPath "winget.export.json") --accept-source-agreements 2>$stderrFile | Out-File -LiteralPath $stdoutFile -Encoding UTF8
                $exitCode = $LASTEXITCODE

                # Merge stdout + stderr into a single log file
                $stdoutLines = @(Get-Content -LiteralPath $stdoutFile -ErrorAction SilentlyContinue)
                $stderrLines = @(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue)
                ($stdoutLines + $stderrLines) | Set-Content -LiteralPath $exportLogPath -Encoding UTF8

                # Parse all output lines for structured warnings
                $unavailable     = @()
                $licenseRequired = @()

                foreach ($line in ($stdoutLines + $stderrLines)) {
                    if (-not $line) { continue }
                    if ($line -match "Installed package is not available from any source:\s*(.+)") {
                        $unavailable += [ordered]@{
                            name   = $Matches[1].Trim()
                            reason = "not available from any source"
                        }
                    }
                    elseif ($line -match "Exported package requires license agreement to install:\s*(.+)") {
                        $licenseRequired += [ordered]@{
                            name   = $Matches[1].Trim()
                            reason = "requires license agreement"
                        }
                    }
                }

                # Save unavailable packages
                if ($unavailable.Count -gt 0) {
                    $unavailable | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unavailablePath -Encoding UTF8
                    Write-Host "$($unavailable.Count) sideloaded/unavailable package(s) logged to winget.unavailable.json"
                }
                elseif (Test-Path -LiteralPath $unavailablePath) {
                    Remove-Item -LiteralPath $unavailablePath -Force
                }

                # Save license-required packages
                if ($licenseRequired.Count -gt 0) {
                    $licenseRequired | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $licensePath -Encoding UTF8
                    Write-Host "$($licenseRequired.Count) license-required package(s) logged to winget.license-required.json"
                }
                elseif (Test-Path -LiteralPath $licensePath) {
                    Remove-Item -LiteralPath $licensePath -Force
                }

                if ($exitCode -ne 0) {
                    throw "Winget export failed with exit code $exitCode. See log: $exportLogPath"
                }
            }
            finally {
                Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
            }
        }

        Invoke-AllAppResolvers -ResolverStage Export -Context $Context
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state file not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json

        $allWingetPackages  = @(Get-SourcePackages -StateObject $mergedState -SourceName "winget")
        $allMsstorePackages = @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore")

        # Split into automated and manual packages
        $wingetPackages  = @($allWingetPackages  | Where-Object { -not (Get-ObjectValue -Object $_ -Name "manual") })
        $msstorePackages = @($allMsstorePackages | Where-Object { -not (Get-ObjectValue -Object $_ -Name "manual") })
        $manualPackages  = @(
            ($allWingetPackages  | Where-Object { Get-ObjectValue -Object $_ -Name "manual" } | ForEach-Object { [ordered]@{ id = [string](Get-ObjectValue -Object $_ -Name "id"); source = "winget"  } }),
            ($allMsstorePackages | Where-Object { Get-ObjectValue -Object $_ -Name "manual" } | ForEach-Object { [ordered]@{ id = [string](Get-ObjectValue -Object $_ -Name "id"); source = "msstore" } })
        )

        # Write manual package list
        $manualPath = Join-Path $Context.BuildPath "winget.manual.json"
        if ($manualPackages.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($manualPath, "Write winget manual packages list")) {
                $manualPackages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manualPath -Encoding UTF8
            }
            Write-Host "$($manualPackages.Count) package(s) marked for manual installation"
        }
        elseif (Test-Path -LiteralPath $manualPath) {
            if ($PSCmdlet.ShouldProcess($manualPath, "Remove stale winget manual packages list")) {
                Remove-Item -LiteralPath $manualPath -Force
            }
        }

        $wingetVersion = Get-WingetVersion

        $importModel = [ordered]@{
            '$schema' = "https://aka.ms/winget-packages.schema.2.0.json"
            Sources   = @(
                (New-WingetSourceBlock -Name "winget" -Packages $wingetPackages),
                (New-WingetSourceBlock -Name "msstore" -Packages $msstorePackages)
            )
        }

        if ($wingetVersion) {
            $importModel.WinGetVersion = $wingetVersion
        }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.BuildPath "winget.import.json"), "Write Winget import JSON")) {
            $importModel | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Context.BuildPath "winget.import.json") -Encoding UTF8
        }

        # Detect packages with available upgrades (filtered to automated desired packages only)
        $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
        $desiredIds = @($wingetPackages | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" }) +
                      @($msstorePackages | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })

        Write-Host "Checking for available upgrades..."
        $upgradeOutput = & winget upgrade --include-unknown --accept-source-agreements 2>$null
        $upgrades = @()

        # Parse winget upgrade output (table format)
        $inTable = $false
        foreach ($line in $upgradeOutput) {
            if ($line -match "^-+$" -or $line -match "^[-\s]+$") {
                $inTable = $true
                continue
            }
            if ($line -match "^\d+ upgrades available" -or [string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($inTable -and $line.Length -gt 20) {
                if ($line -match "^(.+?)\s{2,}(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$") {
                    $pkgId = $Matches[2].Trim()
                    # Only include if in desired state
                    if ($desiredIds -contains $pkgId) {
                        $upgrades += [ordered]@{
                            name      = $Matches[1].Trim()
                            id        = $pkgId
                            installed = $Matches[3].Trim()
                            available = $Matches[4].Trim()
                            source    = $Matches[5].Trim()
                        }
                    }
                }
            }
        }

        if ($upgrades.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($upgradesPath, "Write winget upgrades manifest")) {
                $upgrades | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
            }
            Write-Host "$($upgrades.Count) package(s) have upgrades available"
        }
        elseif (Test-Path -LiteralPath $upgradesPath) {
            if ($PSCmdlet.ShouldProcess($upgradesPath, "Remove stale winget upgrades manifest")) {
                Remove-Item -LiteralPath $upgradesPath -Force
            }
        }

        Invoke-AllAppResolvers -ResolverStage Build -Context $Context
    }

    "Execute" {
        Assert-WingetAvailable

        if (-not (Test-Path -LiteralPath (Join-Path $Context.BuildPath "winget.import.json"))) {
            throw "Winget import file was not found at '$((Join-Path $Context.BuildPath "winget.import.json"))'. Run build first."
        }

        $importDoc = Get-Content -LiteralPath (Join-Path $Context.BuildPath "winget.import.json") -Raw | ConvertFrom-Json
        $desiredWinget = @($importDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget' } | ForEach-Object { $_.Packages.PackageIdentifier })
        $desiredMsstore = @($importDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })

        if ($WhatIfPreference) {
            # Compare with export to show only what's actually missing
            $installedWinget = @()
            $installedMsstore = @()
            if (Test-Path -LiteralPath (Join-Path $Context.ExportPath "winget.export.json")) {
                $exportDoc = Get-Content -LiteralPath (Join-Path $Context.ExportPath "winget.export.json") -Raw | ConvertFrom-Json
                $installedWinget = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget' } | ForEach-Object { $_.Packages.PackageIdentifier })
                $installedMsstore = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })
            }
            else {
                Write-Warning "No export found at $((Join-Path $Context.ExportPath "winget.export.json")) - run 'capture' first for accurate diff. Showing all desired packages."
            }

            $missingWinget = @($desiredWinget | Where-Object { $installedWinget -notcontains $_ } | Sort-Object)
            $missingMsstore = @($desiredMsstore | Where-Object { $installedMsstore -notcontains $_ } | Sort-Object)

            # Check for upgrades (from build stage)
            $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
            $upgradeableWinget = @()
            if (Test-Path -LiteralPath $upgradesPath) {
                $upgradeableWinget = @(Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json)
            }

            $hasWork = $missingWinget.Count -gt 0 -or $missingMsstore.Count -gt 0 -or $upgradeableWinget.Count -gt 0

            if (-not $hasWork) {
                Write-Host "All winget packages are installed and up to date"
            }
            else {
                if ($missingWinget.Count -gt 0) {
                    Write-Host "Would install $($missingWinget.Count) winget package(s):"
                    foreach ($pkg in $missingWinget) { Write-Host "  - $pkg" }
                }
                if ($missingMsstore.Count -gt 0) {
                    Write-Host "Would install $($missingMsstore.Count) msstore package(s):"
                    foreach ($pkg in $missingMsstore) { Write-Host "  - $pkg" }
                }
                if ($upgradeableWinget.Count -gt 0) {
                    Write-Host "Would upgrade $($upgradeableWinget.Count) package(s):"
                    foreach ($pkg in $upgradeableWinget | Sort-Object { $_.id }) {
                        Write-Host "  - $($pkg.id): $($pkg.installed) -> $($pkg.available)"
                    }
                }
            }
            return
        }

        # Build a priority map from the merged state (lower number = install first, default 999)
        $priorityMap = @{}
        if (Test-Path -LiteralPath $Context.MergedStateJson) {
            $mergedForPriority = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
            foreach ($src in @("winget", "msstore")) {
                foreach ($pkg in @(Get-SourcePackages -StateObject $mergedForPriority -SourceName $src)) {
                    $pkgId  = Get-ObjectValue -Object $pkg -Name "id"
                    $pkgPri = Get-ObjectValue -Object $pkg -Name "priority"
                    if ($pkgId) {
                        $priorityMap[[string]$pkgId] = if ($null -ne $pkgPri) { [int]$pkgPri } else { 999 }
                    }
                }
            }
        }

        # Diff desired vs installed so we only attempt packages that are actually missing
        $installedWinget = @()
        $installedMsstore = @()
        if (Test-Path -LiteralPath (Join-Path $Context.ExportPath "winget.export.json")) {
            $exportDoc = Get-Content -LiteralPath (Join-Path $Context.ExportPath "winget.export.json") -Raw | ConvertFrom-Json
            $installedWinget  = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget'  } | ForEach-Object { $_.Packages.PackageIdentifier })
            $installedMsstore = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })
        }

        $missingWinget  = @($desiredWinget  | Where-Object { $installedWinget  -notcontains $_ } | Sort-Object { if ($priorityMap.ContainsKey($_)) { $priorityMap[$_] } else { 999 } }, { $_ })
        $missingMsstore = @($desiredMsstore | Where-Object { $installedMsstore -notcontains $_ } | Sort-Object { if ($priorityMap.ContainsKey($_)) { $priorityMap[$_] } else { 999 } }, { $_ })

        $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
        $upgradeableWinget = @()
        if (Test-Path -LiteralPath $upgradesPath) {
            $upgradeableWinget = @(Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json)
        }

        $failed = @()

        # Build a flat ordered work list so we can show unified progress
        $workList = @(
            @($missingWinget  | ForEach-Object { [ordered]@{ action = "install"; source = "winget";  id = $_ } }) +
            @($missingMsstore | ForEach-Object { [ordered]@{ action = "install"; source = "msstore"; id = $_ } }) +
            @($upgradeableWinget | ForEach-Object { [ordered]@{ action = "upgrade"; source = "winget"; id = $_.id; from = $_.installed; to = $_.available } })
        )

        $total   = $workList.Count
        $current = 0
        $failed  = @()

        if ($total -eq 0) {
            Write-Host "All winget packages are installed and up to date"
        }
        else {
            Write-Host ""
            Write-Host "==> $total package operation(s) to perform"
            Write-Host ""

            foreach ($item in $workList) {
                $current++
                $pct     = [int](($current - 1) / $total * 100)
                $tag     = "[$current/$total]"

                if ($item.action -eq "install") {
                    $label = "$tag Installing $($item.id)"
                    Write-Progress -Activity "winget" -Status $label -PercentComplete $pct
                    Write-Host "$label"

                    if ($PSCmdlet.ShouldProcess($item.id, "winget install ($($item.source) source)")) {
                        & winget install --id $item.id --source $item.source --accept-package-agreements --accept-source-agreements
                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "$tag Failed to install $($item.id) (exit code $LASTEXITCODE)"
                            $failed += $item.id
                        }
                        else {
                            Write-Host "$tag Done"
                            Invoke-AppResolver -PackageId $item.id -ResolverStage Execute -Context $Context
                        }
                    }
                }
                else {
                    $label = "$tag Upgrading $($item.id)  $($item.from) -> $($item.to)"
                    Write-Progress -Activity "winget" -Status $label -PercentComplete $pct
                    Write-Host "$label"

                    if ($PSCmdlet.ShouldProcess($item.id, "winget upgrade")) {
                        & winget upgrade --id $item.id --accept-package-agreements --accept-source-agreements
                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "$tag Failed to upgrade $($item.id) (exit code $LASTEXITCODE)"
                            $failed += $item.id
                        }
                        else {
                            Write-Host "$tag Done"
                            Invoke-AppResolver -PackageId $item.id -ResolverStage Execute -Context $Context
                        }
                    }
                }

                Write-Host ""
            }

            Write-Progress -Activity "winget" -Completed

            $succeeded = $total - $failed.Count
            Write-Host "==> Completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"
        }

        # Print manual installation reminders
        $manualPath = Join-Path $Context.BuildPath "winget.manual.json"
        if (Test-Path -LiteralPath $manualPath) {
            $manualPkgs = @(Get-Content -LiteralPath $manualPath -Raw | ConvertFrom-Json)
            if ($manualPkgs.Count -gt 0) {
                Write-Host ""
                Write-Host "*** MANUAL INSTALLS REQUIRED ***"
                Write-Host "The following packages must be installed manually (e.g. run without elevation):"
                foreach ($pkg in $manualPkgs) {
                    Write-Host "  winget install --id $($pkg.id) --source $($pkg.source) --accept-package-agreements"
                }
                Write-Host ""
            }
        }
    }
}
