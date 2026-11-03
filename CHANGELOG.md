# Changelog

## 0.1.6 (unreleased)

- ScanBridge setup: **status dashboard** above the menu, re-read on every redraw (and **Refresh
  status**). Helpers in both all-users folders, PowerShell 7, the service account and its
  batch-logon right, each route's folders, destination and queue counts, the ingestion and alert
  certificates (days left, task-account key read), Sysmon rule coverage and the scheduled task.
  It ends with "Ready for unattended runs: Yes/No - first blocking reason". Uses the saved
  settings path silently when that file exists. Names and states only, with no IDs, thumbprints,
  addresses or paths, so a screenshot is safe to share. A read that fails shows Unknown, never
  No, and blocks Ready. No sign-in, receipt validation or PDF hashing happens; the Health item
  keeps those checks.
- ScanBridge setup: **Pick the SharePoint destination for a route**. Search sites, or paste a
  folder link, then pick the library and browse to (or create) the folder. DriveId and
  FolderItemId are written into that route with a preview and backup, and no IDs are typed.
- **Create the ingestion app and site access**: a dedicated app with Sites.Selected only, and a
  certificate for the task account (computer store with key read, or a profile store). Write
  access is granted on the site behind every route, then the settings' Auth block is written.
- **Create route folders and grant the task account access**: creates Source/Spool/Archive and the
  lock and alert folders when missing. Grants Modify on each and Read on the settings, after
  ScanBridge's own folder rules: separate folders, and Source and Spool on one drive.
- **Manage routes**: add a route (Source picked; Spool and Archive proposed per route on the same
  drive; short generic names, with System and Worker reserved), rename one, change its readiness
  age, or remove one. After adding, each dependent step is offered in turn: folders and access,
  destination, site access, Sysmon update. Rename and remove are refused while the route has
  files in Spool or PDFs in Source. The last route cannot be removed. **Change Source folder**
  (same refusal) moves a route, for example from a parent folder into a subfolder so sibling
  routes can share that parent, and then offers the folder-access and Sysmon updates.
- Settings backups use a millisecond stamp and a counter, so two saves in the same second no
  longer collide.
- **Grant the ingestion app access to route sites**: write for the configured app on every route's
  site, for routes added later. Already-granted sites are left alone.
- Shared certificate-location and key-grant prompts for the alert and ingestion apps. The settings
  writer lays out lists of tables (Routes) one per block. The setup menu follows setup order.
  Requires NSP.M365.Graph 0.1.3.

## 0.1.5 (2026-11-02)

- ScanBridge setup: **Install PowerShell 7 and ScanBridge modules for all users**. It installs
  PowerShell 7 when missing (the latest stable MSI from the PowerShell GitHub releases, kept only
  when Microsoft-signed). It installs NSP.ScanBridge, NSP.M365.Graph 0.1.2+ and
  Microsoft.Graph.Authentication from the Gallery into both all-users module folders, and removes
  older all-users NSP.M365.Graph copies. It then reports what PowerShell 7 would load without
  user-profile folders. Plans first; DRY RUN changes nothing.
- Task plan and registration use the all-users NSP.ScanBridge runner. Registration refuses while
  ScanBridge is not installed for all users, because the task account could not load it.

## 0.1.4 (2026-11-02)

- Add LocalAccounts and ScanBridge setup/diagnostic launcher entries, with plan-first task setup.
- ScanBridge setup: **Configure dispatch alerting**. The recipient is a saved answer, the sender is
  picked from a tenant search, and the alert app has no Graph permissions, sending only through
  one-mailbox Exchange RBAC. The settings `Alerts` block is written in place with a backup.
  Requires NSP.M365.Graph 0.1.2 with `Find-NSPGraphMailbox` and `Set-NSPGraphMailSendScope`.
- ScanBridge setup: certificate option for a local service account (computer store plus key read
  for that account only). Pick lists replace the typed PowerShell host, run account (`.\name`
  accepted) and interval, and the settings path is remembered.
- ScanBridge setup: **Set up the Sysmon scan trigger**. It watches the route Source folders for new
  PDFs with rules named `NSP ScanBridge`, and refuses a Spool or Archive inside a Source. A missing
  Sysmon can be downloaded from Microsoft (kept only when Microsoft-signed) or taken from a folder.
  Another configuration is kept by default (the rule group is saved for a manual merge) or
  replaced on request.
- Task installer `-SysmonTrigger`: an event trigger for those named file creates, delayed by route
  age + 30 s, alongside a 15-minute sweep on the same task. Runs are queued, never overlapping.
  The event's filename is never passed to the task.

All notable changes to NSP.Toolkit are documented here. Versions follow
[SemVer](https://semver.org/). `0.x` until it has real use outside NSP.

## 0.1.3 (2026-10-28)

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
