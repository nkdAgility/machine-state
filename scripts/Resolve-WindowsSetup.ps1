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
        Id            = "execution-policy"
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
        Id            = "developer-mode"
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
        Id            = "show-file-extensions"
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
        Id            = "show-hidden-files"
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
        Id            = "show-protected-files"
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
        Id            = "wsl"
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
        Id            = "virtual-machine-platform"
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
        Id            = "hyper-v"
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

Invoke-SetupStage -Stage $Stage -Context $Context -Topic "windows" -Catalog $catalog
