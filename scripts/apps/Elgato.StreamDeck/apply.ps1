#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$BackupPath = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck\stream-deck-profiles.streamDeckProfilesBackup"

if (-not (Test-Path $BackupPath)) {
    Write-Host "  [stream-deck] No backup found at '$BackupPath' - run capture first."
    return
}

Add-ManualAction -Context $Context -Category "stream-deck" `
    -Description "Restore Stream Deck profiles from backup" `
    -Reason "Stream Deck profiles cannot be restored automatically" `
    -Steps @(
        "Open Stream Deck",
        "Go to Settings > Profiles",
        "Click the down arrow > Import from backup...",
        "Select: $BackupPath"
    )

Write-Host "  [stream-deck] Backup restore registered in manual actions summary."

if ($PSCmdlet.ShouldProcess($BackupPath, "Open backup location in Explorer")) {
    Start-Process explorer.exe -ArgumentList "/select,`"$BackupPath`""
}
