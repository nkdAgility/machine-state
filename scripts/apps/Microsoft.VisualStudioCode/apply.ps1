#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Write-Host "  [vscode] VS Code not found on PATH - skipping."
    return
}

# Check if already signed in by looking for an auth token in the VS Code keychain store
$settingsPath = Join-Path $env:APPDATA "Code\User\globalStorage\vscode.github-authentication\keystore.json"
$signedIn = Test-Path -LiteralPath $settingsPath

if (-not $signedIn) {
    Add-ManualAction -Context $Context -Category "vscode" `
        -Description "Sign in to Visual Studio Code" `
        -Reason "Settings sync and GitHub Copilot require authentication" `
        -Steps @(
            "Open Visual Studio Code",
            "Click the Accounts icon (bottom-left) or open the Command Palette (Ctrl+Shift+P)",
            "Run: Sign in with GitHub (for Copilot and Settings Sync)",
            "Run: Sign in with Microsoft (for additional enterprise features if required)"
        )
    Write-Host "  [vscode] Sign-in reminder registered in manual actions summary."
} else {
    Write-Host "  [vscode] Already signed in."
}
