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

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

switch ($Stage) {

    "Export" {
        New-DirectoryIfMissing -Path $Context.ExportPath

        $exportPath = Join-Path $Context.ExportPath "psmodules.export.json"

        $installed = @()
        try {
            $modules = @(Get-InstalledModule -ErrorAction SilentlyContinue)
            foreach ($mod in $modules) {
                $installed += [ordered]@{
                    id      = $mod.Name
                    version = $mod.Version.ToString()
                    scope   = $mod.InstalledLocation -match "AllUsers" ? "AllUsers" : "CurrentUser"
                }
            }
        }
        catch {
            # Get-InstalledModule may fail if no modules installed via PowerShellGet
        }

        $exportModel = [ordered]@{ packages = @($installed | Sort-Object id) }

        if ($PSCmdlet.ShouldProcess($exportPath, "Export installed PS modules")) {
            $exportModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $exportPath -Encoding UTF8
        }

        Write-Host "$($installed.Count) PowerShell module(s) installed via PSGallery"
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $importPath  = Join-Path $Context.BuildPath "psmodules.import.json"
        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json

        $psProp       = $mergedState.PSObject.Properties['psmodules']
        $psVal        = if ($psProp) { $psProp.Value } else { $null }
        $pkgProp      = if ($psVal) { $psVal.PSObject.Properties['packages'] } else { $null }
        $pkgVal       = if ($pkgProp) { $pkgProp.Value } else { $null }
        $galleryProp  = if ($pkgVal) { $pkgVal.PSObject.Properties['psgallery'] } else { $null }
        $desired      = if ($galleryProp) { @($galleryProp.Value) } else { @() }

        $names = @($desired | ForEach-Object {
            $id = if ($_ -is [string]) { $_ } else { $_.PSObject.Properties['id']?.Value ?? $_['id'] }
            if ($id) { [string]$id }
        } | Where-Object { $_ } | Sort-Object -Unique)

        $importModel = [ordered]@{
            packageManager = "PSGallery"
            packages       = $names
        }

        if ($PSCmdlet.ShouldProcess($importPath, "Write PS modules import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $importPath -Encoding UTF8
        }

        # Check for outdated modules
        $upgradesPath = Join-Path $Context.BuildPath "psmodules.upgrades.json"
        $upgrades = @()
        foreach ($name in $names) {
            try {
                $installed = Get-InstalledModule -Name $name -ErrorAction SilentlyContinue
                if (-not $installed) { continue }
                $online = Find-Module -Name $name -ErrorAction SilentlyContinue
                if ($online -and $online.Version -gt $installed.Version) {
                    $upgrades += [ordered]@{
                        id        = $name
                        installed = $installed.Version.ToString()
                        available = $online.Version.ToString()
                    }
                }
            }
            catch { }
        }

        if ($upgrades.Count -gt 0) {
            $upgrades | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
            Write-Host "$($upgrades.Count) PS module(s) have updates available"
        }
        elseif (Test-Path -LiteralPath $upgradesPath) {
            Remove-Item -LiteralPath $upgradesPath -Force
        }

        Write-Host "psmodules: $($names.Count) module(s) in desired state"
    }

    "Execute" {
        $importPath = Join-Path $Context.BuildPath "psmodules.import.json"
        if (-not (Test-Path -LiteralPath $importPath)) {
            throw "PS modules import manifest not found at '$importPath'. Run build first."
        }

        $manifest    = Get-Content -LiteralPath $importPath -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            Write-Host "No PowerShell modules configured"
            return
        }

        $exportPath = Join-Path $Context.ExportPath "psmodules.export.json"
        $installedIds = @()
        if (Test-Path -LiteralPath $exportPath) {
            $exportDoc = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
            $installedIds = @($exportDoc.packages | ForEach-Object { $_.id })
        }

        $upgradesPath = Join-Path $Context.BuildPath "psmodules.upgrades.json"
        $upgradeableIds = @()
        if (Test-Path -LiteralPath $upgradesPath) {
            $upgradeableIds = @((Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json) | ForEach-Object { $_.id })
        }

        $toInstall = @($desiredPkgs | Where-Object { $installedIds -notcontains $_ })
        $toUpdate  = @($upgradeableIds)

        if ($WhatIfPreference) {
            if ($toInstall.Count -eq 0 -and $toUpdate.Count -eq 0) {
                Write-Host "All PowerShell modules are installed and up to date"
            }
            else {
                if ($toInstall.Count -gt 0) {
                    Write-Host "Would install $($toInstall.Count) PS module(s):"
                    foreach ($m in $toInstall) { Write-Host "  - $m" }
                }
                if ($toUpdate.Count -gt 0) {
                    Write-Host "Would update $($toUpdate.Count) PS module(s):"
                    foreach ($m in $toUpdate) { Write-Host "  - $m" }
                }
            }
            return
        }

        $workList = @(
            @($toInstall | ForEach-Object { [ordered]@{ action = "install"; id = $_ } }) +
            @($toUpdate  | ForEach-Object { [ordered]@{ action = "update";  id = $_ } })
        )

        $total   = $workList.Count
        $current = 0
        $failed  = @()

        if ($total -eq 0) {
            Write-Host "All PowerShell modules are installed and up to date"
            return
        }

        Write-Host ""
        Write-Host "==> $total PS module operation(s) to perform"
        Write-Host ""

        foreach ($item in $workList) {
            $current++
            $tag   = "[$current/$total]"
            $pct   = [int](($current - 1) / $total * 100)
            $label = "$tag $($item.action.Substring(0,1).ToUpper() + $item.action.Substring(1))ing $($item.id)"
            Write-Progress -Activity "PS modules" -Status $label -PercentComplete $pct
            Write-Host $label

            if ($PSCmdlet.ShouldProcess($item.id, "PS module $($item.action)")) {
                try {
                    if ($item.action -eq "install") {
                        Install-Module -Name $item.id -Scope AllUsers -Force -AllowClobber -Repository PSGallery
                    }
                    else {
                        Update-Module -Name $item.id -Scope AllUsers -Force
                    }
                    Write-Host "$tag Done"
                }
                catch {
                    Write-Warning "$tag Failed to $($item.action) $($item.id): $_"
                    $failed += $item.id
                }
            }
            Write-Host ""
        }

        Write-Progress -Activity "PS modules" -Completed
        $succeeded = $total - $failed.Count
        Write-Host "==> PS modules: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"
    }
}
