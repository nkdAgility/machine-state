# machine-state — Guidance for LLM Contributors

## Core Model

```
YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.
```

LLMs may help maintain this repository. No LLM is required to run it.

---

## State File Routing

This is the most important rule. Use the correct file based on scope:

| Scope | File | Examples |
|-------|------|---------|
| **Cross-platform, every machine** | `state/common.yaml` | git repos, dotnet tools, PS modules, `setup.git` IDs |
| **Windows, every Windows machine** | `state/win/windows-common.yaml` | winget packages, npm globals, uv tools, `setup.windows` IDs |
| **Windows x64 only** | `state/win/windows-x64.yaml` | x64-specific winget packages |
| **Windows ARM64 only** | `state/win/windows-arm64.yaml` | ARM64-specific winget packages |
| **One specific machine** | `state/machines/<Name>.yaml` | machine-unique packages, `git.cloneRoot`, per-machine scripts |

**If it is cross-platform and not machine-specific, it goes in `state/common.yaml`.**

---

## Two Distinct Concerns

### 1. Primary State — what is installed on this machine

Primary state is declared in YAML and lives under `state/`. The engine reads it,
merges it, and drives installation. These are first-class citizens with their own
merge, build, and execute pipeline:

| Concern | Canonical YAML location | Resolver script |
|---------|------------------------|-----------------|
| Winget packages | `state/win/*.yaml`, `state/machines/<Name>.yaml` | `Resolve-Winget.ps1` |
| Node / npm globals | `state/win/windows-common.yaml` | `Resolve-Node.ps1` |
| Python / uv tools | `state/win/windows-common.yaml` | `Resolve-Uv.ps1` |
| .NET global tools | `state/common.yaml` | `Resolve-DotNet.ps1` |
| PowerShell modules | `state/common.yaml` | `Resolve-PSModule.ps1` |
| Git repositories | `state/common.yaml` | `Resolve-GitRepos.ps1` |
| Windows OS setup | `state/win/windows-common.yaml` (`setup.windows`) | `Resolve-WindowsSetup.ps1` |
| Git app config | `state/common.yaml` (`setup.git`) | `Resolve-GitSetup.ps1` |

**Do not put primary state in `scripts/apps/`.** It belongs in `state/` so the
engine can merge, deduplicate, and validate it.

### 2. App Configuration — how an installed app is configured

App configuration is specific to a single application. It is not merged or
deduplicated by the engine — the app resolver owns it entirely.

Structure:

```
scripts/apps/<Publisher.AppName>/Resolve.ps1   ← resolver (Export / Build / Execute)
state/config/<Publisher.AppName>/              ← config files committed to the repo
```

Examples:

| App | Resolver | Config |
|-----|----------|--------|
| Oh My Posh | `scripts/apps/JanDeDobbeleer.OhMyPosh/Resolve.ps1` | `state/config/JanDeDobbeleer.OhMyPosh/ohmyposh.nkdagility.json` |
| Stream Deck | `scripts/apps/Elgato.StreamDeck/Resolve.ps1` | `state/config/Elgato.StreamDeck/stream-deck-profiles.streamDeckProfilesBackup` |

App resolvers use `Setup-Engine.ps1` (`Invoke-SetupStage`) with a catalog of
Check / Apply pairs. They do not add entries to the primary YAML state.

---

## Naming Convention

App folders use the winget `Publisher.AppName` identifier — the same ID used in
`state/win/*.yaml` and `state/machines/*.yaml`. This makes it unambiguous which
winget package an app resolver belongs to.

---

## Repository Layout

```
state/
  common.yaml       ← cross-platform, every machine (dotnet tools, PS modules, git repos, setup.git)
  machines/         ← one file per named workstation
  win/              ← Windows platform state (winget packages, npm, uv, setup.windows)
  config/           ← app config files, one folder per Publisher.AppName

scripts/
  State-Engine.ps1
  Setup-Engine.ps1
  Resolver-Common.ps1
  Resolve-WindowsSetup.ps1   ← Windows OS configuration
  Resolve-GitSetup.ps1       ← git app configuration
  Resolve-Winget.ps1         ← winget packages
  Resolve-DotNet.ps1         ← dotnet global tools
  Resolve-PSModule.ps1       ← PowerShell modules
  Resolve-Node.ps1           ← npm global packages
  Resolve-Uv.ps1             ← uv tools
  Resolve-GitRepos.ps1       ← git repo clone/pull
  Resolve-GitReposCleanup.ps1 ← git branch cleanup
  apps/
    Git.Git/Resolve.ps1
    JanDeDobbeleer.OhMyPosh/Resolve.ps1
    Elgato.StreamDeck/Resolve.ps1

working/          ← generated outputs, gitignored except .gitkeep
```

---

## Rules for LLM Contributors

1. **Cross-platform config belongs in `state/common.yaml`.** dotnet tools, PS modules,
   git repos, `setup.git` IDs — anything that runs on every machine regardless of OS
   or architecture goes here.

2. **Windows-specific config belongs in `state/win/windows-common.yaml`.** winget
   packages, npm globals, uv tools, `setup.windows` IDs.

3. **Primary state belongs in YAML.** If something is installed via Winget, npm, uv,
   dotnet, or PowerShell modules, it goes in `state/`, not in an app resolver.

4. **App configuration belongs in `scripts/apps/<Publisher.AppName>/`.** If something
   configures an already-installed app (dotfiles, registry settings, profile entries),
   it goes there.

5. **Do not merge these two concerns.** A resolver in `scripts/apps/` must not modify
   `state/` YAML. The engine-driven pipeline owns `state/`.

6. **App resolver naming.** Always use the winget `Publisher.AppName` format for the
   folder name under `scripts/apps/` and `state/config/`.

7. **Resolver contract.** Every `Resolve.ps1` under `scripts/apps/` must accept
   `-Stage` (`Export` / `Build` / `Execute`) and `-Context`, and must use
   `[CmdletBinding(SupportsShouldProcess)]`.

8. **Export updates state.** Where an app stores config files (e.g. Stream Deck
   profiles), the Export stage should write back to `state/config/<Publisher.AppName>/`
   so the repo stays current and changes can be committed.

9. **No Bash.** PowerShell 7+ only.

10. **No hidden LLM dependency.** Every script must run without an LLM present.
