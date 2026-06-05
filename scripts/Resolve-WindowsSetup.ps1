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

$settings = @(

    @{
        Name          = "Windows long paths (registry)"
        RequiresAdmin = $true
        Check         = {
            $val = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
            $val -and $val.LongPathsEnabled -eq 1
        }
        Apply         = {
            Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -Type DWord
        }
    }

    @{
        Name          = "PowerShell execution policy (RemoteSigned)"
        RequiresAdmin = $true
        Check         = {
            (Get-ExecutionPolicy -Scope LocalMachine) -in @("RemoteSigned", "Unrestricted", "Bypass")
        }
        Apply         = {
            Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
        }
    }

    @{
        Name          = "Developer mode"
        RequiresAdmin = $true
        Check         = {
            $val = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
            $val -and $val.AllowDevelopmentWithoutDevLicense -eq 1
        }
        Apply         = {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty $path -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
        }
    }

    @{
        Name          = "Show file extensions in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -ErrorAction SilentlyContinue
            $val -and $val.HideFileExt -eq 0
        }
        Apply         = {
            Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -Value 0 -Type DWord
        }
    }

    @{
        Name          = "Show hidden files in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name Hidden -ErrorAction SilentlyContinue
            $val -and $val.Hidden -eq 1
        }
        Apply         = {
            Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name Hidden -Value 1 -Type DWord
        }
    }

    @{
        Name          = "Show protected OS files in Explorer"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowSuperHidden -ErrorAction SilentlyContinue
            $val -and $val.ShowSuperHidden -eq 1
        }
        Apply         = {
            Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name ShowSuperHidden -Value 1 -Type DWord
        }
    }

    @{
        Name          = "WSL (Windows Subsystem for Linux)"
        RequiresAdmin = $true
        Check         = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $f -and $f.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart | Out-Null
        }
    }

    @{
        Name          = "Virtual Machine Platform (WSL 2)"
        RequiresAdmin = $true
        Check         = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $f -and $f.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
        }
    }

    @{
        Name          = "Hyper-V"
        RequiresAdmin = $true
        Check         = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
            $f -and $f.State -eq "Enabled"
        }
        Apply         = {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart | Out-Null
        }
    }

)

Invoke-SetupStage -Stage $Stage -Context $Context -Topic "Windows" -Settings $settings
