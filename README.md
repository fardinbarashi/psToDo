# psToDo — Calendar Reminder

![logo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodologo.png)

A PowerShell solution that watches expiry dates in a JSON file and alerts a team by **mail** and **Microsoft Teams** before things lapse — certificates, secrets, tokens, host keys, license deadlines, or anything else with a deadline. It also renders a self-contained **HTML status dashboard** for IIS from the same data.

Built and tested on **PowerShell 7.3.1 (Core)**.

---

## Table of Contents
- [What's new](#whats-new)
- [Components](#components)
- [Requirements](#requirements)
- [HTML dashboard](#html-dashboard)
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

![PstoDo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodo.jpg)

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| PowerShell | **7.3.1 or later (Core)** |
| OS | Windows + Task Scheduler |
| IIS | Only for the HTML dashboard — **restrict who can see the site** (see below) |
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
Enable **Windows Authentication** on the site and add a `web.config`. The example below allows Domain Admins and denies Domain Users — line up the config sections if you already have some.

```xml
<configuration>
  <location path="MyPage.aspx/php/html">
    <system.web>
      <authorization>
        <allow users="DOMAIN\Domain Admins"/>
        <deny  users="DOMAIN\Domain Users"/>
      </authorization>
    </system.web>
  </location>
</configuration>
```

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
Setup-SenderMailbox-and-AccessPolicy.ps1     Create the alert sender mailbox + access policy (optional)
Create a self-signed cert to app-reg.ps1     Create the Graph client certificate (optional)

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

Files\
  db\monitorobjects.json               The objects being watched
  config\MonitorObjectComplete.json    Copy of every Completed object + copy date (auto-managed)
  state\sent-state.json                What has already been alerted (auto-managed)
  report\index.html                    Generated dashboard
  backup\                              Timestamped backups
Logs\                                  Per-run transcripts
```

---

## Roadmap
```
[x] Import-EntraAppRegistrations — sync app-registration secret & certificate expiry from Entra ID
[x] Import-M365MessageCenter — sync Message Center advisories that carry a deadline
[x] Delegated (user sign-in) importers for both plugins
[x] Report tabs — Monitored / Completed / No channel / No credentials / Not monitored
[x] Completed archive (Files\config\MonitorObjectComplete.json) with per-object copy date
```
