# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this folder is

A Windows Sandbox harness for installing and testing software on a clean, throwaway Windows
image. It is a personal project. It is not a git repo yet, and **don't create one unless asked**.
`.gitignore` is already written for one: only `setup/`, `docs/`, `README.md`, `CLAUDE.md`,
`LICENSE` (MIT), `prereqs/README.md`, `logs/.gitkeep` and `shared/.gitkeep` are meant to be versioned. Keep it
free of employer names and PII. There is no build or test step. The code is PowerShell scripts
plus one `.wsb` config.

## Running it

```powershell
WindowsSandbox.exe C:\source\solo\windows-sandbox\setup\SandboxBase.wsb   # or double-click the .wsb
```

Claude can't observe the sandbox. You can only check a change by launching it and reading what
lands in `logs\`, so ask the user to run it and report back. Each launch starts from a clean
image, and nothing persists between runs except what is written to `logs\` or `shared\`.

## How the pieces fit

`setup/SandboxBase.wsb` maps four host folders into the sandbox. The host paths are
hard-coded to `C:\source\solo\windows-sandbox\...`, so moving the folder breaks the mappings.

| Host | Sandbox | Access | Purpose |
|---|---|---|---|
| `setup\` | `C:\sandbox\setup` | **read-only** | scripts |
| `prereqs\` | `C:\sandbox\prereqs` | **read-only** | installers, fonts and other dependencies |
| `logs\` | `C:\sandbox\logs` | read/write | setup script logs |
| `shared\` | `C:\sandbox\shared` | read/write | the user's own files moving in and out (packages, test files) |

Desktop shortcuts are created for `shared`, `setup` and `prereqs` only. The user doesn't want one
for `logs`.

Networking is **disabled**, so every dependency has to be downloaded on the host and put in
`prereqs\` first. `prereqs/README.md` lists commonly useful installers.

Because `setup\` and `prereqs\` are read-only, scripts must write scratch files to `$env:TEMP`
(for example, `SetupBase.ps1` writes its wallpaper there), logs to `C:\sandbox\logs`, and other
output for the host to `C:\sandbox\shared`. Scripts find sibling folders relative to `$PSScriptRoot`
(`Split-Path -Parent $PSScriptRoot` resolves to `C:\sandbox`).

**Scenario pattern.** The `.wsb` `<LogonCommand>` runs `setup/SetupBase.ps1`, which does the
shared desktop setup: taskbar layout, desktop shortcuts to the mapped folders, a
"Sandbox: <Scenario>" wallpaper, the Recycle Bin delete confirmation and auto-arranged icons,
then it restarts Explorer. Each scenario script is named `setup/Setup<Scenario>.ps1` and must
call the base script first:

```powershell
& "$PSScriptRoot\SetupBase.ps1" -Scenario '<Scenario>'
```

No scenario scripts exist yet. The `.wsb` runs only the base setup.

**Logs.** `SetupBase.ps1` writes `logs/SetupBase-<yyyyMMdd-HHmmss>.log`: boot → PowerShell
start latency, then milliseconds per step, then the total. Each section of the script begins with
`Start-Step '<label>'`, and that label is the log line, so a new step needs a new `Start-Step`. The
steps run inside `try`/`finally`, so the log is still written when a step throws, with a
`FAILED in step ...` line at the end. Keep the label width at 32 and the number width at 10 so old
and new logs line up.

User-facing docs are in `README.md`. Update it when the desktop setup or folder layout changes.

## Script conventions (match `SetupBase.ps1`)

- `$ErrorActionPreference = 'Stop'`. Pipe registry writes to `Out-Null`, and use
  `New-ItemProperty ... -Force` for values.
- Don't run `New-Item -Force` on a registry key that may already exist, because it wipes the key.
  Guard it with `Test-Path`.
- Settings that Explorer caches (desktop icon bag, taskbar) must be written **before**
  `Stop-Process -Name explorer -Force`, since Explorer restarts itself and would otherwise
  overwrite them.
- Desktop auto-arrange isn't reliable from the registry `FFlags` alone, because Explorer can save its
  own view state first. After the restart, the "Desktop auto-arrange (live)" step sets it on the
  running desktop view through `IFolderView2::SetCurrentFolderFlags`, retrying until the desktop
  window registers, and then reads the flags back to confirm.
- Win32 calls and COM interop go through a single `Add-Type -Namespace Sandbox -Name Desktop` block.
  Add new signatures to that block instead of compiling a second type. The COM interfaces are
  declared in **vtable order**, with `_Name` placeholder methods for slots that are never called.
  Inserting, removing or reordering a method silently calls the wrong one.
- You can check changes to the C# block on the host with a read-only call (for example, one that only
  reads the flags with `GetCurrentFolderFlags`). Never *set* anything on the host desktop.
- Put a short trailing comment on any magic registry value or flag explaining what it means.
