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

$StreamDeckAppData = Join-Path $env:APPDATA "Elgato\StreamDeck\ProfilesV2"
$BackupSourcePath  = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck\stream-deck-profiles.streamDeckProfilesBackup"

switch ($Stage) {

    "Export" {
        Write-Host "  [stream-deck] Export: capturing current Stream Deck profiles..."

        if (-not (Test-Path $StreamDeckAppData)) {
            Write-Warning "  [stream-deck] Stream Deck ProfilesV2 folder not found at '$StreamDeckAppData' - skipping export."
            return
        }

        # Pack ProfilesV2 contents directly into the state config file so it
        # stays current and can be committed back to the repository.
        $stateDir = Split-Path -Parent $BackupSourcePath
        New-DirectoryIfMissing -Path $stateDir

        if ($PSCmdlet.ShouldProcess($BackupSourcePath, "Update Stream Deck backup")) {
            if (Test-Path $BackupSourcePath) { Remove-Item $BackupSourcePath -Force }
            Compress-Archive -Path "$StreamDeckAppData\*" -DestinationPath $BackupSourcePath
            Write-Host "  [stream-deck] Backup updated: '$BackupSourcePath'"
        }
    }

    "Build" {
        # Nothing to build - the backup file is the deployable artifact.
        Write-Host "  [stream-deck] Build: no build step required (backup is ready to deploy)."
    }

    "Execute" {
        # Stream Deck does not expose a CLI for profile import. Copying files
        # directly into ProfilesV2 bypasses the internal registry, so profiles
        # will not appear in the UI. The backup must be imported via the app.
        Write-Warning "  [stream-deck] *** MANUAL ACTION REQUIRED ***"
        Write-Warning "  [stream-deck] Stream Deck profiles cannot be restored automatically."
        Write-Warning "  [stream-deck] You must import the backup through the Stream Deck application:"
        Write-Warning "  [stream-deck]   1. Open Stream Deck"
        Write-Warning "  [stream-deck]   2. Go to Settings > Profiles"
        Write-Warning "  [stream-deck]   3. Click the down arrow > Import from backup..."
        Write-Warning "  [stream-deck]   4. Select: $BackupSourcePath"

        if (-not (Test-Path $BackupSourcePath)) {
            Write-Warning "  [stream-deck] Backup file not found at '$BackupSourcePath' - run Export first."
            return
        }

        # Open Explorer to the backup file so it is easy to locate.
        if ($PSCmdlet.ShouldProcess($BackupSourcePath, "Open backup location in Explorer")) {
            Start-Process explorer.exe -ArgumentList "/select,`"$BackupSourcePath`""
        }
    }
}
