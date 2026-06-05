#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    Write-Warning "  [ohmyposh] oh-my-posh not found on PATH - skipping configuration"
    return
}

$configPath  = Join-Path $Context.RepositoryRoot "state\config\JanDeDobbeleer.OhMyPosh\ohmyposh.nkdagility.json"
$profileInit = "oh-my-posh init pwsh --config `"$configPath`" | Invoke-Expression"

$catalog = @(

    @{
        Id            = "ohmyposh-font-meslo"
        Name          = "Oh My Posh Meslo Nerd Font"
        RequiresAdmin = $true
        Check         = {
            $fonts = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -ErrorAction SilentlyContinue
            $fonts.PSObject.Properties.Name | Where-Object { $_ -like "MesloLGM Nerd Font*" } | Select-Object -First 1
        }
        Apply         = {
            & oh-my-posh font install meslo
        }
    }

    @{
        Id            = "ohmyposh-profile"
        Name          = "Oh My Posh init in PowerShell profile"
        RequiresAdmin = $false
        Check         = {
            if (-not (Test-Path -LiteralPath $PROFILE)) { return $false }
            (Get-Content -LiteralPath $PROFILE -Raw) -match [regex]::Escape($configPath)
        }.GetNewClosure()
        Apply         = {
            if (-not (Test-Path -LiteralPath $PROFILE)) {
                New-Item -ItemType File -Path $PROFILE -Force | Out-Null
            }
            # Remove any existing oh-my-posh init line before adding the correct one
            $content = if (Test-Path -LiteralPath $PROFILE) {
                (Get-Content -LiteralPath $PROFILE -Raw) -replace '(?m)^.*oh-my-posh init pwsh.*$\r?\n?', ''
            } else { '' }
            $content = $content.TrimEnd() + "`n`n$profileInit`n"
            Set-Content -LiteralPath $PROFILE -Value $content -Encoding UTF8
        }.GetNewClosure()
    }

)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "ohmyposh" -Catalog $catalog
