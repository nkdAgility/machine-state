# Build Specification: machine-state

## Objective

`machine-state` is a PowerShell-first repository for rebuilding, updating, exporting, and synchronising named Windows workstations to a declared desired state.

YAML files describe desired machine state across five domains: winget packages, npm global packages, uv tools, git repository clones, and OS/tool configuration (setup). PowerShell scripts perform all execution. The same inputs always produce the same generated output. LLMs may help maintain the repository but are never required to run it.

The system:

1. Detects or accepts the current machine name.
2. Loads the machine YAML file.
3. Merges shared state YAML files with machine-specific state.
4. Exports the current observed state of the machine.
5. Builds tool-specific import manifests from merged desired state.
6. Executes resolver scripts to converge the machine to desired state.
7. Allows each stage to run independently for debugging.
8. Supports a `capture` action that exports and ingests discovered packages back into shared YAML.

Supported machines:

- `NKDA-BEHEMOTH` — Windows x64, high-power desktop with Intel i9 and NVIDIA GPU.
- `NKDA-ROCINANTE` — Windows ARM64, Snapdragon Surface with 64 GB RAM.

---

## Design Principles

1. YAML says what.
2. PowerShell says how.
3. `machine-state.ps1` decides when.
4. `working/` shows what happened.
5. Generated files are not the source of truth.
6. The same inputs must produce the same generated output.
7. Scripts must be PowerShell 7+.
8. No Bash.
9. No hidden LLM dependency.
10. Prefer deterministic scripts over inferred behaviour.
11. Infrastructure errors throw and stop execution; package-level errors accumulate and are reported at the end.
12. Merge always runs — even in WhatIf mode — so Execute can compute what would change.

---

## State File Routing

Use the correct file based on scope. **If it is cross-platform and not machine-specific, it goes in `state/common.yaml`.**

| Scope | File | What belongs here |
|-------|------|-------------------|
| **Cross-platform, every machine** | `state/common.yaml` | dotnet global tools, PS modules, git repos, `setup.git` IDs |
| **Windows, every Windows machine** | `state/win/windows-common.yaml` | winget packages, npm globals, uv tools, `setup.windows` IDs |
| **Windows x64 only** | `state/win/windows-x64.yaml` | x64-specific winget packages |
| **Windows ARM64 only** | `state/win/windows-arm64.yaml` | ARM64-specific winget packages |
| **One specific machine** | `state/machines/<Name>.yaml` | machine-unique packages, `git.cloneRoot`, scripts list |

---

## Repository Structure

```text
machine-state/
  machine-state.ps1

  state/
    common.yaml               ← cross-platform, every machine
    machines/
      NKDA-BEHEMOTH.yaml
      NKDA-ROCINANTE.yaml
    win/
      windows-common.yaml     ← all Windows machines
      windows-x64.yaml        ← x64 only
      windows-arm64.yaml      ← ARM64 only
    config/
      <Publisher.AppName>/    ← per-app config files

  scripts/
    State-Engine.ps1
    Setup-Engine.ps1
    Resolver-Common.ps1
    Resolve-WindowsSetup.ps1
    Resolve-GitSetup.ps1
    Resolve-Winget.ps1
    Resolve-DotNet.ps1
    Resolve-PSModule.ps1
    Resolve-Node.ps1
    Resolve-Uv.ps1
    Resolve-GitRepos.ps1
    Resolve-GitReposCleanup.ps1
    apps/
      Git.Git/
      JanDeDobbeleer.OhMyPosh/
      Elgato.StreamDeck/

  working/
    <MachineName>/
      export/
      merge/
      build/
      logs/

  docs/
    spec.md

  .gitignore
```

`working/` is Git-ignored except for `.gitkeep`. `state/` and `scripts/` are committed. `state/config/` holds per-app configuration data committed to the repo (e.g. Stream Deck profiles, Oh My Posh themes).

---

## machine-state.ps1

The entry point. Dot-sources `scripts/State-Engine.ps1` and orchestrates all stages.

### Parameters

```powershell
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("capture", "apply", "sync", "status", "validate", "export", "merge", "build", "execute")]
    [string]$Action = "sync",

    [string]$MachineName,

    [string[]]$Script,

    [switch]$ExportOnly,

    [switch]$BuildOnly,

    [switch]$VerboseOutput
)
```

`-WhatIf` is provided by PowerShell via `SupportsShouldProcess` and is not declared explicitly.

### -Script Filter

If `-Script` is provided, only resolver scripts whose filename matches one of the supplied values are run for that invocation. If none of the supplied names match the machine's configured scripts, the command throws.

Example:

```powershell
./machine-state.ps1 sync -Script Resolve-Git.ps1
```

### -ExportOnly and -BuildOnly

| Flag | Effect |
|---|---|
| `-ExportOnly` | In `sync`, skips merge/build/execute after export. In `capture`, skips ingest after export. |
| `-BuildOnly` | In `sync` and `apply`, skips execute after build. |

### Actions

| Action | Stages run |
|---|---|
| `sync` (default) | Export → Merge → Build → Execute (respects `-ExportOnly`, `-BuildOnly`) |
| `capture` | Export → Ingest (writes new packages back into shared YAML; respects `-ExportOnly`) |
| `apply` | Merge → Build → Execute (respects `-BuildOnly`) |
| `status` | Prints machine info — no changes made |
| `validate` | Structural checks only — no changes made |
| `export` | Export only (legacy verb) |
| `merge` | Merge only (legacy verb) |
| `build` | Merge if needed, then Build (legacy verb) |
| `execute` | Merge+Build if needed, then Execute (legacy verb) |

### WhatIf Behaviour

`-WhatIf` is passed through to all resolver scripts via `$WhatIfPreference`.

- Merge always runs (forced off WhatIf) so Execute can read the merged state.
- Export: file writes are skipped (ShouldProcess-gated).
- Build: file writes are skipped (ShouldProcess-gated).
- Execute: dry-run output shows what would be installed/changed without doing it.

---

## Context Object

`Get-MachineContext` creates and returns this object. All working directories are created as a side-effect.

```powershell
[pscustomobject]@{
    MachineName      = "NKDA-BEHEMOTH"
    Platform         = "win"
    Architecture     = "x64"
    RepositoryRoot   = "<repo-root>"
    MachineStatePath = "<repo-root>/state/machines/NKDA-BEHEMOTH.yaml"
    WorkingPath      = "<repo-root>/working/NKDA-BEHEMOTH"
    ExportPath       = "<repo-root>/working/NKDA-BEHEMOTH/export"
    MergePath        = "<repo-root>/working/NKDA-BEHEMOTH/merge"
    BuildPath        = "<repo-root>/working/NKDA-BEHEMOTH/build"
    LogsPath         = "<repo-root>/working/NKDA-BEHEMOTH/logs"
    MergedStateYaml  = "<repo-root>/working/NKDA-BEHEMOTH/merge/machine-state.merged.yaml"
    MergedStateJson  = "<repo-root>/working/NKDA-BEHEMOTH/merge/machine-state.merged.json"
}
```

There are no resolver-specific path properties on the context. Each resolver derives its own file paths from `ExportPath`, `BuildPath`, and `LogsPath`.

A read-only variant (`Get-MachineContextReadOnly`) exists for validate — it does not create directories and includes additional derived paths for status display only.

---

## State File Shapes

### Machine YAML

```yaml
name: NKDA-BEHEMOTH
platform: win
architecture: x64

git:
  cloneRoot: "%USERPROFILE%\\source\\repos"

state:
  - ../win/windows-common.yaml
  - ../win/windows-x64.yaml
  - ../apps/git-common.yaml

scripts:
  - Resolve-WindowsSetup.ps1
  - Resolve-Winget.ps1
  - Resolve-Node.ps1
  - Resolve-Uv.ps1
  - Resolve-Git.ps1
  - Resolve-GitCleanup.ps1

exclusions:
  packages:
    winget: []
    msstore: []

winget:
  packages:
    winget:
      - id: Nvidia.CUDA
        name: Nvidia.CUDA
        required: true
    msstore: []

setup:
  windows:
    - long-paths
    - execution-policy
  git:
    - default-branch
    - autocrlf
```

Key fields:

- `name`, `platform`, `architecture` — required; used in context and validation.
- `git.cloneRoot` — machine-specific root path for repository clones; supports `%ENVVAR%` expansion. Only read from the machine YAML (never from shared state).
- `state` — ordered list of relative paths to shared state YAML files, resolved relative to the machine file's directory.
- `scripts` — ordered list of resolver script filenames under `scripts/`.
- `exclusions.packages.winget/msstore` — package IDs that must never appear in desired state, even if present in shared files.
- `winget.packages.winget/msstore` — machine-specific package lists.
- `setup.windows/git` — list of catalog entry IDs to apply for each setup topic.

### Shared State YAML

Shared files (e.g. `state/win/windows-common.yaml`, `state/apps/git-common.yaml`) may contain any combination of:

```yaml
winget:
  packages:
    winget:
      - id: Git.Git
        name: Git.Git
        required: true
        priority: 10
    msstore:
      - id: XP9KHM4BK9FZ7Q
        name: Visual Studio Code
        required: true

node:
  packages:
    npm:
      - id: '@githubnext/github-copilot-cli'
        name: '@githubnext/github-copilot-cli'
        required: true

uv:
  packages:
    uv:
      - id: specify-cli
        name: specify-cli
        required: true

git:
  repos:
    - url: https://github.com/nkdAgility/machine-state
    - url: https://github.com/nkdAgility/NKDAgility.com
      folder: NKDAgility.com

exclusions:
  packages:
    winget:
      - Microsoft.DotNet.SDK.9
    msstore: []

setup:
  windows:
    - long-paths
    - developer-mode
  git:
    - default-branch
    - autocrlf
```

### Package Fields

| Field | Required | Notes |
|---|---|---|
| `id` | Yes | Package identifier. Used as the deduplication key. |
| `name` | Yes | Human-readable label. Not emitted to install manifests. |
| `required` | No | Informational flag. |
| `priority` | No | Integer; lower values install first. Default 999. Only used by Resolve-Winget.ps1 Execute. |
| `manual` | No | Boolean. If true, the package is excluded from the automated import manifest and printed as a manual-install reminder instead. |

Git repo fields:

| Field | Required | Notes |
|---|---|---|
| `url` | Yes | Remote URL. Used as the deduplication key (normalised to lowercase, trailing `.git` and `/` stripped). |
| `folder` | No | Override the local folder name. Defaults to the last path segment of the URL. |

---

## Resolver Contract

All resolver scripts follow this contract:

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

Resolver scripts are invoked by `Invoke-ResolverScript` in `State-Engine.ps1`. Each invocation prints a stage/script banner:

```text
--- Build : Resolve-Winget.ps1 ---
```

Each resolver dot-sources either `Resolver-Common.ps1` (for package resolvers) or `Setup-Engine.ps1` (for setup resolvers), then implements a `switch ($Stage)` block for Export, Build, and Execute.

The three-stage pattern:

| Stage | Responsibility |
|---|---|
| **Export** | Read current observed state from the machine; write to `export/`. |
| **Build** | Read `merge/machine-state.merged.json`; write tool-specific install manifests to `build/`. |
| **Execute** | Read manifests from `build/`; converge the machine to desired state. |

---

## Resolver-Common.ps1

Dot-sourced by all package resolver scripts (`Resolve-Winget.ps1`, `Resolve-Node.ps1`, `Resolve-Uv.ps1`, `Resolve-Git.ps1`).

### Functions

**`Get-ObjectValue -Object $obj -Name $name`**
Safely reads a property from either a `[System.Collections.IDictionary]` (raw YAML parse) or a `[pscustomobject]` (JSON deserialise). Returns `$null` if not found.

**`New-DirectoryIfMissing -Path $path`**
Creates the directory if it does not exist. No-op if it does.

**`Invoke-RefreshPath`**
Rebuilds `$env:PATH` from the machine-level and user-level environment variables. Called after bootstrapping a tool via winget so the new binary is immediately available.

**`Install-ToolIfMissing -Command $cmd -WingetId $id -DisplayName $name`**
Checks whether `$cmd` is on PATH. If not, installs it via `winget install --id $id --accept-package-agreements --accept-source-agreements`, calls `Invoke-RefreshPath`, then verifies the command is now available. Throws on failure.

**`Get-SectionPackages -StateObject $obj -SectionName $section -SourceName $source`**
Navigates `$obj.$section.packages.$source` and returns the package array, or `@()` if any node is absent.

---

## Resolve-Winget.ps1

### Export

- Asserts winget is on PATH (`Assert-WingetAvailable`).
- Runs `winget export --output <ExportPath>/winget.export.json --accept-source-agreements`.
- Captures stdout and stderr to temp files; merges both into `logs/winget.export.log`.
- Parses output lines for warnings:
  - "Installed package is not available from any source" → written to `export/winget.unavailable.json`.
  - "Exported package requires license agreement to install" → written to `export/winget.license-required.json`.
- Stale warning files are deleted if the condition no longer applies.
- Throws if winget exits non-zero.

### Build

- Reads `merge/machine-state.merged.json`.
- Splits packages into **automated** (no `manual` field) and **manual** (`manual: true`).
- Writes `build/winget.manual.json` listing manual packages (or deletes stale file).
- Constructs the winget import model:

  ```json
  {
    "$schema": "https://aka.ms/winget-packages.schema.2.0.json",
    "WinGetVersion": "<detected>",
    "Sources": [
      { "Packages": [...], "SourceDetails": { "Name": "winget", ... } },
      { "Packages": [...], "SourceDetails": { "Name": "msstore", ... } }
    ]
  }
  ```

  Only automated packages appear in the import model. `WinGetVersion` is included if winget is available; omitted otherwise.
- Writes `build/winget.import.json`.
- Runs `winget upgrade --include-unknown` and parses the tabular output to detect upgradeable packages (filtered to desired automated packages only). Writes `build/winget.upgrades.json` (or deletes stale file).

### Execute

- WhatIf mode: diffs desired vs installed (from export) and reports what would be installed or upgraded. No changes made.
- Live mode:
  1. Builds a priority map from `merge/machine-state.merged.json` (`priority` field; default 999).
  2. Diffs desired packages against `export/winget.export.json`; produces `$missingWinget` and `$missingMsstore` sorted by priority then id.
  3. Reads `build/winget.upgrades.json` for packages to upgrade.
  4. Builds a flat work list: installs first, upgrades second.
  5. For each item: prints `[N/total]` progress, calls `winget install --id $id --source $source --accept-package-agreements --accept-source-agreements` or `winget upgrade --id $id --accept-package-agreements --accept-source-agreements`.
  6. Accumulates failures; reports summary at the end. Failures do not abort remaining items.
  7. Prints manual-install reminders for packages in `build/winget.manual.json`.

---

## Resolve-Node.ps1

### Export

- Bootstraps Node.js if absent (`Install-ToolIfMissing -Command npm -WingetId OpenJS.NodeJS.LTS`).
- Runs `npm list -g --depth=0 --json`. Treats non-zero exit as empty list.
- Writes `export/node.npm.export.json` with shape `{ packages: [{ id, version }] }`.

### Build

- Reads merged state; extracts `node.packages.npm` package IDs.
- If npm is available, runs `npm outdated -g --json` and writes `build/node.upgrades.json` for desired packages with available upgrades.
- Writes `build/node.npm.import.json` with shape:

  ```json
  { "packageManager": "npm", "installScope": "global", "packages": ["pkg-name"] }
  ```

### Execute

- WhatIf mode: reports missing packages and available upgrades; no changes made.
- Live mode: runs `npm install -g <pkg>` for every desired package in order. Accumulates failures; does not abort.

---

## Resolve-Uv.ps1

### Export

- Bootstraps uv if absent (`Install-ToolIfMissing -Command uv -WingetId astral-sh.uv`).
- Tries `uv tool list --json`; falls back to plain-text `uv tool list` if JSON parse fails.
- Writes `export/uv.tools.export.json` with shape `{ packageManager: "uv", packages: [{ id, version }] }`.

### Build

- Reads merged state; extracts `uv.packages.uv` package IDs.
- Writes `build/uv.tools.import.json`:

  ```json
  { "packageManager": "uv", "installScope": "tool", "packages": ["tool-name"] }
  ```

### Execute

- WhatIf mode: reports missing tools; no changes made.
- Live mode: runs `uv tool install --upgrade --force <pkg>` for every desired tool. Accumulates failures.

---

## Resolve-Git.ps1

### Export

- Bootstraps git if absent (`Install-ToolIfMissing -Command git -WingetId Git.Git`).
- Reads `cloneRoot` from merged state (or falls back to machine YAML if merge has not run yet; supports `%ENVVAR%` expansion).
- Scans `cloneRoot` for directories containing a `.git` folder.
- For each: reads `origin` remote URL and current branch.
- Writes `export/git.export.json` with shape `{ cloneRoot, repos: [{ path, url, branch }] }`.

### Build

- Reads merged state for desired repos and `cloneRoot`.
- Reads `export/git.export.json` for already-cloned repos.
- Classifies each repo:
  - **Managed** (in desired state and on disk): add to pull list.
  - **To clone** (in desired state, not on disk): add to clone list.
  - **Local-only** (on disk but not in desired state): add to pull list with `managed: false`.
- Writes `build/git.ops.json`:

  ```json
  { "cloneRoot": "...", "clone": [...], "pull": [...] }
  ```

  Each item: `{ url, path, folder, managed }`.

### Execute

- WhatIf mode: processes ShouldProcess checks without running git commands.
- Live mode:
  1. Creates `cloneRoot` if missing.
  2. Clones each entry in `ops.clone` via `git clone <url> <path>`.
  3. Pulls each entry in `ops.pull` via `git -C <path> pull --ff-only`.
  4. Accumulates failures; reports summary.

URL normalisation: trailing `/` and `.git` are stripped; lowercased for deduplication. The original URL is used for the actual `git clone` call.

---

## Resolve-GitCleanup.ps1

A supplementary resolver that prunes merged and redundant local branches across all repos under `cloneRoot`.

### Export

- Reads `cloneRoot` from `export/git.export.json` or merged state.
- Fetches and prunes remotes (`git fetch --prune`) for each repo.
- Counts branches eligible for auto-delete (merged into default branch, or no unique commits) and branches needing manual review (unique commits but no remote tracking branch).
- Reports counts; writes no files.

### Build

No-op. No intermediate manifest needed.

### Execute

- For each repo under `cloneRoot`:
  - Detects the default branch (`origin/HEAD`, then `origin/main`, then `origin/master`).
  - Categorises local branches:
    - **Auto-delete**: merged into default branch, or zero unique commits ahead of it.
    - **Needs review**: unique commits but no remote tracking branch.
    - **Keep**: unique commits and has a remote tracking branch.
  - Checks out the default branch before deleting others.
  - Deletes auto-delete branches via `git branch -d`.
  - Reports branches needing review.
- Writes `logs/git-cleanup-review.txt` if any branches need manual review.
- Accumulates failures; does not abort.

---

## Setup Scripts

Setup resolvers apply idempotent OS and tool configuration settings. They are built on `Setup-Engine.ps1` rather than `Resolver-Common.ps1`.

### Setup-Engine.ps1

Dot-sourced by setup resolver scripts. Provides `Invoke-SetupStage`.

`Invoke-SetupStage -Stage $Stage -Context $Context -Topic $topic -Catalog $catalog`:

1. Calls `Get-EnabledSettings` to filter the catalog to only IDs listed under `setup.$topic` in the merged state. If merged state is not yet available, the full catalog is used.
2. Dispatches to the appropriate stage block.

**Export**: Evaluates each enabled setting's `Check` scriptblock. Writes `export/<topic>.setup.json` with shape `[{ name, configured }]`. Reports how many settings need applying.

**Build**: No-op. Settings are self-contained in the catalog.

**Execute**:

- Detects whether the current process is elevated (administrator).
- For each setting:
  - Runs `Check`. If already configured, prints `OK`.
  - If `RequiresAdmin` is `true` and not elevated: prints `SKIPPED`; accumulates for post-run warning.
  - Otherwise: runs `Apply`. Catches failures and accumulates them.
- Prints summary: applied / already OK / skipped (need admin) / failed.
- Warns if a reboot is required (WSL, Hyper-V, Virtual Machine Platform settings).

Each catalog entry shape:

```powershell
@{
    Id            = "long-paths"
    Name          = "Windows long paths (registry)"
    RequiresAdmin = $true
    Check         = { ... }    # scriptblock; returns truthy if already configured
    Apply         = { ... }    # scriptblock; applies the change
}
```

### Resolve-WindowsSetup.ps1

Topic: `windows`. Dot-sources `Setup-Engine.ps1`. Defines a catalog and calls `Invoke-SetupStage`.

Catalog IDs:

| ID | Name | Admin Required |
|---|---|---|
| `long-paths` | Windows long paths (registry) | Yes |
| `execution-policy` | PowerShell execution policy (RemoteSigned) | Yes |
| `developer-mode` | Developer mode | Yes |
| `show-file-extensions` | Show file extensions in Explorer | No |
| `show-hidden-files` | Show hidden files in Explorer | No |
| `show-protected-files` | Show protected OS files in Explorer | No |
| `wsl` | WSL (Windows Subsystem for Linux) | Yes |
| `virtual-machine-platform` | Virtual Machine Platform (WSL 2) | Yes |
| `hyper-v` | Hyper-V | Yes |
| `office-insider-beta` | Office Insider Beta channel (machine policy) | Yes |
| `office-insider-behavior` | Office Insider slab behavior (user policy) | No |

### Resolve-GitSetup (not yet implemented)

A planned resolver for topic `git`. The catalog IDs referenced in shared state YAML (`long-paths`, `default-branch`, `autocrlf`, `pull-rebase`, `editor-vscode`, `diff-tool-vscode`, `merge-tool-vscode`) are prepared for this resolver. The script file does not yet exist.

---

## Merge Behaviour

`Merge-MachineState` in `State-Engine.ps1` performs the full merge:

1. Reads the machine YAML file.
2. For each path in `machine.state[]` (resolved relative to the machine file's directory):
   - Reads the shared YAML file.
   - Accumulates packages, repos, exclusions, and setup IDs.
3. Accumulates the machine file's own inline packages, repos, exclusions, and setup IDs.

Merging rules per section:

| Section | Key | Rule |
|---|---|---|
| `winget.packages.winget` | `id` | Deduplicate by id; last occurrence wins; sorted by id. |
| `winget.packages.msstore` | `id` | Same. |
| `node.packages.npm` | `id` | Same. |
| `uv.packages.uv` | `id` | Same. |
| `git.repos` | `url` (normalised) | Deduplicate by normalised URL; last occurrence wins; sorted by normalised URL. |
| `setup.windows` | ID string | Deduplicated and sorted. |
| `setup.git` | ID string | Deduplicated and sorted. |
| `exclusions.packages.*` | ID string | Combined across all state objects; deduplicated and sorted. |
| `git.cloneRoot` | — | Read from machine YAML only; never from shared files. |

Exclusion application: after all packages are merged, any package whose `id` appears in the combined exclusion list for that source is removed from the merged package list.

Output written to:

- `working/<MachineName>/merge/machine-state.merged.yaml`
- `working/<MachineName>/merge/machine-state.merged.json`

---

## Working Folder

All generated files live under `working/<MachineName>/`. Folders are created on demand.

```text
working/<MachineName>/
  export/
    winget.export.json          # raw winget export
    winget.unavailable.json     # sideloaded/unavailable packages (if any)
    winget.license-required.json # license-required packages (if any)
    node.npm.export.json        # npm global packages
    uv.tools.export.json        # uv tools
    git.export.json             # discovered git repos
    windows.setup.json          # windows setup check results
    <topic>.setup.json          # setup check results per topic

  merge/
    machine-state.merged.yaml
    machine-state.merged.json

  build/
    winget.import.json          # automated winget install manifest
    winget.manual.json          # packages flagged manual: true
    winget.upgrades.json        # detected upgrades (if any)
    node.npm.import.json        # npm install manifest
    node.upgrades.json          # detected npm upgrades (if any)
    uv.tools.import.json        # uv install manifest
    git.ops.json                # git clone/pull plan

  logs/
    winget.export.log           # stdout+stderr from winget export
    git-cleanup-review.txt      # branches needing manual review (if any)
```

---

## Pipeline Logging

Stage banners are printed by `State-Engine.ps1`:

```text
========================================
  STAGE: Export  [NKDA-BEHEMOTH]
========================================
```

```text
========================================
  STAGE: Merge   [NKDA-BEHEMOTH]
========================================
```

```text
========================================
  STAGE: Build   [NKDA-BEHEMOTH]
========================================
```

```text
========================================
  STAGE: Execute [NKDA-BEHEMOTH]
========================================
```

Per-resolver announcements are printed by `Invoke-ResolverScript`:

```text
--- Export : Resolve-Winget.ps1 ---
```

Within Execute, each package operation is logged as `[N/total] Installing <id>` or `[N/total] Upgrading <id>  <from> -> <to>`, followed by `[N/total] Done` or a warning on failure. A `Write-Progress` bar tracks completion percentage.

---

## Error Handling

- **Infrastructure errors** (missing YAML file, missing resolver script, winget not found, failed bootstrap install) throw and propagate to the top-level `catch` in `machine-state.ps1`, which prints the error and exits with code 1.
- **Package-level errors** (individual install/upgrade/clone failure) are accumulated into a `$failed` array. Execution continues with the remaining items. The summary line reports counts: `Completed: N/M succeeded, K failed: id1, id2`.
- Setup settings that fail `Apply` are accumulated into `$failed` and reported in the summary. Settings that require admin when not elevated are accumulated into `$skipped` with a post-run reminder.

---

## WhatIf Behaviour

`-WhatIf` is passed through the entire call chain via `$WhatIfPreference`.

- **Merge**: always runs with WhatIf suppressed (`$WhatIfPreference = $false` inside `Invoke-StageMerge`). This ensures Execute can compute what would change.
- **Export**: `ShouldProcess` gates file writes. Checks and reads still run.
- **Build**: `ShouldProcess` gates all file writes (`winget.import.json`, `winget.manual.json`, `winget.upgrades.json`, `node.npm.import.json`, etc.).
- **Execute (winget)**: diffs desired vs installed (from export); reports `Would install N package(s)` and `Would upgrade N package(s)` per source. No winget commands run.
- **Execute (node/uv)**: same diff pattern.
- **Execute (git)**: `ShouldProcess` is called per clone/pull operation; no git commands run.
- **Execute (setup)**: setup check scriptblocks still run (read-only registry reads); Apply scriptblocks are gated by `ShouldProcess` inside each apply call.

---

## Validate

`./machine-state.ps1 validate` runs `Invoke-StageValidate` from `State-Engine.ps1`. It is purely read-only and structural.

Checks performed:

1. At least one machine YAML file exists.
2. Each machine YAML has `name`, `platform`, and `architecture`.
3. Each path in `state[]` resolves to an existing file.
4. Each script name in `scripts[]` resolves to an existing file under `scripts/`.
5. Exclusion entries are non-empty strings.
6. Machine-local package IDs are unique across all machine files (duplicates must move to shared state).
7. Machine-local exclusion IDs are unique across all machine files.
8. After merge, `winget.packages` only contains sources `winget` and `msstore`.
9. All merged packages have `id` and `name`.
10. Package IDs are globally unique across all sources within a single merged state.

Validate does not run export, build, or execute, and does not write any files.

---

## Acceptance Criteria

The implementation is complete when:

1. `./machine-state.ps1 status -MachineName NKDA-BEHEMOTH` shows machine name, YAML path, platform, architecture, referenced state files, scripts, and working path.
2. `./machine-state.ps1 validate` passes for all configured machines without installing anything.
3. `./machine-state.ps1 merge -MachineName NKDA-BEHEMOTH` writes `working/NKDA-BEHEMOTH/merge/machine-state.merged.yaml` and `.json`.
4. The merged output combines packages from all referenced state files and the machine file; exclusions are applied; results are deduplicated and sorted.
5. `./machine-state.ps1 build -MachineName NKDA-BEHEMOTH` writes `working/NKDA-BEHEMOTH/build/winget.import.json` separating `winget` and `msstore` sources with only `PackageIdentifier` entries.
6. Packages marked `manual: true` do not appear in `winget.import.json` and are printed as reminders during Execute.
7. Packages with a `priority` field are installed before lower-priority or default-priority packages.
8. `./machine-state.ps1 export -MachineName NKDA-BEHEMOTH` writes observed state to `working/NKDA-BEHEMOTH/export/` for each configured resolver.
9. `./machine-state.ps1 sync -MachineName NKDA-BEHEMOTH` runs all four stages in order.
10. `./machine-state.ps1 sync -MachineName NKDA-BEHEMOTH -WhatIf` runs merge, then reports what would change without modifying the machine.
11. `./machine-state.ps1 sync -Script Resolve-Git.ps1` runs only the git resolver.
12. `./machine-state.ps1 capture -MachineName NKDA-BEHEMOTH` exports observed state and ingests newly discovered packages into the first shared YAML file.
13. `./machine-state.ps1 apply -MachineName NKDA-BEHEMOTH -BuildOnly` runs merge and build without executing.
14. Unknown machines do not silently apply another machine's configuration.
15. All scripts are PowerShell 7+ compatible.
16. No Bash scripts are present.
17. Each stage can be run independently for debugging (`export`, `merge`, `build`, `execute`).
18. Exclusions declared in shared or machine YAML files are applied at merge time so excluded IDs never appear in merged state or generated import manifests.
19. Setup resolvers apply OS and tool configuration idempotently; already-configured settings are skipped; settings requiring elevation are skipped with a reminder when not running as administrator.
20. Git resolver clones missing repos, pulls existing ones (managed and local-only), and never re-clones a repo whose path already exists on disk.
21. Resolve-GitCleanup prunes merged and redundant local branches across all repos under `cloneRoot` and logs branches needing manual review.
