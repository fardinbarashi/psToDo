# psToDo — Calender Reminder
![logo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodologo.png) 
A PowerShell solution that watches expiry dates in a JSON file and alerts a team by **mail** and **Microsoft Teams** before things lapse
```
- upgrade-notifcations to teams
- certificates
- secrets
- tokens
- host keys
- license deadline
 ``` 
anything with a deadline. It also renders a self-contained **HTML status dashboard** for IIS.
Built and tested on **PowerShell 7.3.1 (Core)**.
The scripts create the folders they need on first run.
## Table of Contents
- [What's new](#whats-new)
- [psToDo-HTML-Report](#pstodo-html-report)
- [System requirements (HTML Report)](#system-requirements-html-report)
- [psToDo](#pstodo)
- [System requirements (psToDo)](#system-requirements-pstodo)
- [API permissions (all features)](#api-permissions-all-features)
- [Teams webhook (optional)](#teams-webhook-optional)
- [How alerting works](#how-alerting-works)
- [How to add a new object to monitor](#how-to-add-new-object-to-monitor-in-the-dbmonitorobjectsjson)
- [Entra ID app registration importer (plugin)](#entra-id-app-registration-importer-plugin)
- [Microsoft 365 Message Center importer (plugin)](#microsoft-365-message-center-importer-plugin)
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)

---
## What's new

### 1.3 :
**Kanban mode deloyed**
![Kanban-mode](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/appregmessagecenter.jpg) 

**Report tabs & completed archive.**
- The HTML report now has **five tabs**: **Monitored**, **Completed**, **No channel**, **No credentials** and **Not monitored**.
- **Completed archive** — objects with status **Completed** are copied to their own file, `Files\config\MonitorObjectComplete.json`, each time the report runs. It is a **copy, not a move**: the objects stay in `monitorobjects.json`. The **Completed** tab is built **only** from that file, and shows a note at the top naming the source file.
- **Copy date** — each object written to `MonitorObjectComplete.json` gets a `copiedDate` (the day it was first copied over). The date is **preserved across runs** and is shown next to the **Completed** badge in the row detail, e.g. `Status  Completed  2026-08-10`.
- **No channel** tab — lists any object that has **neither mail nor Teams** enabled (`notifyMethodbyMail` and `notifyMethodbyTeams` both off), so it would never alert. This replaces the old warning banner with a dedicated tab that names the affected objects.

**Report** — more data to report.
- The HTML report is now split into tabs: **Monitored**, **No credentials**, and **Not monitored**
- App registrations with **no secret and no certificate** are imported too and listed in the **No credentials** tab
- Entra rows set **environment** to `Entra - <tenant name> - <tenant id>`, and the row detail shows the **App ID** (Entra) or **Message ID** (Message Center).
- Added two **delegated importers** that sign in as a **user** (interactive) instead of an app registration + certificate — no certificate or `MsGraphSettings.json` needed.
- Reading the tenant name for the environment tag uses `Organization.Read.All` (falls back to the tenant id if it is not granted).

### 1.2 :
the HTML report has a new **Status** column (Backlog / Active / Completed) with coloured badges, and Message Center rows now carry a **severity** badge and a clickable **admin-center link**. 

### 1.1 :
added the `Settings\plugin` importers for Entra app registrations and Microsoft 365 Message Center. Each plugin ships as a versioned script with its own `config\version.json` (version + a short `Changes` note).

---
## System-Design
![System-Design](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/appregmessagecenter2.jpg) 

---
## psToDo-HTML-Report
| Script | Job |
|--------|-----|
| `psToDo-HTML-Report-v1.3.ps1` | Reads objects in db\monitorobjects.json and writes an HTML status page |
![Web dashboard](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/wwebdashboard.jpg)
The dashboard shows each object's expiry **urgency** (expired / critical / warning / ok) and a manual **Status** (Backlog / Active / Completed) as coloured badges. Rows imported from the Message Center also show a **severity** badge and an **"Open in admin center"** link. It is split into five tabs — **Monitored**, **Completed** (status `Completed`, read from `Files\config\MonitorObjectComplete.json`), **No channel** (objects with neither mail nor Teams enabled), **No credentials** (app registrations with no secret or certificate), and **Not monitored** (objects with an invalid date). Clicking a row expands its details; for Entra rows this includes the **App ID**, for Message Center rows the **Message ID**, and for completed rows the **copy date** next to the Status badge. It creates the `Files\report\`, `Files\config\` and `Files\backup\psToDo-HTML-Report\` folders it needs on first run.
## System requirements (HTML Report)
### Runtime
```
| Requirement | Detail |
|-------------|--------|
| PowerShell | **7.3.1 or later (Core)**. The scripts use PowerShell 7 syntax (`??`, ternary) that fails on Windows PowerShell 5.1. Run with `pwsh`, not `powershell`.
| OS | Windows. The certificate store paths (`Cert:\LocalMachine\My`) and Task Scheduler
| IIS | Restrict who can se the site 
        The webhook URL is the credential. Anyone who has it can post to the channel. Keep it out of the repo and out of the HTML report.
        You'll need to add a web.config
        You will need Windows Authentication enabled under Authentication in your site preferences for this to work,
        The below will allow Domain Admins and deny Domain Users. Make sure you line up the config sections if you already have a section, etc.
        
         <configuration>
           <location path="MyPage.aspx/php/html">
            <system.web>
             <authorization>
              <allow users="DOMAIN\Domain Admins"/>
              <deny users="DOMAIN\Domain Users"/>
             </authorization>
            </system.web>
           </location>
         </configuration>
```
---
## psToDo
| Script | Job |
|--------|-----|
| `psToDo-v1.3.ps1` | Reads the objects, db\monitorobjects.json, The objects being checked, decides what is due, sends the alerts based on objects configuration |
![PstoDo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodo.jpg)
## System requirements (psToDo)
### Runtime
```
| Requirement | Detail |
|-------------|--------|
| PowerShell | **7.3.1 or later (Core)**. The scripts use PowerShell 7 syntax (`??`, ternary) that fails on Windows PowerShell 5.1. Run with `pwsh`, not `powershell`.
| OS | Windows. The certificate store paths (`Cert:\LocalMachine\My`) 
| Task Scheduler | For unattended use, schedule `psToDo-v1.3.ps1` daily with Task Scheduler under
                   a service account that has Read on the certificate's private key.
                   Run it with `pwsh`, not Windows PowerShell 5.1 — the scripts use PowerShell 7 syntax.

| Module | Microsoft.Graph.Authentication (the importers also use Microsoft.Graph.Applications, Microsoft.Graph.Devices.ServiceAnnouncement and Microsoft.Graph.Identity.DirectoryManagement, installed automatically on first run).
| Appreg | Mail needs Graph and a certificate. Teams needs only a webhook URL — no app registration, no module, no certificate..
```

---
### App registration (for mail)
Mail is sent through Microsoft Graph using **certificate authentication** and an **application permission**. There is no signed-in user, so delegated permissions do not apply.
**1 - Create or open the app registration**

Entra portal → **App registrations** → your app. Note two values from the **Overview** page:
- **Application (client) ID** → goes into `AppId` ( Settings\Config\MsGraphSettings.json ) / Use the **Application (client) ID**, not the Object ID. They are different GUIDs on the same app
- **Directory (tenant) ID** → goes into `TenantId` ( Settings\Config\MsGraphSettings.json )
- The private key stays on the server that runs the script, Upload the public.cer → goes into `CertificateThumbprint` ( Settings\Config\MsGraphSettings.json )
---> The script authenticates with a certificate in `Cert:\LocalMachine\My`. 
     Create it as **exportable** if it must run on more than one server, and use the modern KSP provider:
      powershell : 
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

you can use script : Create a self-signed cert to app-reg.ps1
More info : https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate?view=windowsserver2025-ps

#### MsGraphSettings.json File layout ->
```
 Settings\Config\MsGraphSettings.json:
{
  "TenantId": "00000000-0000-0000-0000-000000000000",
  "AppId": "00000000-0000-0000-0000-000000000000",
  "CertificateThumbprint": "A1B2C3..."
}
```
---
#### Grant the Mail.Send permission
API permissions → Add a permission → Microsoft Graph → Application permissions →
search Mail.Send → add it → then Grant admin consent.
( If Type says *Delegated*, or Status is not granted, Graph returns `403` when sending. ) 
```
2 - For best practice — Restrict who the app can send as
```
#### Example : 
Mail.Send` as an application permission lets the app send as **any mailbox in the tenant**. Scope it down:
#powershell
Connect-ExchangeOnline
New-DistributionGroup -Name 'CalenderReminderSenders' -Type Security `
    -PrimarySmtpAddress CalenderReminderSenders@lab.local `
    -Members CalenderReminder@lab.local
New-ApplicationAccessPolicy -AppId <appId> `
    -PolicyScopeGroupId CalenderReminderSenders@lab.local `
    -AccessRight RestrictAccess `
    -Description 'Restrict CalenderReminder to its own mailbox'
Test-ApplicationAccessPolicy -Identity CalenderReminder@lab.local -AppId <appId>
The policy can take up to 30 minutes to apply.

#### helper script Setup-SenderMailbox-and-AccessPolicy.ps1
in the repository root creates a dedicated shared mailbox and this access policy for you in one step.

#### API permissions (all features)

Every Graph permission the tool uses is an **Application** permission (app-only certificate auth, no signed-in user) and requires **admin consent**. Add them under **App registration → API permissions → Microsoft Graph → Application permissions**, then click **Grant admin consent**.

| Permission | Type | Needed for |
|------------|------|------------|
| `Mail.Send` | Application | `psToDo-v1.3.ps1` — send alert mail via Graph |
| `Application.Read.All` | Application | `Import-EntraAppRegistrations` — read app registration secrets & certificates |
| `ServiceMessage.Read.All` | Application | `Import-M365MessageCenter` — read Message Center advisories |
| `Organization.Read.All` | Application | `Import-EntraAppRegistrations` — read the tenant name for the `Entra - <name> - <id>` environment tag (optional; falls back to the tenant id) |
Teams alerts need no Graph permission — they post to a Workflows webhook. If the **Type** column shows *Delegated* instead of *Application*, Graph returns `403` at run time.

The **delegated importers** (`...-Delegated-...`) do not need any of the above pre-granted on an app registration — 
they sign in as a user and use the built-in Microsoft Graph PowerShell client, so the signed-in user just needs the equivalent **delegated** scope (`Application.Read.All`, `ServiceMessage.Read.All`, `Organization.Read.All`) and a role that permits the read.

---
## Teams webhook (optional)
Teams alerts use a **Workflows (Power Automate) webhook**, not Graph. App-only posting to a channel is a protected Graph API that needs Microsoft approval; the webhook needs none.
In the target channel: **Manage channel → Workflows →** *"Post to a channel when a webhook request is received"* → copy the `https://` URL into each object's `teamWebhookUrl`.

---
## How alerting works
Each number is *days remaining until expiry*, and each is the moment an alert goes out. Order in the file does not matter — the script sorts them and uses the **smallest as the most urgent**, because the smallest number sits closest to the expiry date.
Example : 
```
| Window | Status |
|--------------|--------------------|
| 1dateTrigger | notice / ok |  First alert point, in **days before expiry**. | First, gentle heads-up |
| 2dateTrigger | warning | Second alert point, in days before expiry. |  warning |
| 3dateTrigger | critical | Third alert point, in days before expiry. | critical, last call |
| below 0      | expired | no json-value, is controlled with script
```
The smallest trigger sits closest to expiry, so it is the most urgent. Every object can have unique triggers and a unique expiry date — nothing is shared between rows.
Forexample Mail alerts: 
### 1dateTrigger : 
![1dateTrigger Mail1](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail1.jpg) 

### 2dateTrigger : 
![2dateTrigger Mail2](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail2.jpg)

### 3dateTrigger : 
![3dateTrigger Mail3](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail3.jpg) 

### below 0 :
![below 0 Mail4](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail4.jpg)

---

## How to add new object to monitor in The db\monitorobjects.json
`Files\db\monitorobjects.json` is an array of objects that you need do manually add data to.

#### HowTo : 
Step 1: Fill in the Mandatory Core Fields
```
These fields set up the baseline monitoring. You must define these first to establish the object 
 - identity
  -> id
  -> name
 - the deadlines 
  -> expireDate
  -> 1dateTrigger 
  -> 2dateTrigger
  -> 3dateTrigger 
| `id` | Number
| `name` | string | Human-readable label shown in mails, Teams cards and the dashboard. |
| `expireDate` | `yyyy-MM-dd` format
| `1dateTrigger` | First alert point,
| `2dateTrigger` | Second alert point
| `3dateTrigger` | Third alert point
```

Step 2: Toggle Your Alert Channels (The Switches)
These boolean toggles act as switches. Setting either to true branches the logic and forces you to configure the corresponding block in Step 3:
```
| `notifyMethodbyMail` | boolean | `true` sends mail through Graph. Must be a real boolean, not `"true"` in quotes. 
| `notifyMethodbyTeams` | boolean | `true` posts to the Teams webhook. Both can be true — the object then alerts on both channels.
```

Step 3: Fill in the Details for the Activated Channels
Step 3A (Only if notifyMethodbyMail is true):
You must now provide the email routing details so the system knows how to dispatch the email:
#### Example : 
```
    "mail": {
        "mailSender": "AutomateB@M365x04357061.OnMicrosoft.com",
        "mailSubject": "Wildcard cert lab.local expires soon",
        "mailBody": "The certificate is approaching its expiry date.",
        "mailRecipients": [
            "AdeleV@M365x04357061.OnMicrosoft.com"
        ]
    },
```

Step 3B (Only if notifyMethodbyTeams is true):
You must now configure the Teams details so the system can post the alert to your Teams channel:
```
    "teams": {
        "teamSubject": "Wildcard cert lab.local expires soon",
        "teamBody": "The certificate is approaching its expiry date.",
        "teamWebhookUrl": "https://outlook.office.com/webhook/..."
    }
 }
```

Step 4 (Optional): Set a workflow status
`status` is an optional field. Set it to `Backlog`, `Active` or `Completed` and it shows up as a coloured badge in the dashboard. If you leave it out, the dashboard treats the object as `Backlog`. It does not affect alerting.

---
### Object field reference
Every entry in `monitorobjects.json` describes one thing to watch. Fields below in the order they appear.
Nothing is shared between objects.
| Field | Type | What it is |
|-------|------|------------|
| `id` | string | Unique identifier for the object. Used in the state key and in log lines. Must be unique across the file, use a number for best interaction. |
| `name` | string | Human-readable label shown in mails, Teams cards and the dashboard. |
| `expireDate` | string | The deadline, in `yyyy-MM-dd` format. Everything is calculated from this date. An unparseable value is skipped and the object is left unmonitored. |
| `template` | string | Free-text tag for what kind of object this is (certificate template, resource type). Shown for context; not used in logic. |
| `servername` | string | The host or resource the object belongs to. Shown in every alert. |
| `environment` | string | Which environment it lives in (`prod.local`, `test.local`). Shown for context. |
| `status` | string | Optional workflow status shown as a coloured badge in the dashboard: `Backlog`, `Active` or `Completed`. Defaults to `Backlog` when omitted. Not used in alerting logic. |
| `description` | string | The action the recipient should take. This is the "Action required" text in the mail and card — write real instructions here, not a placeholder. |
| `1dateTrigger` | number | First alert point, in **days before expiry** (first, gentle heads-up). |
| `2dateTrigger` | number | Second alert point, in days before expiry (warning). |
| `3dateTrigger` | number | Third alert point, in days before expiry (critical, last call). |
| `notifyMethodbyMail` | boolean | `true` sends mail through Graph. Must be a real boolean, not `"true"` in quotes. |
| `notifyMethodbyTeams` | boolean | `true` posts to the Teams webhook. Both can be true — the object then alerts on both channels. |
| `mail` | object | Mail settings, used only when `notifyMethodbyMail` is `true`. |
| `teams` | object | Teams settings, used only when `notifyMethodbyTeams` is `true`. |
### The `mail` object
| Field | Type | What it is |
|-------|------|------------|
| `mailSender` | string | The mailbox the alert is sent *from*. Must be a real mailbox the app is allowed to send from — an alias or distribution group is rejected by Graph. |
| `mailSubject` | string | Base subject line. The script prepends a severity tag, e.g. `[CRITICAL]`. |
| `mailBody` | string | Intro sentence shown above the details table in the mail. |
| `mailRecipients` | array of strings | Who receives the mail. Multiple addresses land on the same message, so recipients can see each other. |
### The `teams` object
| Field | Type | What it is |
|-------|------|------------|
| `teamSubject` | string | Title shown on the Teams card. |
| `teamBody` | string | Intro line shown under the title on the card. |
| `teamWebhookUrl` | string | The Workflows webhook URL for the target channel. |
### Fields added automatically by the importers
The plugins add a few extra fields to the rows they create. They are ignored by the alerting logic and are safe to leave in place — they let the importers update their own rows idempotently and give the dashboard extra context.
| Field | Added by | What it is |
|-------|----------|------------|
| `source` | both importers | `EntraAppReg` or `MessageCenter` — marks where the row came from, and is used to match the row on re-import. |
| `appId` | Entra importer | The app's Application (client) ID. Shown in the row detail; identifies which app the credential belongs to. |
| `entraKeyId` | Entra importer | The credential's key id. On a re-run, the matching row's `expireDate` is refreshed instead of a duplicate being added. |
| `noCredentials` | Entra importer | `true` for app registrations with no secret and no certificate; these are shown in the report's **No credentials** tab and never alert. |
| `messageId` | Message Center importer | The advisory id (e.g. `MC100001`). Used the same way to update the row idempotently, and shown in the row detail. |
| `severity` | Message Center importer | The advisory severity (`normal` / `high` / `critical`), shown as a coloured badge in the dashboard. |
| `messageLink` | Message Center importer | Deep link to the message in the Microsoft 365 admin center, shown as a clickable "Open in admin center" link in the dashboard. |

---

### Why a state file
`Files\state\sent-state.json` records which windows have already alerted, keyed by `id_expireDate_trigger`. This gives two things a plain date-match cannot:
- **Each window fires exactly once**, even when the script runs every day.
- **A missed run is caught up** on the next run. If the server was down on the exact trigger day, the window is still open, so the alert still goes out.
Renewing a certificate changes its `expireDate`, which changes the key prefix, retires the old keys, and re-arms all three windows automatically.
Two extra cases are handled: the **expiry day** itself, and a **recurring reminder** once an object has already expired.
### The completed archive file
Every time the HTML report runs, it copies each object whose `status` is **Completed** into `Files\config\MonitorObjectComplete.json`. This is a **copy, not a move** — the objects also stay in `monitorobjects.json`. The report's **Completed** tab is built **only** from this file.
Each copied object gets an extra `copiedDate` field set to the day it was first copied over. That date is **preserved on later runs** (matched on `entraKeyId`, then `messageId`, then `appId`, otherwise `name`+`servername`+`expireDate`), so it reflects when the object was completed, not when the report last ran. The date is shown next to the **Completed** badge in the row detail. The file always mirrors the objects currently marked Completed: set an object back to `Active` and it drops out of the archive on the next run. Change the location with the report's `-CompleteJsonPath` parameter.

---

## Entra ID app registration importer (plugin)
| Script | Job |
|--------|-----|
| `Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1` | Reads app registration credentials (client secrets **and** certificates) from Entra ID via Microsoft Graph and merges their expiry dates into `Files\db\monitorobjects.json` |
App registration secrets and certificates expire like everything else, but adding each one to `monitorobjects.json` by hand is tedious. This plugin pulls them straight from the tenant: every `passwordCredential` (client secret) and `keyCredential` (certificate) on every app registration becomes one monitored object.

**Every app registration is included — no filtering.** Apps that have no secret and no certificate are still listed (keyed by appId, shown in the report's **No credentials** tab with no expiry, and they never alert), so you can see which apps have no credentials at all. `entraKeyId` identifies exactly which secret or certificate is expiring on the apps that do have credentials.

Fields Entra provides map directly:
- `name`        ← app display name + credential display name
- `expireDate`  ← the credential `endDateTime` (`yyyy-MM-dd`)
- `servername`  ← the app's Application (client) ID
- `appId`       ← the app's Application (client) ID (shown in the row detail)
- `environment` ← `Entra - <tenant name> - <tenant id>`

**The plugin has its own configuration file, `Settings\plugin\entra\config\entra-app-defaults.json`, and copies its values into every row it writes to `monitorobjects.json`.** So you set the triggers, mail addresses, status and notification switches once in that file, and every imported credential inherits them. Everything Entra cannot supply (`template`, `status`, `description`, the three triggers, `mail`, `teams`) comes from there. The tokens `{{name}}`, `{{expireDate}}`, `{{servername}}` and `{{environment}}` are substituted per object, so defaults live in one JSON file instead of in the code. New rows get `status: "Backlog"` by default.
The plugin has its own version file, `Settings\plugin\entra\config\version.json` (`Entraversion` + a short `Changes` note), printed at the top of each run. On a new version, bump `Entraversion` and set `Changes` to a short line describing what changed.
**It never overwrites your data.** Before writing it takes a timestamped backup of `monitorobjects.json` into `Files\backup\psToDo\`. Existing/manual objects are left untouched; objects it imported before (matched on `entraKeyId`) get only their `expireDate` refreshed; brand-new credentials are appended with a fresh `id`. Imported objects carry extra fields (`source`, `appId`, `entraKeyId`), so re-runs are idempotent. The other scripts ignore unknown fields, so this stays compatible.
### Graph permission
This reads app registrations, so the app needs the **application permission `Application.Read.All`** with admin consent — in addition to the `Mail.Send` the main script uses. For the `Entra - <name> - <id>` environment tag it also reads the organization, which needs **`Organization.Read.All`** (or `Directory.Read.All`); without it the tag falls back to the tenant id. Authentication reuses the existing certificate flow (`Settings\Config\MsGraphSettings.json` + `Connect-CalenderReminderGraph`).

A **delegated** variant, `Settings\plugin\Import-EntraAppRegistrations-Delegated-v1.3.ps1`, does the same job but signs in as a **user** (interactive) instead of an app registration + certificate — no cert or `MsGraphSettings.json` needed. Use `-UseDeviceCode` on a headless host.
### Run it
Always WhatIf-run first.
```powershell
# Lab test — built-in sample data, no tenant needed:
.\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1 -UseMockData -WhatIf
.\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1 -UseMockData
# Live against the tenant:
.\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1 -WhatIf
.\Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1
```

| Switch | Effect |
|--------|--------|
| `-UseMockData` | Skip Graph and use built-in sample credentials — test backup/merge with no tenant. |
| `-NoDateRefresh` | Do not update `expireDate` on already-imported objects. |
| `-WhatIf` | Show what would change without writing (nothing is backed up or saved). |
---

## Microsoft 365 Message Center importer (plugin)
| Script | Job |
|--------|-----|
| `Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1` | Reads Microsoft 365 Message Center advisories via Microsoft Graph and merges the ones that carry a deadline into `Files\db\monitorobjects.json` |
Microsoft 365 announces upcoming changes, retirements and required actions in the Message Center. Some of those advisories come with a hard deadline. This plugin pulls them from the tenant so they land in the same watch list as your certificates and secrets.
It reads every service announcement message and keeps **only the ones that have an `actionRequiredByDateTime`** — a real deadline. That date becomes the object's `expireDate`. No service or severity filter is applied; every advisory with a deadline is imported.
Fields the Message Center provides map directly:
- `name`        ← message id + title (e.g. `MC100001 - Retirement: Legacy connector is being removed`)
- `expireDate`  ← the advisory `actionRequiredByDateTime` (`yyyy-MM-dd`)
- `servername`  ← the affected services
- `messageId`   ← the advisory id (e.g. `MC100001`), shown in the row detail
- `severity`    ← the advisory severity (`normal` / `high` / `critical`) — shown as a coloured badge in the HTML report
- `messageLink` ← a deep link to the message in the Microsoft 365 admin center, built from the message id (Graph has no link field), rendered as a clickable "Open in admin center" link in the report
Note: the Message Center **release status** (Scheduled / Rolling out / Launched) and the **High / Medium / Low relevance** shown in the admin center are not exposed by Microsoft Graph, so they cannot be imported. `severity` is the closest signal Graph provides.
**The plugin has its own configuration file, `Settings\plugin\messagecenter\config\messagecenter-defaults.json`, and copies its values into every row it writes to `monitorobjects.json`.** So you set the triggers, mail addresses, status and notification switches once in that file, and every imported advisory inherits them. Everything the Message Center cannot supply (`template`, `environment`, `status`, `description`, the three triggers, `mail`, `teams`) comes from there. The tokens `{{name}}`, `{{expireDate}}`, `{{servername}}`, `{{environment}}`, `{{messageId}}`, `{{category}}` and `{{severity}}` are substituted per object. Fill in your own `mailSender`, `mailRecipients` (and `teamWebhookUrl` if you want Teams) once in that file — those are the values Graph does not give you. New rows get `status: "Backlog"` by default. The config file is used only at import time, never when alerts are sent.
The plugin has its own version file, `Settings\plugin\messagecenter\config\version.json` (`MessageCenterversion` + a short `Changes` note), printed at the top of each run. On a new version, bump `MessageCenterversion` and set `Changes` to a short line describing what changed.
**It never overwrites your data.** Before writing it takes a timestamped backup of `monitorobjects.json` into `Files\backup\psToDo\`. Existing/manual objects are left untouched; advisories imported before (matched on `messageId`) get only their `expireDate` refreshed; brand-new advisories are appended with a fresh `id`. Imported objects carry the extra fields `source`, `messageId`, `severity` and `messageLink`, so re-runs are idempotent.
### Graph permission
This reads the Message Center, so the app needs the **application permission `ServiceMessage.Read.All`** with admin consent — in addition to the `Mail.Send` the main script uses. Add it to the same app registration in Entra → API permissions → Grant admin consent. Authentication reuses the existing certificate flow (`Settings\Config\MsGraphSettings.json` + `Connect-CalenderReminderGraph`).

A **delegated** variant, `Settings\plugin\Import-M365MessageCenter-Delegated-v1.3.ps1`, does the same job but signs in as a **user** (interactive) instead of an app registration + certificate.

### Run it
Always WhatIf-run first.
```powershell
# Lab test — built-in sample advisories, no tenant needed:
.\Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1 -UseMockData -WhatIf
.\Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1 -UseMockData
# Live against the tenant:
.\Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1 -WhatIf
.\Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1
```

| Switch | Effect |
|--------|--------|
| `-UseMockData` | Skip Graph and use built-in sample advisories — test backup/merge with no tenant. |
| `-NoDateRefresh` | Do not update `expireDate` on already-imported objects. |
| `-WhatIf` | Show what would change without writing (nothing is backed up or saved). |

---

## Repository layout
```
psToDo-v1.3.ps1                         Evaluate and alert
psToDo-HTML-Report-v1.3.ps1             Build the HTML dashboard
Setup-SenderMailbox-and-AccessPolicy.ps1   Create the alert sender mailbox + access policy (optional helper)
Create a self-signed cert to app-reg.ps1   Create the Graph client certificate (optional helper)
Settings\                          Functions to script
 Functions\
     psToDo\   
       - Connect-CalenderReminderGraph
       - Format-AlertAdaptiveCard
       - Format-AlertMailBody
       - Get-AlertPresentation
       - Get-SentState
       - Initialize-RequiredModules
       - Save-SentState
       - Send-AlertMail
       - Send-AlertNotification
       - Send-AlertTeams
     psToDo-HtmlReport\
       - Get-Urgency
       - Test-NotifyFlag
Settings\
  Config\
    - MsGraphSettings.json           Tenant, app and certificate (Mail.Send + Application.Read.All + ServiceMessage.Read.All + Organization.Read.All)
    - version.json                   Tool version + change note + History changelog
  plugin\
    - Import-EntraAppRegistrations-v1.3.ps1            Import Entra app-reg secret & cert expiry (app-registration auth)
    - Import-M365MessageCenter-v1.1.3.ps1               Import Message Center advisories (app-registration auth)
    - Import-EntraAppRegistrations-Delegated-v1.3.ps1 Same, but interactive user sign-in
    - Import-M365MessageCenter-Delegated-v1.3.ps1     Same, but interactive user sign-in
    entra\config\
      - entra-app-defaults.json          Default field values for Entra-imported objects
      - version.json                     Entra plugin version + change note + History changelog
    messagecenter\config\
      - messagecenter-defaults.json      Default field values for Message Center-imported objects
      - version.json                     Message Center plugin version + change note + History changelog
  
Files\
  db\monitorobjects.json           The objects being watched
  config\MonitorObjectComplete.json  Copy of every Completed object + copy date (auto-managed by the report)
  state\sent-state.json            What has already been alerted (auto-managed)
  report\index.html                Generated dashboard
  backup\                          Timestamped backups
Logs\                              Per-run transcripts
```

---
## Roadmap
```
Plugin folder : -->
[x] Added : Import-EntraAppRegistrations — sync app registration secret & certificate expiry from Entra ID
[x] Added : Import-M365MessageCenter — sync Message Center advisories that carry a deadline
[x] Added : Delegated (user sign-in) importers for both plugins
[x] Added : Report tabs — Monitored / Completed / No channel / No credentials / Not monitored
[x] Added : Completed archive (Files\config\MonitorObjectComplete.json) with per-object copy date
```
