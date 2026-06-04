Use this as the Copilot implementation spec.

````markdown
# Build Specification: machine-state

## Objective

Create a PowerShell-first repository named `machine-state` for rebuilding, updating, exporting, and synchronising named workstations.

The system must be deterministic. YAML files describe desired machine state. PowerShell scripts perform all execution. LLMs may help maintain the repository, but must not be required to run it.

The first supported machines are:

- `NKDA-BEHEMOTH`, Windows x64, high-power desktop with Intel i9 and NVIDIA GPU.
- `NKDA-ROCINANTE`, Windows ARM64, Snapdragon Surface with 64 GB RAM.

The first supported package system is Winget.

The system must be able to:

1. Detect the current machine.
2. Load the correct machine YAML file.
3. Merge machine YAML with referenced shared state YAML files.
4. Build a valid Winget import JSON file from the merged YAML.
5. Export current Winget state.
6. Execute configured resolver scripts in order.
7. Allow each stage to be run independently for debugging.

## Design Principles

1. YAML says what.
2. PowerShell says how.
3. `machine-state.ps1` decides when.
4. `working/` shows what happened.
5. Generated files are not the source of truth.
6. The same inputs should produce the same generated output.
7. Scripts must be PowerShell 7+.
8. No Bash.
9. No hidden LLM dependency.
10. Prefer deterministic scripts over inferred behaviour.

## Repository Structure

Create this structure:

```text
machine-state/
  README.md
  machine-state.ps1

  state/
    machines/
      NKDA-BEHEMOTH.yaml
      NKDA-ROCINANTE.yaml

    win/
      windows-common.yaml
      windows-x64.yaml
      windows-arm64.yaml

  scripts/
    Resolve-Winget.ps1

  working/
    .gitkeep

  docs/
    .gitkeep

  .gitignore
````

## Root Script

Create `machine-state.ps1` in the repository root.

It must support these stages:

```powershell
./machine-state.ps1 export
./machine-state.ps1 merge
./machine-state.ps1 build
./machine-state.ps1 execute
./machine-state.ps1 sync
```

It must also support:

```powershell
./machine-state.ps1 status
./machine-state.ps1 validate
```

The default action should be `sync`.

Example usage:

```powershell
./machine-state.ps1
./machine-state.ps1 sync
./machine-state.ps1 merge
./machine-state.ps1 build
./machine-state.ps1 execute
./machine-state.ps1 export
./machine-state.ps1 validate
./machine-state.ps1 status
./machine-state.ps1 sync -MachineName NKDA-BEHEMOTH
./machine-state.ps1 sync -MachineName NKDA-ROCINANTE
```

## Parameters

`machine-state.ps1` must support:

```powershell
param(
    [Parameter(Position = 0)]
    [ValidateSet("export", "merge", "build", "execute", "sync", "status", "validate")]
    [string]$Action = "sync",

    [string]$MachineName,

    [switch]$VerboseOutput
)
```

Use `[CmdletBinding(SupportsShouldProcess)]`.

`-WhatIf` is provided by PowerShell via `SupportsShouldProcess` and does not need to be declared explicitly in the `param(...)` block.

## Machine Detection

On Windows, detect the current machine with:

```powershell
$env:COMPUTERNAME
```

If `-MachineName` is supplied, use that instead.

If the detected or supplied machine has a matching YAML file under:

```text
state/machines/<MachineName>.yaml
```

use that file.

If the machine is unknown, print the available machine names and ask the user to choose one interactively.

Do not silently default to a machine.

## State Files

The system uses YAML state files.

Use PowerShell’s `ConvertFrom-Yaml` and `ConvertTo-Yaml` if available. If not available, the script should detect this and install or require the `powershell-yaml` module.

Preferred behaviour:

1. Check whether `ConvertFrom-Yaml` is available.
2. If not, check for the `powershell-yaml` module.
3. If not installed, print a clear error explaining the prerequisite.
4. Do not silently install modules unless explicitly implemented with confirmation.

## Exclusions

Exclusions define installed packages that should never become part of desired state.

Exclusions may be declared in any referenced YAML file:

* machine files under `state/machines/`
* shared files under `state/win/`

Shape:

```yaml
exclusions:
  packages:
    winget:
      - Microsoft.DotNet.SDK.9
    msstore:
      - XP89DCGQ3K6VLD
```

Rules:

1. During merge, exclusions from all loaded state files are combined and deduplicated.
2. Excluded package IDs are removed from merged desired state, even if present in common or machine package lists.
3. Raw `winget export` output is still written unchanged to `working/<MachineName>/export/winget.export.json`.
4. When converting/export snapshots into maintained YAML state, excluded IDs must be filtered out and never reintroduced.
5. Shared exclusions should live in shared YAML files (for example `state/win/windows-common.yaml`) to avoid duplication across machine files.

## Machine YAML Shape

Create `state/machines/NKDA-BEHEMOTH.yaml`:

```yaml
name: NKDA-BEHEMOTH
platform: win
architecture: x64

state:
  - ../win/windows-common.yaml
  - ../win/windows-x64.yaml

scripts:
  - Resolve-Winget.ps1

exclusions:
  packages:
    winget: []
    msstore: []

winget:
  packages:
    winget:
      - id: Nvidia.CUDA
        name: NVIDIA CUDA Toolkit
        description: NVIDIA CUDA development toolkit.
        required: true

      - id: Nvidia.PhysX
        name: NVIDIA PhysX
        description: NVIDIA PhysX runtime.
        required: true

      - id: OBSProject.OBSStudio
        name: OBS Studio
        description: Video recording and streaming software.
        required: true
```

Create `state/machines/NKDA-ROCINANTE.yaml`:

```yaml
name: NKDA-ROCINANTE
platform: win
architecture: arm64

state:
  - ../win/windows-common.yaml
  - ../win/windows-arm64.yaml

scripts:
  - Resolve-Winget.ps1

exclusions:
  packages:
    winget: []
    msstore: []

winget:
  packages:
    winget: []
    msstore: []
```

## Shared Windows YAML Files

Create `state/win/windows-common.yaml`:

```yaml
name: windows-common
platform: win

winget:
  packages:
    winget:
      - id: Git.Git
        name: Git
        description: Git version control system.
        required: true

      - id: Microsoft.PowerShell
        name: PowerShell
        description: PowerShell 7 shell and scripting runtime.
        required: true

      - id: Microsoft.VisualStudioCode
        name: Visual Studio Code
        description: Code editor.
        required: true

      - id: GitHub.cli
        name: GitHub CLI
        description: GitHub command-line interface.
        required: true

      - id: Microsoft.AzureCLI
        name: Azure CLI
        description: Command-line tools for Microsoft Azure.
        required: true

      - id: Microsoft.WindowsTerminal
        name: Windows Terminal
        description: Modern terminal application for Windows.
        required: true

      - id: JanDeDobbeleer.OhMyPosh
        name: Oh My Posh
        description: Prompt theme engine.
        required: true

      - id: Microsoft.PowerToys
        name: PowerToys
        description: Microsoft PowerToys utilities.
        required: true

    msstore: []
```

Create `state/win/windows-x64.yaml`:

```yaml
name: windows-x64
platform: win
architecture: x64

winget:
  packages:
    winget:
      - id: Microsoft.VisualStudio.Enterprise.Insiders
        name: Visual Studio Enterprise Insiders
        description: Visual Studio Enterprise Insiders edition.
        required: true

      - id: Microsoft.DotNet.SDK.10
        name: .NET SDK 10
        description: .NET 10 SDK.
        required: true

      - id: Microsoft.DotNet.SDK.9
        name: .NET SDK 9
        description: .NET 9 SDK.
        required: true

      - id: Microsoft.DotNet.SDK.8
        name: .NET SDK 8
        description: .NET 8 SDK.
        required: true

    msstore: []
```

Create `state/win/windows-arm64.yaml`:

```yaml
name: windows-arm64
platform: win
architecture: arm64

winget:
  packages:
    winget:
      - id: Microsoft.DotNet.SDK.10
        name: .NET SDK 10
        description: .NET 10 SDK.
        required: true

      - id: Microsoft.DotNet.SDK.9
        name: .NET SDK 9
        description: .NET 9 SDK.
        required: true

      - id: Microsoft.DotNet.SDK.8
        name: .NET SDK 8
        description: .NET 8 SDK.
        required: true

    msstore: []
```

## Package YAML Shape

Each Winget package entry must support:

```yaml
- id: Git.Git
  name: Git
  description: Git version control system.
  required: true
```

Required fields:

* `id`
* `name`

Optional fields:

* `description`
* `required`
* `notes`
* `tags`

The generated Winget JSON must only use `id`, mapped to `PackageIdentifier`.

## Working Folder

All generated files must go under:

```text
working/<MachineName>/
```

For example:

```text
working/NKDA-BEHEMOTH/
  export/
    winget.export.json

  merge/
    machine-state.merged.yaml
    machine-state.merged.json

  build/
    winget.import.json

  logs/
    machine-state.log
```

Create folders as needed.

`working/` should be ignored by Git except for `.gitkeep`.

## Stage: Export

`export` reads current machine state and writes observed state to `working/<MachineName>/export/`.

For Winget, call the Winget resolver script with stage `Export`.

Expected output:

```text
working/<MachineName>/export/winget.export.json
```

Implementation should run:

```powershell
winget export --output <path> --accept-source-agreements
```

If Winget export fails, report the error clearly.

## Stage: Merge

`merge` loads:

1. The machine YAML file.
2. Each YAML file listed under the machine file’s `state` array.
3. The machine file’s own inline state.

Merge order:

1. Referenced shared state files in listed order.
2. Machine-specific inline state last.

For `NKDA-BEHEMOTH`, merge:

```text
state/win/windows-common.yaml
state/win/windows-x64.yaml
state/machines/NKDA-BEHEMOTH.yaml
```

For `NKDA-ROCINANTE`, merge:

```text
state/win/windows-common.yaml
state/win/windows-arm64.yaml
state/machines/NKDA-ROCINANTE.yaml
```

Merge behaviour:

1. Combine Winget package lists.
2. Preserve separate sources:

   * `winget`
   * `msstore`
3. Deduplicate by `id`.
4. Sort packages by `id` for deterministic output.
5. Preserve package metadata from the last occurrence if duplicates exist.
6. Combine exclusions from all loaded state files (`state[]` files plus machine file), deduplicate exclusion IDs, and remove excluded package IDs from merged package lists.
7. Save merged output as YAML and JSON.

Expected output:

```text
working/<MachineName>/merge/machine-state.merged.yaml
working/<MachineName>/merge/machine-state.merged.json
```

## Stage: Build

`build` converts merged state into tool-specific generated files.

For Winget, call `scripts/Resolve-Winget.ps1` with stage `Build`.

Input:

```text
working/<MachineName>/merge/machine-state.merged.yaml
```

Output:

```text
working/<MachineName>/build/winget.import.json
```

The generated Winget JSON must follow this structure:

```json
{
  "$schema": "https://aka.ms/winget-packages.schema.2.0.json",
  "CreationDate": "2026-06-04T10:50:43.266-00:00",
  "Sources": [
    {
      "Packages": [
        {
          "PackageIdentifier": "Git.Git"
        }
      ],
      "SourceDetails": {
        "Argument": "https://cdn.winget.microsoft.com/cache",
        "Identifier": "Microsoft.Winget.Source_8wekyb3d8bbwe",
        "Name": "winget",
        "Type": "Microsoft.PreIndexed.Package"
      }
    },
    {
      "Packages": [
        {
          "PackageIdentifier": "9PLM9XGG6VKS"
        }
      ],
      "SourceDetails": {
        "Argument": "https://storeedgefd.dsx.mp.microsoft.com/v9.0",
        "Identifier": "StoreEdgeFD",
        "Name": "msstore",
        "Type": "Microsoft.Rest"
      }
    }
  ],
  "WinGetVersion": "1.29.240"
}
```

The source shape must preserve Winget’s separate `winget` and `msstore` sources. A real Winget export contains this structure, with `PackageIdentifier` entries grouped under `Sources[].Packages[]`. The uploaded export uses schema `https://aka.ms/winget-packages.schema.2.0.json`, includes `winget` and `msstore` sources, and was produced by Winget `1.29.240`. 

For deterministic build output:

1. Sort `winget` packages by `id`.
2. Sort `msstore` packages by `id`.
3. Do not include YAML-only metadata in the Winget JSON.
4. Only emit `PackageIdentifier`.
5. Include `CreationDate` only if required. If included, it makes exact file comparison non-deterministic, so prefer omitting it unless Winget requires it.
6. Include `WinGetVersion` if available, but do not fail if it cannot be resolved.

## Stage: Execute

`execute` runs the resolver scripts listed in the machine YAML file.

Example:

```yaml
scripts:
  - Resolve-Winget.ps1
```

For each script:

1. Resolve the script path under `scripts/`.
2. Verify it exists.
3. Call it with `-Stage Execute`.
4. Pass a context object.
5. Stop on failure unless explicitly changed later.

For Winget, execute must run:

```powershell
winget import --import-file <working>/<MachineName>/build/winget.import.json --accept-package-agreements --accept-source-agreements
```

## Stage: Sync

`sync` runs the full flow:

```text
export
merge
build
execute
```

For rebuild scenarios, it should also be possible to skip export later, but the initial implementation can always run all four stages.

## Stage: Status

`status` prints:

1. Detected machine name.
2. Selected machine YAML.
3. Platform.
4. Architecture.
5. Referenced state files.
6. Scripts to run.
7. Working folder path.

Do not make changes during `status`.

## Stage: Validate

`validate` checks:

1. Machine YAML files exist.
2. Machine YAML has `name`, `platform`, and `architecture`.
3. Referenced state YAML files exist.
4. Script files listed in machine YAML exist.
5. Winget package entries have `id` and `name`.
6. Package IDs are unique after merge.
7. Source names are valid:

   * `winget`
   * `msstore`
8. Generated Winget JSON can be parsed.
9. Generated Winget JSON has `Sources`.
10. Generated Winget JSON has valid `PackageIdentifier` entries.
11. Exclusion entries are non-empty IDs.
12. Machine-local package IDs are unique across machine files (if duplicated across machines, move to shared state).
13. Machine-local exclusion IDs are unique across machine files (if shared, move to shared state YAML).

Do not execute installations during `validate`.

## Resolver Script Contract

Create `scripts/Resolve-Winget.ps1`.

It must support:

```powershell
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
```

The context object must include:

```powershell
[pscustomobject]@{
    MachineName        = "NKDA-BEHEMOTH"
    Platform           = "win"
    Architecture       = "x64"
    RepositoryRoot     = "<repo-root>"
    MachineStatePath   = "<repo-root>/state/machines/NKDA-BEHEMOTH.yaml"
    WorkingPath        = "<repo-root>/working/NKDA-BEHEMOTH"
    ExportPath         = "<repo-root>/working/NKDA-BEHEMOTH/export"
    MergePath          = "<repo-root>/working/NKDA-BEHEMOTH/merge"
    BuildPath          = "<repo-root>/working/NKDA-BEHEMOTH/build"
    LogsPath           = "<repo-root>/working/NKDA-BEHEMOTH/logs"
    MergedStateYaml    = "<repo-root>/working/NKDA-BEHEMOTH/merge/machine-state.merged.yaml"
    MergedStateJson    = "<repo-root>/working/NKDA-BEHEMOTH/merge/machine-state.merged.json"
    WingetImportPath   = "<repo-root>/working/NKDA-BEHEMOTH/build/winget.import.json"
    WingetExportPath   = "<repo-root>/working/NKDA-BEHEMOTH/export/winget.export.json"
}
```

## Resolve-Winget.ps1 Behaviour

### Export

Run:

```powershell
winget export --output $Context.WingetExportPath --accept-source-agreements
```

Create the export folder first.

### Build

Read:

```text
$Context.MergedStateYaml
```

Build:

```text
$Context.WingetImportPath
```

The input YAML is:

```yaml
winget:
  packages:
    winget:
      - id: Git.Git
        name: Git
        description: Git version control system.
        required: true

    msstore:
      - id: 9PLM9XGG6VKS
        name: Example Store App
        description: Microsoft Store app.
        required: true
```

The output JSON must map these to:

```json
{
  "PackageIdentifier": "Git.Git"
}
```

### Execute

Run:

```powershell
winget import --import-file $Context.WingetImportPath --accept-package-agreements --accept-source-agreements
```

If the import file does not exist, fail clearly and instruct the user to run `build`.

## README Content

Create a `README.md` with:

1. Purpose.
2. Supported machines.
3. How to run.
4. Stage explanation.
5. State file explanation.
6. Winget flow explanation.
7. Working folder explanation.
8. Determinism principle.
9. LLM boundary.

Include this short model:

```text
YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.
```

## .gitignore

Create `.gitignore`:

```gitignore
working/*
!working/.gitkeep

*.log
*.tmp

# Secrets and credentials
*.key
*.pem
*.pfx
*.env
secrets.*
credentials.*
id_rsa
id_ed25519
```

## Implementation Notes

Use PowerShell 7+.

Use strict mode:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
```

Avoid Bash.

Avoid global mutable state where practical.

Keep functions small.

Prefer explicit paths.

Create missing folders before writing files.

Fail clearly when prerequisites are missing.

## Acceptance Criteria

The implementation is complete when:

1. `./machine-state.ps1 status -MachineName NKDA-BEHEMOTH` shows the selected machine, state files, scripts, and working paths.
2. `./machine-state.ps1 status -MachineName NKDA-ROCINANTE` shows the selected machine, state files, scripts, and working paths.
3. `./machine-state.ps1 merge -MachineName NKDA-BEHEMOTH` writes merged YAML and JSON under `working/NKDA-BEHEMOTH/merge/`.
4. `./machine-state.ps1 merge -MachineName NKDA-ROCINANTE` writes merged YAML and JSON under `working/NKDA-ROCINANTE/merge/`.
5. `./machine-state.ps1 build -MachineName NKDA-BEHEMOTH` writes `working/NKDA-BEHEMOTH/build/winget.import.json`.
6. `./machine-state.ps1 build -MachineName NKDA-ROCINANTE` writes `working/NKDA-ROCINANTE/build/winget.import.json`.
7. The generated Winget JSON separates `winget` and `msstore` sources.
8. The generated Winget JSON only includes `PackageIdentifier` package entries.
9. Package metadata such as `name` and `description` remains in YAML but is not emitted into Winget JSON.
10. Package IDs are deduplicated and sorted during merge/build.
11. `./machine-state.ps1 export -MachineName NKDA-BEHEMOTH` runs Winget export and writes to `working/NKDA-BEHEMOTH/export/winget.export.json`.
12. `./machine-state.ps1 execute -MachineName NKDA-BEHEMOTH` runs the scripts listed in `NKDA-BEHEMOTH.yaml`.
13. `Resolve-Winget.ps1 -Stage Execute` runs Winget import using the generated import file.
14. `./machine-state.ps1 validate` checks all machine and state files without installing anything.
15. Unknown machines do not silently apply another machine’s config.
16. All scripts are PowerShell 7+ compatible.
17. No Bash scripts are created.
18. The repository can run the stages independently for debugging:

    * `export`
    * `merge`
    * `build`
    * `execute`
  19. Exclusions declared in shared or machine YAML files are applied during merge/build so excluded IDs do not appear in merged state or generated Winget import JSON.
  20. Excluded packages may still appear in raw export artifacts, but are filtered out when generating or refreshing desired state YAML.

```

Confidence: High.
```
