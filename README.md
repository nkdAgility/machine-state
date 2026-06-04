# machine-state

PowerShell-first machine rebuild and synchronization for named workstations.

This repository treats YAML as the source of truth for desired machine state and uses PowerShell scripts to execute deterministic stages.

YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.

## Purpose

The goal is to rebuild, update, export, and synchronize workstation state in a deterministic way.

## Supported Machines

- NKDA-BEHEMOTH (Windows x64)
- NKDA-ROCINANTE (Windows ARM64)

## How to Run

Run from repository root with PowerShell 7+:

```powershell
./machine-state.ps1
./machine-state.ps1 sync
./machine-state.ps1 status
./machine-state.ps1 validate
./machine-state.ps1 merge -MachineName NKDA-BEHEMOTH
./machine-state.ps1 build -MachineName NKDA-ROCINANTE
```

## Stages

- export: Capture observed local state, including Winget export.
- merge: Combine machine and shared YAML files into merged YAML and JSON.
- build: Generate tool-specific import files from merged state.
- execute: Run resolver scripts that apply desired state.
- sync: Run export, merge, build, execute.
- status: Display resolved machine, files, scripts, and paths.
- validate: Validate state files and generated Winget import JSON shape.

## State Files

Machine files in state/machines define:

- machine identity and platform metadata
- referenced shared state files
- resolver scripts to run
- machine-specific package additions

Shared files in state/win define reusable package sets.

## Winget Flow

1. export runs Winget export to working/<MachineName>/export/winget.export.json.
2. merge combines referenced state with machine inline state.
3. build creates working/<MachineName>/build/winget.import.json.
4. execute runs winget import using that generated import file.

The generated Winget import JSON includes separate sources for winget and msstore and emits only PackageIdentifier entries.

## Working Folder

Generated artifacts are written to:

- working/<MachineName>/export
- working/<MachineName>/merge
- working/<MachineName>/build
- working/<MachineName>/logs

Generated files are outputs, not source of truth.

## Determinism

Given the same input YAML and script versions, merge and build output is deterministic:

- package entries are deduplicated by id
- package lists are sorted by id
- output files are written to predictable paths

## LLM Boundary

LLMs may help maintain this repository, but no LLM is required to run it.
Execution depends only on PowerShell 7+, Winget, and YAML parsing support.
