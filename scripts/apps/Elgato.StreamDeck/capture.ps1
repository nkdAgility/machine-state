#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$StreamDeckAppData = Join-Path $env:APPDATA "Elgato\StreamDeck\ProfilesV2"
$BackupPath        = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck\stream-deck-profiles.streamDeckProfilesBackup"

Write-Host "  [stream-deck] Capture: saving current Stream Deck profiles to repo..."

if (-not (Test-Path $StreamDeckAppData)) {
    Write-Warning "  [stream-deck] ProfilesV2 folder not found at '$StreamDeckAppData' - skipping."
    return
}

New-DirectoryIfMissing -Path (Split-Path -Parent $BackupPath)

if ($PSCmdlet.ShouldProcess($BackupPath, "Update Stream Deck backup")) {
    if (Test-Path $BackupPath) { Remove-Item $BackupPath -Force }
    Compress-Archive -Path "$StreamDeckAppData\*" -DestinationPath $BackupPath
    Write-Host "  [stream-deck] Profiles saved: '$BackupPath'"
}
