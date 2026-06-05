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

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Each setting is described as a hashtable with:
#   Name        - display name
#   Check       - script block returning $true if already correctly configured
#   Apply       - script block to apply the setting
#   RequiresAdmin - whether the setting needs elevation
# ---------------------------------------------------------------------------

$settings = @(

    @{
        Name          = "Windows long paths (registry)"
        RequiresAdmin = $true
        Check         = {
            $val = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
            $val -and $val.LongPathsEnabled -eq 1
        }
        Apply         = {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -Type DWord
        }
    }

    @{
        Name          = "Git long paths (core.longpaths)"
        RequiresAdmin = $true
        Check         = {
            $val = & git config --system core.longpaths 2>$null
            $val -eq "true"
        }
        Apply         = {
            & git config --system core.longpaths true
        }
    }

    @{
        Name          = "PowerShell execution policy (RemoteSigned)"
        RequiresAdmin = $true
        Check         = {
            $policy = Get-ExecutionPolicy -Scope LocalMachine
            $policy -in @("RemoteSigned", "Unrestricted", "Bypass")
        }
        Apply         = {
            Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
        }
    }

    @{
        Name          = "Show file extensions in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -ErrorAction SilentlyContinue
            $val -and $val.HideFileExt -eq 0
        }
        Apply         = {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -Value 0 -Type DWord
        }
    }

    @{
        Name          = "Show hidden files in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name Hidden -ErrorAction SilentlyContinue
            $val -and $val.Hidden -eq 1
        }
        Apply         = {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name Hidden -Value 1 -Type DWord
        }
    }

    @{
        Name          = "Show protected OS files in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowSuperHidden -ErrorAction SilentlyContinue
            $val -and $val.ShowSuperHidden -eq 1
        }
        Apply         = {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowSuperHidden -Value 1 -Type DWord
        }
    }

    @{
        Name          = "Developer mode"
        RequiresAdmin = $true
        Check         = {
            $val = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
            $val -and $val.AllowDevelopmentWithoutDevLicense -eq 1
        }
        Apply         = {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
        }
    }

    @{
        Name          = "WSL (Windows Subsystem for Linux)"
        RequiresAdmin = $true
        Check         = {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $feature -and $feature.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
        }
    }

    @{
        Name          = "Virtual Machine Platform (WSL 2)"
        RequiresAdmin = $true
        Check         = {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $feature -and $feature.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
        }
    }

    @{
        Name          = "Hyper-V"
        RequiresAdmin = $true
        Check         = {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
            $feature -and $feature.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart | Out-Null
        }
    }

)

# ---------------------------------------------------------------------------

switch ($Stage) {

    "Export" {
        New-DirectoryIfMissing -Path $Context.ExportPath
        $exportPath = Join-Path $Context.ExportPath "windows.setup.json"

        $state = @()
        foreach ($setting in $settings) {
            try {
                $configured = & $setting.Check
            }
            catch {
                $configured = $false
            }
            $state += [ordered]@{
                name       = $setting.Name
                configured = [bool]$configured
            }
        }

        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $exportPath -Encoding UTF8

        $needed = @($state | Where-Object { -not $_.configured }).Count
        if ($needed -eq 0) {
            Write-Host "Windows setup: all $($settings.Count) settings already configured"
        }
        else {
            Write-Host "Windows setup: $needed/$($settings.Count) setting(s) need applying"
        }
    }

    "Build" {
        # Nothing to build - settings list is self-contained in this script
    }

    "Execute" {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        $applied  = @()
        $skipped  = @()
        $failed   = @()
        $total    = $settings.Count
        $current  = 0

        Write-Host ""
        Write-Host "==> Applying Windows setup ($total setting(s))"
        Write-Host ""

        foreach ($setting in $settings) {
            $current++
            $tag = "[$current/$total]"

            # Check if already configured
            try { $configured = & $setting.Check } catch { $configured = $false }

            if ($configured) {
                Write-Host "$tag OK       $($setting.Name)"
                continue
            }

            if ($setting.RequiresAdmin -and -not $isAdmin) {
                Write-Warning "$tag SKIPPED  $($setting.Name) (requires admin)"
                $skipped += $setting.Name
                continue
            }

            Write-Host "$tag Applying  $($setting.Name)..."

            if ($PSCmdlet.ShouldProcess($setting.Name, "Apply Windows setting")) {
                try {
                    & $setting.Apply
                    Write-Host "$tag Done"
                    $applied += $setting.Name
                }
                catch {
                    Write-Warning "$tag FAILED   $($setting.Name): $_"
                    $failed += $setting.Name
                }
            }
        }

        Write-Host ""
        Write-Host "==> Setup complete: $($applied.Count) applied, $($total - $applied.Count - $skipped.Count - $failed.Count) already OK$(if ($skipped.Count -gt 0) { ", $($skipped.Count) skipped (need admin)" })$(if ($failed.Count -gt 0) { ", $($failed.Count) failed" })"

        if ($skipped.Count -gt 0) {
            Write-Host ""
            Write-Warning "Re-run as administrator to apply skipped settings:"
            foreach ($s in $skipped) { Write-Host "  - $s" }
        }

        if ($applied.Count -gt 0) {
            $rebootNeeded = $applied | Where-Object { $_ -match "WSL|Hyper-V|Virtual Machine" }
            if ($rebootNeeded) {
                Write-Host ""
                Write-Warning "A reboot is required to complete: $($rebootNeeded -join ', ')"
            }
        }
    }
}
