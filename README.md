# psToDo — Calendar Reminder

![logo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodologo.png)

A PowerShell solution that watches expiry dates in a JSON file and alerts a team by **mail** and **Microsoft Teams** before things lapse — certificates, secrets, tokens, host keys, license deadlines, or anything else with a deadline. It also renders a self-contained **HTML status dashboard** for IIS from the same data.

Built and tested on **PowerShell 7.3.1 (Core)**. The scripts avoid PowerShell 7-only syntax and are written to run on Windows PowerShell 5.1 as well.

---

## Table of Contents
- [What's new](#whats-new)
- [Components](#components)
- [Requirements](#requirements)
- [HTML dashboard](#html-dashboard)
- [Editing in the browser (edit.html)](#editing-in-the-browser-edithtml)
- [App registration & Graph permissions](#app-registration--graph-permissions)
- [How alerting works](#how-alerting-works)
- [Adding an object to monitor](#adding-an-object-to-monitor)
- [Object field reference](#object-field-reference)
- [State file & completed archive](#state-file--completed-archive)
- [Plugins (importers)](#plugins-importers)
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)

---

## What's new

### 1.4
- Beta onprem version : psToDo\BETA-Onprem Exchange
- **Editable dashboard (`edit.html`)** — the browser editor from the on-prem edition, now with **Teams** support: change objects, triggers, status, mail and Teams settings (including the webhook URL), add, duplicate and delete objects, and save straight back to `monitorobjects.json`. Only members of an AD editors group can save; everyone else who can open the site gets a read-only view. Every save is version-checked, backed up and logged. See [Editing in the browser](#editing-in-the-browser-edithtml).
- **IIS setup scripts** — `Install-help\Setup-IisReportSecurity.ps1` (Windows sign-in + IIS URL Authorization: only an AD group can open the site) and `Install-help\Setup-IisReportEditor.ps1` (turns on saving). A commented `Files\report\web.config` ships with the repo.
- **Fixes**
  - The Entra importers no longer crash on the second run (`Cannot convert null to type "System.DateTime"`) when an app without credentials has already been imported.
  - Scripts work when run with F8 / "Run Selection" (empty `$PSScriptRoot`): they fall back to the script path, then the current folder.
  - The HTML report's log file name no longer contains `/` (it created nested folders under `Logs`).
  - Windows PowerShell 5.1 compatibility: no `-AsArray`, `??` or other PowerShell 7-only syntax, JSON arrays are read and written the 5.1-safe way, and every `.ps1` is saved as UTF-8 with BOM.
  - The IIS example in this README (`system.web/authorization`) did not protect the static dashboard. It is replaced by IIS URL Authorization and the setup scripts.

### 1.3
- **Kanban mode** deployed.
- **Report split into five tabs**: **Monitored**, **Completed**, **No channel**, **No credentials**, **Not monitored**.
- **Completed archive** — objects with status `Completed` are **copied** (not moved) to `Files\config\MonitorObjectComplete.json` on every report run; the **Completed** tab is built only from that file.
- **No channel** tab — objects with neither mail nor Teams enabled, so they would never alert.
- App registrations with **no secret and no certificate** are imported and listed in the **No credentials** tab.
- Entra rows set `environment` to `Entra - <tenant name> - <tenant id>`; row detail shows **App ID** (Entra) or **Message ID** (Message Center).
- Added two **delegated importers** that sign in as a user (interactive) — no certificate or `MsGraphSettings.json` needed.

### 1.2
- HTML report gained a **Status** column (Backlog / Active / Completed) with coloured badges.
- Message Center rows carry a **severity** badge and a clickable **admin-center link**.

### 1.1
- Added the `Settings\plugin` importers for Entra app registrations and Microsoft 365 Message Center, each shipping as a versioned script with its own `config\version.json`.

---

## System design
![System-Design](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/appregmessagecenter2.jpg)

---

## Components

| Script | Job |
|--------|-----|
| `psToDo-v1.3.ps1` | Reads `db\monitorobjects.json`, decides what is due, and sends the alerts based on each object's configuration. |
| `psToDo-HTML-Report-v1.3.ps1` | Reads `db\monitorobjects.json` and writes an HTML status page. |
| `psToDo-HTML-Report-Editable-v1.4.ps1` | Writes `edit.html`: the same data as an editable page. Saves go through `Settings\Web\psToDo-api.ashx`. |

![PstoDo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodo.jpg)

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| PowerShell | **7.3.1 or later (Core)**; written to also run on Windows PowerShell 5.1 |
| OS | Windows + Task Scheduler |
| IIS | Only for the dashboards. Windows Authentication + URL Authorization and an AD group (`Install-help\Setup-IisReportSecurity.ps1`); ASP.NET 4.x only for saving from `edit.html` (`Install-help\Setup-IisReportEditor.ps1`) |
| Modules | `Microsoft.Graph.Authentication`; the importers also use `Microsoft.Graph.Applications`, `Microsoft.Graph.Devices.ServiceAnnouncement` and `Microsoft.Graph.Identity.DirectoryManagement` (installed automatically on first run) |
| App reg | Mail needs Graph + a certificate. Teams needs only a webhook URL. |

---

## HTML dashboard

The dashboard shows each object's expiry **urgency** (expired / critical / warning / ok) and its manual **Status** (Backlog / Active / Completed) as coloured badges. Message Center rows also show a **severity** badge and an **"Open in admin center"** link. Clicking a row expands its details.

![Web dashboard](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/wwebdashboard.jpg)

**Tabs:**

| Tab | Shows |
|-----|-------|
| Monitored | Active objects |
| Completed | Status `Completed`, read from `Files\config\MonitorObjectComplete.json` |
| No channel | Objects with neither mail nor Teams enabled |
| No credentials | App registrations with no secret or certificate |
| Not monitored | Objects with an invalid date |

On first run it creates the `Files\report\`, `Files\config\` and `Files\backup\psToDo-HTML-Report\` folders it needs.

### Restrict who can see the site (IIS)
The dashboard lists internal servers, accounts and Teams webhook URLs, so only an AD group should be able to open it. Use **Windows Authentication** together with **IIS URL Authorization** (`system.webServer/security/authorization`). Do **not** use `system.web/authorization`: those rules only apply to ASP.NET requests and do not protect a static `index.html`.

`Install-help\Setup-IisReportSecurity.ps1` does it all (run as Administrator on the IIS server; safe to re-run):
- installs Windows Authentication and URL Authorization,
- looks the AD group up (`psToDo-Viewers` by default) and writes `web.config` into the report folder (an existing one is backed up first),
- turns Windows Authentication on and Anonymous off for the site in `applicationHost.config` (these settings are locked at server level and give HTTP 500.19 if they are put in `web.config`),
- gives the group and the site's app pool NTFS Read on the report folder (with Windows sign-in IIS reads the page **as the signed-in user**),
- with `-CreateSite`, creates the site with its own app pool.

```powershell
.\Install-help\Setup-IisReportSecurity.ps1 -WhatIf
.\Install-help\Setup-IisReportSecurity.ps1 -Group 'CONTOSO\psToDo-Viewers' -CreateSite -Port 8080
```

The core of the `web.config` it writes (a commented copy ships in `Files\report\web.config`):
```xml
<configuration>
  <system.webServer>
    <security>
      <authorization>
        <clear />
        <add accessType="Allow" roles="CONTOSO\psToDo-Viewers" />
      </authorization>
    </security>
  </system.webServer>
</configuration>
```
A user who is added to the group must sign out and in again (new Kerberos ticket). Add an https binding: over plain http the sign-in is protected but the page content is not.

---

## Editing in the browser (edit.html)

`psToDo-HTML-Report-Editable-v1.4.ps1` writes `Files\report\edit.html` next to the dashboard. It shows the same objects as an editable table: name, expiry date, status, triggers and the **Mail** / **Teams** switches inline; target, environment, template, description, the mail settings and the **Teams settings (subject, body, webhook URL)** in each row's detail panel. Objects can be added, duplicated and deleted, and days left, urgency and the checks update while you type. Saving writes `Files\db\monitorobjects.json` directly; the alert script and `index.html` pick the change up on their next run.

| Who | What they get |
|-----|---------------|
| Members of the editors group (`psToDo-Editors`) | **Editing**: change, add, duplicate, delete, save |
| Everyone else the site lets in (`psToDo-Viewers`) | The same page, **read-only** |
| Page opened as a file, or the save handler is not reachable | The snapshot embedded when the page was generated, read-only, with the reason |

**How saving works.** The page is static; it loads and saves through `psToDo-api.ashx`, a small ASP.NET handler next to it (the editable report copies it from `Settings\Web` on every run). The handler:
- lets only members of the editors group save (`appSettings` key `psToDo:EditorsGroup`; empty = nobody can save),
- refuses a save if `monitorobjects.json` changed after the page loaded it, for example by another editor or a plugin run (HTTP 409; the page offers to download your version),
- checks the data before writing anything: unique id, name, `yyyy-MM-dd` dates, triggers 0–3650, recipients as a list, and an `https://` webhook when Teams is on,
- backs up the current file to `Files\backup\psToDo\monitorobjects-<time>-web-<user>.json`, then writes a temp file and swaps it in, as UTF-8 with BOM,
- logs every save (who, when, object count, backup name) to `Logs\psToDo-web-edits.log`,
- only accepts saves with the header `X-psToDo-Request: 1` from the same origin (CSRF protection).

**Checks on the page** (errors block Save, warnings do not):
- Errors: no name, invalid date, trigger that is not a whole number 0–3650, duplicate id, invalid e-mail address, a `REPLACE_ME` placeholder address, Teams on with a webhook that does not start with `https://`.
- Warnings: no date or no triggers (not monitored), mail on without sender or recipients, Teams on without a webhook, and **neither mail nor Teams on** (the object never alerts).

**Duplicate** copies the mail and Teams settings, including the webhook URL (the copy alerts the same channel), and drops the importer fields (`source`, `entraKeyId`, `messageId`, …), so the copy becomes a normal object.

**One-time setup** (as Administrator on the IIS server, after [Restrict who can see the site](#restrict-who-can-see-the-site-iis)):
1. Create an AD security group for the editors, e.g. `psToDo-Editors`.
2. Run `Install-help\Setup-IisReportEditor.ps1`. It installs ASP.NET 4.x, sets the app pool to .NET CLR v4.0, lets the editors group into the site, allows `.ashx` through request filtering, writes the `appSettings` the handler reads, and sets NTFS rights: **Modify** for the app pool on `Files\db`, `Files\backup\psToDo` and `Logs` (the handler runs as the app pool), **Read** for the editors on the report folder.
   ```powershell
   .\Install-help\Setup-IisReportEditor.ps1 -WhatIf
   .\Install-help\Setup-IisReportEditor.ps1 -EditorsGroup 'CONTOSO\psToDo-Editors'
   ```
3. Run `.\psToDo-HTML-Report-Editable-v1.4.ps1` (add it to the scheduled report task) and open `https://<server>/edit.html`. Members of the editors group see **Editing**.

> **Security:** editors decide who gets alert mail, what it says and which Teams channel webhook receives the alerts. Keep the editors group small. Viewers can see the webhook URLs, just as in `index.html`, and anyone who has a webhook URL can post to that channel.

**Troubleshooting**

| Symptom | Cause / fix |
|---------|-------------|
| HTTP 401 | Not in `psToDo-Viewers` / `psToDo-Editors`, or added recently: sign out and in again. |
| HTTP 500.19 | Windows/Anonymous authentication set in `web.config`, or `--` inside an XML comment. Re-run the setup scripts. |
| Page shows the *snapshot* / *HTTP 404* | ASP.NET 4.x is missing or `.ashx` is blocked by request filtering: run `Setup-IisReportEditor.ps1`. |
| *Read-only* for an editor | Not a member of the group in `psToDo:EditorsGroup`, or not signed in again after being added. |
| Save fails with *access denied* | The app pool lacks Modify on `Files\db`, `Files\backup\psToDo` or `Logs`: re-run `Setup-IisReportEditor.ps1`. |
| Save refused: *changed by someone else* | Someone (or a plugin run) saved in between. Download your version, Reload, and apply your change again. |

---

## App registration & Graph permissions

Mail is sent through Microsoft Graph using **certificate authentication** and an **application permission** — there is no signed-in user, so delegated permissions do not apply.

### 1. App registration values
From the app's **Overview** page in the Entra portal, collect these into `Settings\Config\MsGraphSettings.json`:

| Value | Setting | Note |
|-------|---------|------|
| Application (client) ID | `AppId` | Not the Object ID — they are different GUIDs. |
| Directory (tenant) ID | `TenantId` | |
| Certificate thumbprint | `CertificateThumbprint` | Private key stays on the server; upload the public `.cer`. |

```json
{
    "AppId": "Application (client) ID — App registration → Overview → Application (client) ID",
    "ClientId": "Same value as AppId (Application client ID) — same place, copy the same GUID",
    "TenantId": "Directory (tenant) ID — App registration → Overview → Directory (tenant) ID",
    "CertificateThumbprint": "Certificate thumbprint — App registration → Certificates & secrets → Certificates tab → Thumbprint column (same value $cert.Thumbprint returned when you created the cert)"
}
```

### 2. Certificate
The script authenticates with a certificate in `Cert:\LocalMachine\My`. Create it as **exportable** if it must run on more than one server (Script: `Create a self-signed cert to app-reg.ps1`):

```powershell
$cert = New-SelfSignedCertificate `
  -Subject           'CN=PsToDo' `
  -CertStoreLocation 'Cert:\LocalMachine\My' `
  -KeyExportPolicy   Exportable `
  -KeyAlgorithm      RSA `
  -KeyLength         2048 `
  -HashAlgorithm     SHA256 `
  -NotAfter          (Get-Date).AddYears(2) `
  -Provider          'Microsoft Software Key Storage Provider'
$cert.Thumbprint
Export-Certificate -Cert $cert -FilePath 'C:\temp\PsToDo.cer'
```

### 3. Graph permissions
All permissions are **Application** type (app-only certificate auth) and require **admin consent** (App registration → API permissions → Microsoft Graph → Application permissions → Grant admin consent). Teams alerts need no Graph permission — they post to a Workflows webhook.

| Permission | Needed for |
|------------|------------|
| `Mail.Send` | `psToDo-v1.3.ps1` — send alert mail via Graph |
| `Application.Read.All` | `Import-EntraAppRegistrations` — read app-registration secrets & certificates |
| `ServiceMessage.Read.All` | `Import-M365MessageCenter` — read Message Center advisories |
| `Organization.Read.All` | `Import-EntraAppRegistrations` — read tenant name for the `Entra - <name> - <id>` tag (optional; falls back to tenant id) |

> If the **Type** column shows *Delegated* instead of *Application*, Graph returns `403` at run time.

### Restrict who the app can send as (best practice)
`Mail.Send` as an application permission lets the app send as **any mailbox in the tenant**. Scope it down with an application access policy (Script: `Setup-SenderMailbox-and-AccessPolicy.ps1` does this in one step):

```powershell
Connect-ExchangeOnline
New-DistributionGroup -Name 'CalenderReminderSenders' -Type Security `
  -PrimarySmtpAddress CalenderReminderSenders@lab.local `
  -Members CalenderReminder@lab.local
New-ApplicationAccessPolicy -AppId <appId> `
  -PolicyScopeGroupId CalenderReminderSenders@lab.local `
  -AccessRight RestrictAccess `
  -Description 'Restrict CalenderReminder to its own mailbox'
Test-ApplicationAccessPolicy -Identity CalenderReminder@lab.local -AppId <appId>
```
The policy can take up to 30 minutes to apply.

---

## How alerting works

Each `dateTrigger` is a number of **days remaining until expiry** and marks a moment an alert goes out. Order in the file does not matter — the script sorts them and treats the **smallest as the most urgent**, because it sits closest to the expiry date. Every object has its own triggers and expiry date; nothing is shared between rows.
| Window | Status | Meaning |
|--------|--------|---------|
| `1dateTrigger` | notice / ok | First, gentle heads-up |
| `2dateTrigger` | warning | Second alert point |
| `3dateTrigger` | critical | Last call |
| below 0 | expired | Handled by the script (no JSON value) |

Mail examples per window:
| 1dateTrigger | 2dateTrigger | 3dateTrigger | below 0 |
|---|---|---|---|
| ![Mail1](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail1.jpg) | ![Mail2](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail2.jpg) | ![Mail3](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail3.jpg) | ![Mail4](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail4.jpg) |

---

## Adding an object to monitor

`Files\db\monitorobjects.json` is an array of objects you add to manually.

**Step 1 — Core fields (mandatory):** `id`, `name`, `expireDate` (`yyyy-MM-dd`), and the three triggers `1dateTrigger` / `2dateTrigger` / `3dateTrigger`.

**Step 2 — Alert channels (switches):** set `notifyMethodbyMail` and/or `notifyMethodbyTeams` to a real boolean (`true`, not `"true"`). Either or both can be on.

**Step 3A — Mail block** (only if `notifyMethodbyMail` is true):
```json
"mail": {
  "mailSender": "AutomateB@M365x04357061.OnMicrosoft.com",
  "mailSubject": "Wildcard cert lab.local expires soon",
  "mailBody": "The certificate is approaching its expiry date.",
  "mailRecipients": ["AdeleV@M365x04357061.OnMicrosoft.com"]
}
```

**Step 3B — Teams block** (only if `notifyMethodbyTeams` is true):
```json
"teams": {
  "teamSubject": "Wildcard cert lab.local expires soon",
  "teamBody": "The certificate is approaching its expiry date.",
  "teamWebhookUrl": "https://outlook.office.com/webhook/..."
}
```

**Step 4 — Status (optional):** set `status` to `Backlog`, `Active` or `Completed` for a coloured badge in the dashboard. Omitted → treated as `Backlog`. Does not affect alerting.

---

## Object field reference

Every entry describes one thing to watch. Nothing is shared between objects.

| Field | Type | What it is |
|-------|------|------------|
| `id` | string | Unique identifier (used in the state key and log lines). Use a number for best interaction. |
| `name` | string | Human-readable label shown in mails, Teams cards and the dashboard. |
| `expireDate` | string | The deadline, `yyyy-MM-dd`. Everything is calculated from this. Unparseable → skipped and left unmonitored. |
| `template` | string | Free-text tag for the kind of object. Context only. |
| `servername` | string | The host or resource the object belongs to. Shown in every alert. |
| `environment` | string | Which environment it lives in. Context only. |
| `status` | string | Optional badge: `Backlog`, `Active` or `Completed`. Defaults to `Backlog`. Not used in alerting. |
| `description` | string | The "Action required" text in the mail/card — write real instructions here. |
| `1dateTrigger` | number | First alert point, days before expiry. |
| `2dateTrigger` | number | Second alert point, days before expiry. |
| `3dateTrigger` | number | Third alert point, days before expiry. |
| `notifyMethodbyMail` | boolean | `true` sends mail through Graph. |
| `notifyMethodbyTeams` | boolean | `true` posts to the Teams webhook. |
| `mail` | object | Mail settings, used only when `notifyMethodbyMail` is `true`. |
| `teams` | object | Teams settings, used only when `notifyMethodbyTeams` is `true`. |

**`mail` object:** `mailSender` (a real sendable mailbox — alias/DL is rejected by Graph), `mailSubject` (script prepends a severity tag), `mailBody` (intro sentence), `mailRecipients` (array; all land on the same message).

**`teams` object:** `teamSubject` (card title), `teamBody` (intro line), `teamWebhookUrl` (Workflows webhook URL).

**Fields added automatically by the importers** (ignored by alerting, safe to leave; they enable idempotent updates and extra dashboard context): `source`, `appId`, `entraKeyId`, `noCredentials` (Entra); `messageId`, `severity`, `messageLink` (Message Center).

---

## State file & completed archive

**`Files\state\sent-state.json`** records which windows have already alerted, keyed by `id_expireDate_trigger`. This gives two things a plain date-match cannot:
- **Each window fires exactly once**, even when the script runs daily.
- **A missed run is caught up** on the next run — if the server was down on the trigger day, the window is still open.

Renewing a certificate changes its `expireDate`, which changes the key prefix, retires the old keys, and re-arms all three windows. The expiry day itself and a recurring post-expiry reminder are also handled.

**`Files\config\MonitorObjectComplete.json`** is written on every report run: each object with status `Completed` is **copied** here (it stays in `monitorobjects.json`). Each copy gets a `copiedDate` set on first copy and **preserved on later runs** (matched on `entraKeyId`, then `messageId`, then `appId`, otherwise `name`+`servername`+`expireDate`), shown next to the Completed badge. Set an object back to `Active` and it drops out on the next run. Change the location with `-CompleteJsonPath`.

---

## Plugins (importers)

Two optional importers in `Settings\plugin` pull expiry dates straight from the tenant into `monitorobjects.json`.

| Script | Job |
|--------|-----|
| `Import-EntraAppRegistrations-v1.3.ps1` | Reads client-secret **and** certificate expiry from every Entra app registration. |
| `Import-M365MessageCenter-v1.1.3.ps1` | Reads Message Center advisories and imports the ones that carry a deadline. |

### Shared behaviour (both importers)
- **Own defaults file** (`entra\config\entra-app-defaults.json` / `messagecenter\config\messagecenter-defaults.json`): set triggers, mail addresses, status and notification switches once, and every imported row inherits them. Tokens like `{{name}}`, `{{expireDate}}`, `{{servername}}`, `{{environment}}` are substituted per object. New rows get `status: "Backlog"`.
- **Own version file** (`config\version.json`): version + a short `Changes` note, printed at the top of each run.
- **Never overwrites your data.** A timestamped backup of `monitorobjects.json` is taken into `Files\backup\psToDo\` first. Manual objects are untouched; previously imported rows get only their `expireDate` refreshed; new ones are appended with a fresh `id`. Matching is idempotent (`entraKeyId` for Entra, `messageId` for Message Center).
- **Delegated variant** (`...-Delegated-v1.3.ps1`): same job, signs in as a **user** (interactive) instead of app registration + certificate — no cert or `MsGraphSettings.json` needed. Use `-UseDeviceCode` / `-UseMockData` as applicable.

| Switch | Effect |
|--------|--------|
| `-UseMockData` | Skip Graph and use built-in sample data — test backup/merge with no tenant. |
| `-NoDateRefresh` | Do not update `expireDate` on already-imported objects. |
| `-WhatIf` | Show what would change without writing (nothing is backed up or saved). |

> Always WhatIf-run first.
> ```powershell
> .\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1 -UseMockData -WhatIf
> .\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1 -WhatIf   # live
> ```

### Entra importer — specifics
Every app registration is included (no filtering). Apps with no secret and no certificate are still listed (keyed by `appId`, shown in **No credentials**, no expiry, never alert). Field mapping: `name` ← app + credential display name; `expireDate` ← credential `endDateTime`; `servername`/`appId` ← Application (client) ID; `environment` ← `Entra - <tenant name> - <tenant id>`.
**Permissions:** `Application.Read.All` (+ `Organization.Read.All` or `Directory.Read.All` for the tenant-name tag). Reuses the existing certificate flow.

### Message Center importer — specifics
Reads every service announcement message and keeps **only** those with an `actionRequiredByDateTime` (a real deadline), which becomes `expireDate`. No service/severity filter. Field mapping: `name` ← message id + title; `servername` ← affected services; `messageId` ← advisory id; `severity` ← `normal`/`high`/`critical` (badge); `messageLink` ← admin-center deep link built from the id.
**Note:** release status (Scheduled / Rolling out / Launched) and the admin-center High/Medium/Low relevance are not exposed by Graph, so they can't be imported — `severity` is the closest signal.
**Permissions:** `ServiceMessage.Read.All`. Reuses the existing certificate flow.

---

## Repository layout
```
psToDo-v1.3.ps1                              Evaluate and alert
psToDo-HTML-Report-v1.3.ps1                  Build the HTML dashboard
psToDo-HTML-Report-Editable-v1.4.ps1         Build the editable dashboard (edit.html)

Install-help\
  Setup-SenderMailbox-and-AccessPolicy.ps1   Create the alert sender mailbox + access policy (optional)
  Create a self-signed cert to app-reg.ps1   Create the Graph client certificate (optional)
  Setup-IisReportSecurity.ps1                IIS: Windows sign-in, only an AD group may open the site
  Setup-IisReportEditor.ps1                  IIS: turn on saving from edit.html for an editors group

Settings\
  Functions\
    psToDo\              Connect-CalenderReminderGraph, Format-AlertAdaptiveCard,
                         Format-AlertMailBody, Get-AlertPresentation, Get-SentState,
                         Initialize-RequiredModules, Save-SentState, Send-AlertMail,
                         Send-AlertNotification, Send-AlertTeams
    psToDo-HtmlReport\   Get-Urgency, Test-NotifyFlag
  Config\
    MsGraphSettings.json   Tenant, app and certificate
    version.json           Tool version + change note + history
  plugin\
    Import-EntraAppRegistrations-v1.3.ps1              Entra secret & cert expiry (app-registration auth)
    Import-M365MessageCenter-v1.1.3.ps1               Message Center advisories (app-registration auth)
    Import-EntraAppRegistrations-Delegated-v1.3.ps1   Same, interactive user sign-in
    Import-M365MessageCenter-Delegated-v1.3.ps1       Same, interactive user sign-in
    entra\config\          entra-app-defaults.json, version.json
    messagecenter\config\  messagecenter-defaults.json, version.json
  Web\
    edit-template.html     Template for edit.html
    psToDo-api.ashx        Load/save handler for edit.html (copied next to it on every run)

Files\
  db\monitorobjects.json               The objects being watched
  config\MonitorObjectComplete.json    Copy of every Completed object + copy date (auto-managed)
  state\sent-state.json                What has already been alerted (auto-managed)
  report\index.html                    Generated dashboard
  report\edit.html                     Generated editable dashboard (+ psToDo-api.ashx)
  report\web.config                    IIS access control (written by the setup scripts)
  backup\                              Timestamped backups (also one per save from edit.html)
Logs\                                  Per-run transcripts + psToDo-web-edits.log (who saved what)
```

---

## Roadmap
```
[x] Import-EntraAppRegistrations — sync app-registration secret & certificate expiry from Entra ID
[x] Import-M365MessageCenter — sync Message Center advisories that carry a deadline
[x] Delegated (user sign-in) importers for both plugins
[x] Report tabs — Monitored / Completed / No channel / No credentials / Not monitored
[x] Completed archive (Files\config\MonitorObjectComplete.json) with per-object copy date
[x] Editable dashboard (edit.html): AD-group editing incl. Teams settings, version-checked saves
```
