# Changelog

All notable changes to NSP.Toolkit are documented here. Versions follow
[SemVer](https://semver.org/). `0.x` until it has real use outside NSP.

## 0.1.3 (unreleased)

- New tool `MDE`: NSP.Win.MDE's `Start-NSPMDETroubleshooter` (Defender for Endpoint EDR sharing-violation evidence), shown as applying where the Sense service is installed. `tools\Sync-SharedLoader.ps1` also writes NSP-Win-MDE's loader copy.
- `tools\Sync-SharedLoader.ps1` also writes NSP-SSLCertificates' loader copy (no change to the module).

## 0.1.2

- Release routine: `tools\Publish-ToGallery.ps1` now runs `Publish-NSPModule` from NSP.RepoTools, the checks every NSP module shares (including a client-reference sweep of the Git history). No change to the module itself.

## 0.1.1

From the 2026-10-02 security review:

- **Secrets fail closed.** Answers holding a tool's secret field (NPS `RADIUSSecret`) are saved only
  while `%ProgramData%\NSP\Toolkit` is limited to Administrators and SYSTEM; an elevated session puts
  the permissions back, otherwise the save fails and nothing is written. (`NSP_TOOLKIT_ROOT`
  overrides are not checked.)
- **Gallery installs are announced** - the module, minimum version and scope - before the sibling
  loader installs anything, and the installed version after. The loader is now one canonical file
  here; the tool modules carry generated copies (`tools\Sync-SharedLoader.ps1`) with a drift test.
- `Import-NSPToolSeedAnswers` supports `-WhatIf`.
- The launcher script no longer suggests piping a download into `Invoke-Expression`;
  `Install-Module NSP.Toolkit; Start-NSPToolkit` is the documented start.
- The loader dot-sources files in name order.

## 0.1.0

First release.

The other NSP modules it needs are installed from the PowerShell Gallery the first time they're needed,
so `Install-Module` of this one module is enough. Set `NSP_NO_AUTOINSTALL=1` to turn that off.
