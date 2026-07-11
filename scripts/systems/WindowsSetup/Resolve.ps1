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

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

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
            # Fast registry check - avoids slow Get-WindowsOptionalFeature -Online
            (Get-Service LxssManager -ErrorAction SilentlyContinue)?.Status -eq 'Running' -or
            (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\LxssManager")
        }
        Apply         = {
            # Enable-WindowsOptionalFeature fails with "Class not registered" in some contexts;
            # dism.exe is a direct CLI alternative that doesn't rely on the DISM COM object.
            dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All /NoRestart | Out-Null
        }
        OnApplied     = {
            Add-ManualAction -Context $Context -Category "reboot-required" -Description "Reboot to complete WSL (Windows Subsystem for Linux) installation" -Reason "Windows feature enabled — takes effect after restart"
        }
    }

    @{
        Id            = "virtual-machine-platform"
        Name          = "Virtual Machine Platform (WSL 2)"
        RequiresAdmin = $true
        Check         = {
            # Fast registry check
            (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\winhv") -and
            (Get-Service winhv -ErrorAction SilentlyContinue)?.StartType -ne 'Disabled'
        }
        Apply         = {
            dism.exe /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All /NoRestart | Out-Null
        }
        OnApplied     = {
            Add-ManualAction -Context $Context -Category "reboot-required" -Description "Reboot to complete Virtual Machine Platform (WSL 2) installation" -Reason "Windows feature enabled — takes effect after restart"
        }
    }

    @{
        Id            = "hyper-v"
        Name          = "Hyper-V"
        RequiresAdmin = $true
        Check         = {
            # Fast service check - vmms is the Hyper-V Virtual Machine Management service
            (Get-Service vmms -ErrorAction SilentlyContinue)?.Status -eq 'Running' -or
            (Get-Service vmms -ErrorAction SilentlyContinue)?.StartType -eq 'Automatic'
        }
        Apply         = {
            dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart | Out-Null
        }
        OnApplied     = {
            Add-ManualAction -Context $Context -Category "reboot-required" -Description "Reboot to complete Hyper-V installation" -Reason "Windows feature enabled — takes effect after restart"
        }
    }

    @{
        Id            = "office-insider-beta"
        Name          = "Office Insider Beta channel (machine policy)"
        RequiresAdmin = $true
        Check         = {
            $val = Get-ItemProperty "HKLM:\Software\Policies\Microsoft\office\16.0\common\officeupdate" -Name updatebranch -ErrorAction SilentlyContinue
            $val -and $val.updatebranch -eq "BetaChannel"
        }
        Apply         = {
            $path = "HKLM:\Software\Policies\Microsoft\office\16.0\common\officeupdate"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty $path -Name updatebranch -Value "BetaChannel" -Type String
        }
    }

    @{
        Id            = "office-insider-behavior"
        Name          = "Office Insider slab behavior (user policy)"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty "HKCU:\Software\Policies\Microsoft\office\16.0\common" -Name insiderslabbehavior -ErrorAction SilentlyContinue
            $val -and $val.insiderslabbehavior -eq 1
        }
        Apply         = {
            $path = "HKCU:\Software\Policies\Microsoft\office\16.0\common"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty $path -Name insiderslabbehavior -Value 1 -Type DWord
        }
    }

    @{
        Id            = "localappdata-windowsapps-path"
        Name          = "LocalAppData\Microsoft\WindowsApps on system PATH (ensures winget and AppX tools are always available)"
        RequiresAdmin = $true
        Check         = {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
            $machinePath -contains '%LOCALAPPDATA%\Microsoft\WindowsApps'
        }
        Apply         = {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $parts = @($machinePath -split ';' | Where-Object { $_ })
            if ($parts -notcontains '%LOCALAPPDATA%\Microsoft\WindowsApps') {
                $parts += '%LOCALAPPDATA%\Microsoft\WindowsApps'
                [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
            }
        }
    }

    @{
        Id            = "machine-state-path"
        Name          = "machine-state repo root on user PATH (enables root-level scripts e.g. work-package.ps1)"
        RequiresAdmin = $false
        Check         = {
            $repoRoot = $Context.RepositoryRoot
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $parts = @(($userPath ?? '') -split ';' | Where-Object { $_ })
            $parts -contains $repoRoot
        }
        Apply         = {
            $repoRoot = $Context.RepositoryRoot
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $parts = @(($userPath ?? '') -split ';' | Where-Object { $_ })
            if ($parts -notcontains $repoRoot) {
                $parts += $repoRoot
                [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
                # Reflect into the current session so scripts are runnable immediately
                $env:Path = "$env:Path;$repoRoot"
            }
        }
    }

    @{
        Id            = "sudo"
        Name          = "Windows sudo (forceNewWindow — elevate without a new UAC session)"
        RequiresAdmin = $false
        Check         = {
            $val = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Sudo" -Name Enabled -ErrorAction SilentlyContinue
            $val -and $val.Enabled -eq 1
        }
        Apply         = {
            sudo config --enable forceNewWindow
        }
    }

    @{
        Id            = "defender-exclusions"
        Name          = "Windows Defender exclusions for dev tooling caches"
        RequiresAdmin = $true
        Check         = {
            $profile = $env:USERPROFILE
            $expected = @(
                "$profile\.agents",
                "$profile\.cache",
                "$profile\.copilot",
                "$profile\.ollama\models",
                "$profile\.vscode",
                "$profile\.vscode-insiders",
                "$profile\.nuget\packages",
                "$profile\AppData\Local\npm-cache",
                "$profile\AppData\Local\pnpm",
                "$profile\AppData\Local\Yarn",
                "$profile\AppData\Local\Temp\yarn-cache",
                "$profile\AppData\Local\pip\Cache",
                "$profile\.conda",
                "$profile\.virtualenvs",
                "$profile\AppData\Local\JetBrains",
                "$profile\AppData\Roaming\JetBrains",
                "$profile\AppData\Local\Docker",
                "$profile\AppData\Roaming\Docker",
                "$profile\.aitk",
                "$profile\source"
            )
            $current = (Get-MpPreference).ExclusionPath ?? @()
            $missing = $expected | Where-Object { $_ -notin $current }
            $missing.Count -eq 0
        }
        Apply         = {
            $profile = $env:USERPROFILE
            $desired = @(
                "$profile\.agents",
                "$profile\.cache",
                "$profile\.copilot",
                "$profile\.ollama\models",
                "$profile\.vscode",
                "$profile\.vscode-insiders",
                "$profile\.nuget\packages",
                "$profile\AppData\Local\npm-cache",
                "$profile\AppData\Local\pnpm",
                "$profile\AppData\Local\Yarn",
                "$profile\AppData\Local\Temp\yarn-cache",
                "$profile\AppData\Local\pip\Cache",
                "$profile\.conda",
                "$profile\.virtualenvs",
                "$profile\AppData\Local\JetBrains",
                "$profile\AppData\Roaming\JetBrains",
                "$profile\AppData\Local\Docker",
                "$profile\AppData\Roaming\Docker",
                "$profile\.aitk",
                "$profile\source"
            )
            $current = (Get-MpPreference).ExclusionPath ?? @()
            $toAdd = $desired | Where-Object { $_ -notin $current }
            foreach ($path in $toAdd) {
                Add-MpPreference -ExclusionPath $path
            }
        }
    }

)

Invoke-SetupStage -Stage $Stage -Context $Context -Topic "windows" -Catalog $catalog
