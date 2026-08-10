<#
System requirements
    PSVersion  7.3.1 (Core) or later
    PSEdition  Core

psToDo plugin : Import-M365MessageCenter
    Author  : Fardin Barashi
    Title   : psToDo - Microsoft 365 Message Center importer
    Purpose : Read Microsoft 365 Message Center advisories from the tenant via
              Microsoft Graph and merge the ones that carry a deadline into
              Files\db\monitorobjects.json.

Behaviour
    1. Reads every service announcement message (serviceAnnouncement/messages)
       and keeps only those that have an actionRequiredByDateTime - i.e. a real
       deadline. That date becomes the object's expireDate. No service or
       severity filter is applied.
    2. Fields the Message Center does NOT provide (template, environment,
       triggers, mail, teams, ...) are taken from
       Settings\plugin\messagecenter\config\messagecenter-defaults.json. The tokens {{name}},
       {{expireDate}}, {{servername}}, {{environment}}, {{messageId}},
       {{category}} and {{severity}} are replaced per object.
    3. BEFORE writing anything it takes a timestamped backup of
       monitorobjects.json into Files\backup\psToDo\.
    4. It MERGES rather than overwrites:
         - existing manual objects are never touched
         - objects previously imported from the Message Center (matched on
           messageId) get their expireDate refreshed (unless -NoDateRefresh)
         - brand-new advisories are appended with a fresh numeric id
       Imported objects carry two extra fields, "source" and "messageId",
       so re-runs are idempotent. The existing psToDo scripts ignore unknown
       fields, so this is safe.

Graph permissions
    Application permission : ServiceMessage.Read.All  (grant admin consent)
    Certificate auth is reused from the rest of psToDo (MsGraphSettings.json +
    Connect-CalenderReminderGraph). Add ServiceMessage.Read.All to the same app
    registration (or a dedicated one) before running.

Switches
    -UseMockData   Skip Graph completely and use built-in sample advisories, so
                   you can test the backup/merge logic without a tenant.
    -NoDateRefresh Do not update expireDate on already-imported objects.
    -WhatIf        Show what would change without writing (SupportsShouldProcess).

Examples
    .\Import-M365MessageCenter-v1.1.ps1 -UseMockData -WhatIf
    .\Import-M365MessageCenter-v1.1.ps1 -UseMockData
    .\Import-M365MessageCenter-v1.1.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $UseMockData,
    [switch] $NoDateRefresh
)

$ErrorActionPreference = 'Stop'

#------------------------------- Paths -------------------------------

$pluginRoot = $PSScriptRoot
$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$configFolder          = Join-Path (Join-Path $pluginRoot 'messagecenter') 'config'
$monitoringObjectsPath = Join-Path $repoRoot 'Files\db\monitorobjects.json'
$graphSettingsPath     = Join-Path $repoRoot 'Settings\Config\MsGraphSettings.json'
$defaultsPath          = Join-Path $configFolder 'messagecenter-defaults.json'
$versionPath           = Join-Path $configFolder 'version.json'
$backupFolder          = Join-Path $repoRoot 'Files\backup\psToDo'
$functionFolder        = Join-Path $repoRoot 'Settings\Functions\psToDo'

$expireDateFormat = 'yyyy-MM-dd'

#------------------------------- Helpers -----------------------------

# Replace {{token}} placeholders in any string using a lookup table.
function Expand-Tokens {
    param(
        [string] $Text,
        [hashtable] $Tokens
    )
    if ($null -eq $Text) { return $Text }
    foreach ($key in $Tokens.Keys) {
        $Text = $Text -replace [regex]::Escape("{{$key}}"), [string]$Tokens[$key]
    }
    return $Text
}

# Build one ordered monitored object from the defaults template + one advisory.
function New-MonitorObjectFromMessage {
    param(
        [Parameter(Mandatory)] $Defaults,
        [Parameter(Mandatory)] $Message,   # PSCustomObject: Name, ExpireDate, ServerName, MessageId, Category, Severity
        [Parameter(Mandatory)] [int] $Id
    )

    $expire = ([datetime]$Message.ExpireDate).ToString($expireDateFormat)

    $tokens = @{
        name        = $Message.Name
        expireDate  = $expire
        servername  = $Message.ServerName
        environment = $Defaults.environment
        messageId   = $Message.MessageId
        category    = $Message.Category
        severity    = $Message.Severity
    }

    $mail = [ordered]@{
        mailSender     = $Defaults.mail.mailSender
        mailSubject    = Expand-Tokens $Defaults.mail.mailSubject $tokens
        mailBody       = Expand-Tokens $Defaults.mail.mailBody    $tokens
        mailRecipients = @($Defaults.mail.mailRecipients)
    }

    $teams = [ordered]@{
        teamSubject    = Expand-Tokens $Defaults.teams.teamSubject $tokens
        teamBody       = Expand-Tokens $Defaults.teams.teamBody    $tokens
        teamWebhookUrl = $Defaults.teams.teamWebhookUrl
    }

    return [ordered]@{
        id                  = [string]$Id
        name                = $Message.Name
        expireDate          = $expire
        template            = $Defaults.template
        servername          = $Message.ServerName
        environment         = $Defaults.environment
        status              = $Defaults.status
        description         = Expand-Tokens $Defaults.description $tokens
        '1dateTrigger'      = $Defaults.'1dateTrigger'
        '2dateTrigger'      = $Defaults.'2dateTrigger'
        '3dateTrigger'      = $Defaults.'3dateTrigger'
        notifyMethodbyMail  = $Defaults.notifyMethodbyMail
        notifyMethodbyTeams = $Defaults.notifyMethodbyTeams
        mail                = $mail
        teams               = $teams
        source              = 'MessageCenter'
        messageId           = $Message.MessageId
        severity            = $Message.Severity
        messageLink         = "https://admin.microsoft.com/#/MessageCenter/:/messages/$($Message.MessageId)"
    }
}

# Flatten service announcement messages into the flat list we monitor.
# Only messages that carry an actionRequiredByDateTime (a real deadline) are kept.
function Get-MessageListFromServiceAnnouncement {
    param([Parameter(Mandatory)] $Messages)

    $list = [System.Collections.Generic.List[object]]::new()

    foreach ($msg in $Messages) {
        if ($null -eq $msg.ActionRequiredByDateTime) { continue }

        $services = if ($msg.Services -and @($msg.Services).Count -gt 0) { (@($msg.Services) -join ', ') } else { 'Microsoft 365' }

        $list.Add([pscustomobject]@{
            Name       = "$($msg.Id) - $($msg.Title)"
            ExpireDate = $msg.ActionRequiredByDateTime
            ServerName = $services
            MessageId  = [string]$msg.Id
            Category   = [string]$msg.Category
            Severity   = [string]$msg.Severity
        })
    }

    return $list
}

# Built-in sample advisories so the merge/backup logic can be tested with no tenant.
function Get-MockMessages {
    [pscustomobject]@{
        Id = 'MC100001'; Title = 'Retirement: Legacy connector is being removed'
        Category = 'planForChange'; Severity = 'high'
        Services = @('Exchange Online'); ActionRequiredByDateTime = (Get-Date).AddDays(40)
    }
    [pscustomobject]@{
        Id = 'MC100002'; Title = 'Action required: update Teams client policy'
        Category = 'planForChange'; Severity = 'normal'
        Services = @('Microsoft Teams'); ActionRequiredByDateTime = (Get-Date).AddDays(12)
    }
    [pscustomobject]@{
        Id = 'MC100003'; Title = 'Informational: new admin report (no deadline)'
        Category = 'stayInformed'; Severity = 'normal'
        Services = @('Microsoft 365 suite'); ActionRequiredByDateTime = $null
    }
}

#------------------------------- Load defaults & existing data -------------------------------

Write-Host 'psToDo :: Import-M365MessageCenter' -ForegroundColor Cyan

if (Test-Path $versionPath) {
    $version = Get-Content -Raw -Encoding UTF8 $versionPath | ConvertFrom-Json
    Write-Host "- Version : $($version.MessageCenterversion)" -ForegroundColor DarkGray
    if ($version.Changes) { Write-Host "- Changes : $($version.Changes)" -ForegroundColor DarkGray }
}

if (-not (Test-Path $defaultsPath)) { throw "Defaults template not found: $defaultsPath" }
$defaults = Get-Content -Raw -Encoding UTF8 $defaultsPath | ConvertFrom-Json

if (Test-Path $monitoringObjectsPath) {
    $existing = @(Get-Content -Raw -Encoding UTF8 $monitoringObjectsPath | ConvertFrom-Json)
} else {
    Write-Warning "monitorobjects.json not found at $monitoringObjectsPath - starting from an empty list."
    $existing = @()
}
Write-Host "- Existing objects in file : $($existing.Count)" -ForegroundColor DarkGray

#------------------------------- Fetch messages -------------------------------

if ($UseMockData) {
    Write-Host '- Using MOCK data (no Graph call).' -ForegroundColor Yellow
    $messages = Get-MockMessages
} else {
    $functionFiles = Get-ChildItem -Path $functionFolder -Filter '*.ps1' -File
    foreach ($file in $functionFiles) { . $file.FullName }

    Initialize-RequiredModules -Modules @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Devices.ServiceAnnouncement')

    if (-not (Test-Path $graphSettingsPath)) { throw "Cannot find Graph settings file: $graphSettingsPath" }
    $settings = Get-Content -Raw -Encoding UTF8 $graphSettingsPath | ConvertFrom-Json
    foreach ($k in 'TenantId', 'AppId', 'CertificateThumbprint') {
        if ([string]::IsNullOrWhiteSpace($settings.$k)) { throw "MsGraphSettings.json is missing $k" }
    }

    $certificate = Get-ChildItem "Cert:\LocalMachine\My\$($settings.CertificateThumbprint)" -ErrorAction SilentlyContinue
    if (-not $certificate) { throw "Certificate $($settings.CertificateThumbprint) not found in Cert:\LocalMachine\My" }

    Connect-CalenderReminderGraph -TenantId $settings.TenantId -AppId $settings.AppId -Certificate $certificate | Out-Null

    if ('ServiceMessage.Read.All' -notin (Get-MgContext).Scopes) {
        Write-Warning "Token has no ServiceMessage.Read.All scope. Reading the Message Center may fail. Current scopes: $((Get-MgContext).Scopes -join ', ')"
    }

    Write-Host '- Reading Message Center advisories from Microsoft 365...' -ForegroundColor DarkGray
    $messages = Get-MgServiceAnnouncementMessage -All
}

$advisories = Get-MessageListFromServiceAnnouncement -Messages $messages
Write-Host "- Advisories with a deadline (actionRequiredBy) : $($advisories.Count)" -ForegroundColor DarkGray

#------------------------------- Merge -------------------------------

# Index existing Message Center objects by their messageId.
$existingByMessageId = @{}
foreach ($obj in $existing) {
    if ($obj.PSObject.Properties.Name -contains 'messageId' -and $obj.messageId) {
        $existingByMessageId[[string]$obj.messageId] = $obj
    }
}

# Next free numeric id (ids in the file are numeric strings).
$maxId = 0
foreach ($obj in $existing) {
    $n = 0
    if ([int]::TryParse([string]$obj.id, [ref]$n) -and $n -gt $maxId) { $maxId = $n }
}

$result = [System.Collections.Generic.List[object]]::new()
foreach ($obj in $existing) { $result.Add($obj) }   # keep every existing object, order preserved

$added = 0; $updated = 0
foreach ($adv in $advisories) {
    if ($existingByMessageId.ContainsKey($adv.MessageId)) {
        $target = $existingByMessageId[$adv.MessageId]
        $newExpire = ([datetime]$adv.ExpireDate).ToString($expireDateFormat)
        if (-not $NoDateRefresh -and [string]$target.expireDate -ne $newExpire) {
            $target.expireDate = $newExpire
            $updated++
        }
    } else {
        $maxId++
        $result.Add((New-MonitorObjectFromMessage -Defaults $defaults -Message $adv -Id $maxId))
        $added++
    }
}

Write-Host "- New objects to add      : $added"   -ForegroundColor Green
Write-Host "- Existing objects updated: $updated" -ForegroundColor Green
Write-Host "- Untouched objects       : $($existing.Count - $updated)" -ForegroundColor DarkGray

if ($added -eq 0 -and $updated -eq 0) {
    Write-Host 'Nothing to change. File left as is.' -ForegroundColor Yellow
    return
}

#------------------------------- Backup, then write -------------------------------

if ($PSCmdlet.ShouldProcess($monitoringObjectsPath, "Backup and write $($result.Count) monitored objects")) {

    if (Test-Path $monitoringObjectsPath) {
        if (-not (Test-Path $backupFolder)) { New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null }
        $backupfileDate = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
        $backupTarget   = Join-Path $backupFolder "monitorobjects-$backupfileDate.json"
        Copy-Item -Path $monitoringObjectsPath -Destination $backupTarget -Force
        Write-Host "- Backup written : $backupTarget" -ForegroundColor DarkGray
    }

    $json = $result | ConvertTo-Json -Depth 20 -AsArray
    Set-Content -Path $monitoringObjectsPath -Value $json -Encoding UTF8
    Write-Host "- Wrote $($result.Count) objects to $monitoringObjectsPath" -ForegroundColor Green
}
