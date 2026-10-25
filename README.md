# NSP.Toolkit

Shared plumbing, and the single entry point, for NSP operator tools (NSP.ActiveDirectory, NSP.NPS,
NSP.PKI, NSP.FortiClient, NSP.Win.MDE). Windows PowerShell **5.1** compatible (and 7+); imports on a bare host.
NSP.Bootstrap and NSP.Console are loaded on first use, never declared as required modules.

## One entry point

```powershell
Install-Module NSP.Toolkit; Start-NSPToolkit           # menu of every tool
Start-NSPToolkit -Tool NPS                             # straight into one
```

`Start-NSPToolkit` relaunches elevated, marks the tools that apply to this machine (NPS on an NPS
server, PKI on a CA, ...), and installs a tool's module from the Gallery the first time it is
picked (it says what it is installing, from where and at which scope, before it does;
`NSP_NO_AUTOINSTALL=1` turns that off). `Launcher\Start-NSPToolkit.ps1` is a one-file bootstrap for a
server that can't run `Install-Module` yet (no NuGet provider, no TLS 1.2): download it over HTTPS,
check it, and run the saved copy - don't pipe it into `Invoke-Expression`.

## Client data and secrets

Each tool keeps its answers and hand-back files under `%ProgramData%\NSP\Toolkit\<Tool>`. The root is
limited to Administrators and SYSTEM when it is created. Answers holding a secret (NPS
`RADIUSSecret`) are only saved while that is still true: an elevated session puts the permissions
back, otherwise the save fails. A tool may give the desktop user read access to its `Responses\`
folder when it opens it in Explorer. `Clear-NSPToolClientData` blanks the secret fields when a server
is done with. `NSP_TOOLKIT_ROOT` (tests, portable use) is not checked - protect that folder yourself.

## What's in it

| Function | Purpose |
|---|---|
| `Start-NSPToolkit` / `Get-NSPToolkitTool` | The launcher menu, and the tool list behind it (module, entry function, installed version, applies here). |
| `Get-NSPToolWorkPath` | A tool's work folder: `%ProgramData%\NSP\Toolkit\<Tool>\{Answers,Responses,Logs}`, Administrators and SYSTEM only. |
| `Get-NSPToolAnswers` / `Save-NSPToolAnswers` | A tool's saved answers in its work folder. |
| `Import-NSPToolSeedAnswers` | Merge the answers a launcher (shim) carried into the saved ones - what each `Start-NSP*Manager -SeedAnswersJson` does. |
| `Merge-NSPHandoffAnswers` | The per-field merge: live answers win; new fields are added; differing fields are prompted (keep Live / take Incoming / All / Skip). |
| `New-NSPHandoff` / `Export-NSPHandoff` / `Import-NSPHandoff` | Hand-off files between tools: one file per tool per server, with a shared header around the tool's own payload and a SHA-256 of the payload. `Import-NSPHandoff` also reads the zip-era `*_CAResponse.json`, `*_NPSResponse.json` and `ADInventory_*.json` files. |
| `Move-NSPToolLegacyData` | Moves what a zip-era install left on a server (answers next to the script, extracted folders, hand-back files, answers embedded in old shims) into the work folder, then removes the old copies. PFX files are kept. |
| `Clear-NSPToolClientData` | Blank a tool's secret answer fields (e.g. the RADIUS secret), or `-All`. |
| `Invoke-NSPStep` / `Get-NSPDryRun` / `Set-NSPDryRun` | The DRY RUN step engine every tool routes state changes through. |
| `Get-NSPToolVersionStatus` | "v1.2.0 (updated from v1.1.0)" header label; same state as the zip-era tools. |

## Hand-off header

```json
{ "Envelope": "NSP.Handoff", "EnvelopeVersion": 1, "Kind": "Answers|Response",
  "Tool": "NPS", "ToolVersion": "0.1.0", "PayloadSchema": 1,
  "Company": "...", "ComputerName": "...", "Domain": "...",
  "Generated": "2026-01-15T16:00:00Z", "GeneratedBy": "...", "PayloadSha256": "...",
  "Payload": { "...": "the tool's own data, unchanged" } }
```

Files are named `<Company>_<Tool>_<Kind>.json` and are never merged: each tool writes its own on
its own server.

## Tests

```powershell
.\tools\Test-Repo.ps1      # PSScriptAnalyzer + Pester 5 under Windows PowerShell 5.1 and pwsh
```
