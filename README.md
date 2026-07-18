# psToDo — Calender Reminder

![logo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodologo.png) 

A PowerShell solution that watches expiry dates in a JSON file and alerts a team by **mail** and **Microsoft Teams** before things lapse 

- upgrade-notifcations to teams
- certificates
- secrets
- tokens
- host keys
- license deadline
  
anything with a deadline. It also renders a self-contained **HTML status dashboard** for IIS.
Built and tested on **PowerShell 7.3.1 (Core)**.
The scripts create the folders they need on first run.
```

                 [ Daily System Run ]
                           |
             Does "Days Remaining" match a trigger?
                    /             \
               ( Yes )            ( No )
                 /                   \
       [ Check Alert Channels ]    [ Standby until tomorrow ]
         /             \
  [ Mail = true ]   [ Teams = true ]
       /                 \
(Send via Graph)    (Post to Webhook)
```


Always WhatIf-run first. 

```powershell
.\psToDo.ps1 -WhatIf  ( Nothing is sent and the state file is left untouched )
.\psToDo-HTML-Report.ps1 -WhatIf ( No html file is created )
```

Then for real:

```powershell
.\psToDo.ps1 
.\psToDo-HTML-Report.ps1
```

---


## psToDo-HTML-Report
| Script | Job |
|--------|-----|
| `psToDo-HTML-Report.ps1` | Reads objects in db\monitorobjects.json, Tand writes an HTML status page |

![Web dashboard](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/wwebdashboard.jpg)

## System requirements :
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
| `psToDo.ps1` | Reads the objects, db\monitorobjects.json, The objects being checked, decides what is due, sends the alerts based on objects configuration |

![PstoDo](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/pstodo.jpg)

## System requirements :
### Runtime
```
| Requirement | Detail |
|-------------|--------|
| PowerShell | **7.3.1 or later (Core)**. The scripts use PowerShell 7 syntax (`??`, ternary) that fails on Windows PowerShell 5.1. Run with `pwsh`, not `powershell`.
| OS | Windows. The certificate store paths (`Cert:\LocalMachine\My`) 
| Task Scheduler | For unattended use, schedule `psToDo.ps1` daily with Task Scheduler under
                   a service account that has Read on the certificate's private key.
                   Run it with `pwsh`, not Windows PowerShell 5.1 — the scripts use PowerShell 7 syntax.

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

| Module | Microsoft.Graph.Authentication.
| Appreg | Mail needs Graph and a certificate. Teams needs only a webhook URL — no app registration, no module, no certificate..


```
### App registration (for mail)
Mail is sent through Microsoft Graph using **certificate authentication** and an **application permission**. There is no signed-in user, so delegated permissions do not apply.

**1 - Create or open the app registration**
```
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

File layout ->
 Settings\Config\MsGraphSettings.json:
{
  "TenantId": "00000000-0000-0000-0000-000000000000",
  "AppId": "00000000-0000-0000-0000-000000000000",
  "CertificateThumbprint": "A1B2C3..."
}

---------------------------------------------------------------------------
Grant the Mail.Send permission

API permissions → Add a permission → Microsoft Graph → Application permissions →
search Mail.Send → add it → then Grant admin consent.

( If Type says *Delegated*, or Status is not granted, Graph returns `403` when sending. ) 
```

**2 - For best practice — Restrict who the app can send as**
```
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
```

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
1dateTrigger : 
![1dateTrigger Mail1](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail1.jpg) 
2dateTrigger : 
![2dateTrigger Mail2](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail2.jpg)
3dateTrigger : 
![3dateTrigger Mail3](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail3.jpg) 
below 0 :
![below 0 Mail4](https://raw.githubusercontent.com/fardinbarashi/psToDo/refs/heads/main/githubRepoContentDeleteIfYouWant/IMG/Mail4.jpg)


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
| `description` | string | The action the recipient should take. This is the "Action required" text in the mail and card — write real instructions here, not a placeholder. |
| `1dateTrigger` | number | First alert point, in **days before expiry**. | First, gentle heads-up |
| `2dateTrigger` | number | Second alert point, in days before expiry. |  warning |
| `3dateTrigger` | number | Third alert point, in days before expiry. | critical, last call |
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


### Why a state file

`Files\state\sent-state.json` records which windows have already alerted, keyed by `id_expireDate_trigger`. This gives two things a plain date-match cannot:
- **Each window fires exactly once**, even when the script runs every day.
- **A missed run is caught up** on the next run. If the server was down on the exact trigger day, the window is still open, so the alert still goes out.
Renewing a certificate changes its `expireDate`, which changes the key prefix, retires the old keys, and re-arms all three windows automatically.
Two extra cases are handled: the **expiry day** itself, and a **recurring reminder** once an object has already expired.
---

## Repository layout

```
psToDo.ps1                         Evaluate and alert
psToDo-HTML-Report.ps1             Build the HTML dashboard

Settings\                          Functions to script
 Functions\
     psToDo\   
      Get-Urgency
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
    - MsGraphSettings.json           Tenant, app and certificate for mail
    - ScriptSettings.json            Script-level settings
  
Files\
  db\monitorobjects.json           The objects being watched
  state\sent-state.json            What has already been alerted (auto-managed)
  report\index.html                Generated dashboard
  backup\                          Timestamped backups

Logs\                              Per-run transcripts
```





