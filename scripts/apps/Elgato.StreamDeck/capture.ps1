#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$StateConfigDir = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck"
$BackupFile     = Join-Path $StateConfigDir "stream-deck-profiles.streamDeckProfilesBackup"

Add-ManualAction -Context $Context -Category "stream-deck" `
    -Description "Export Stream Deck profiles backup" `
    -Reason "Stream Deck profiles cannot be exported automatically" `
    -Steps @(
        "Open Stream Deck",
        "Go to Settings > Profiles",
        "Click the down arrow > Export backup...",
        "Save to: $BackupFile"
    )

Write-Host "  [stream-deck] Backup export registered in manual actions summary."

if ($PSCmdlet.ShouldProcess($StateConfigDir, "Open backup destination in Explorer")) {
    Start-Process explorer.exe -ArgumentList "`"$StateConfigDir`""
}
