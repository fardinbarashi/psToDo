<#
System requirements
    PSVersion  7.3.1 (Core) or later
    PSEdition  Core

psToDo plugin : Import-EntraAppRegistrations
    Author  : Fardin Barashi
    Title   : psToDo - Entra ID app registration importer
    Purpose : Read app registration credentials (client secrets + certificates)
              from Entra ID via Microsoft Graph and merge their expiry dates
              into Files\db\monitorobjects.json.

Behaviour
    1. Reads every app registration in the tenant and expands each
       passwordCredential (client secret) and keyCredential (certificate)
       into one monitored object.
    2. Fields Entra does NOT provide (template, environment, description,
       triggers, mail, teams, ...) are taken from
       Settings\plugin\entra\config\entra-app-defaults.json. The tokens {{name}},
       {{expireDate}}, {{servername}} and {{environment}} are replaced per
       object.
    3. BEFORE writing anything it takes a timestamped backup of
       monitorobjects.json into Files\backup\psToDo\.
    4. It MERGES rather than overwrites:
         - existing manual objects are never touched
         - objects previously imported from Entra (matched on entraKeyId) get
           their expireDate refreshed (unless -NoDateRefresh)
         - brand-new credentials are appended with a fresh numeric id
       Imported objects carry two extra fields, "source" and "entraKeyId",
       so re-runs are idempotent. The existing psToDo scripts ignore unknown
       fields, so this is safe.

Graph permissions
    Application permission : Application.Read.All  (grant admin consent)
    Certificate auth is reused from the rest of psToDo (MsGraphSettings.json +
    Connect-CalenderReminderGraph). Note: this is a different scope than the
    Mail.Send used by the main script, so add Application.Read.All to the same
    app registration (or a dedicated one) before running.

Switches
    -UseMockData   Skip Graph completely and use built-in sample credentials.
                   Lets you test the backup/merge logic in a lab with no tenant.
    -NoDateRefresh Do not update expireDate on already-imported objects.
    -WhatIf        Show what would change without writing (SupportsShouldProcess).

Examples
    # Lab test, no tenant needed:
    .\Import-EntraAppRegistrations-v1.1.ps1 -UseMockData -WhatIf
    .\Import-EntraAppRegistrations-v1.1.ps1 -UseMockData

    # Live against the tenant:
    .\Import-EntraAppRegistrations-v1.1.ps1
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

$configFolder          = Join-Path (Join-Path $pluginRoot 'entra') 'config'
$monitoringObjectsPath = Join-Path $repoRoot 'Files\db\monitorobjects.json'
$graphSettingsPath     = Join-Path $repoRoot 'Settings\Config\MsGraphSettings.json'
$defaultsPath          = Join-Path $configFolder 'entra-app-defaults.json'
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

# Build one ordered monitored object from the defaults template + one Entra credential.
function New-MonitorObjectFromCredential {
    param(
        [Parameter(Mandatory)] $Defaults,
        [Parameter(Mandatory)] $Credential,   # PSCustomObject: Name, ExpireDate, ServerName, KeyId
        [Parameter(Mandatory)] [int] $Id
    )

    $expire = ([datetime]$Credential.ExpireDate).ToString($expireDateFormat)

    $tokens = @{
        name       = $Credential.Name
        expireDate = $expire
        servername = $Credential.ServerName
        environment = $Defaults.environment
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
        name                = $Credential.Name
        expireDate          = $expire
        template            = $Defaults.template
        servername          = $Credential.ServerName
        environment         = $Defaults.environment
        status              = $Defaults.status
        description         = $Defaults.description
        '1dateTrigger'      = $Defaults.'1dateTrigger'
        '2dateTrigger'      = $Defaults.'2dateTrigger'
        '3dateTrigger'      = $Defaults.'3dateTrigger'
        notifyMethodbyMail  = $Defaults.notifyMethodbyMail
        notifyMethodbyTeams = $Defaults.notifyMethodbyTeams
        mail                = $mail
        teams               = $teams
        source              = 'EntraAppReg'
        entraKeyId          = $Credential.KeyId
    }
}

# Flatten Entra applications into a flat list of credentials to monitor.
function Get-CredentialListFromApps {
    param([Parameter(Mandatory)] $Apps)

    $list = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $Apps) {
        $appName = $app.DisplayName
        $appId   = $app.AppId

        foreach ($secret in @($app.PasswordCredentials)) {
            if ($null -eq $secret.EndDateTime) { continue }
            $label = if ([string]::IsNullOrWhiteSpace($secret.DisplayName)) { 'secret' } else { $secret.DisplayName }
            $list.Add([pscustomobject]@{
                Name       = "$appName - $label (secret)"
                ExpireDate = $secret.EndDateTime
                ServerName = $appId
                KeyId      = [string]$secret.KeyId
            })
        }

        foreach ($cert in @($app.KeyCredentials)) {
            if ($null -eq $cert.EndDateTime) { continue }
            $label = if ([string]::IsNullOrWhiteSpace($cert.DisplayName)) { 'certificate' } else { $cert.DisplayName }
            $list.Add([pscustomobject]@{
                Name       = "$appName - $label (certificate)"
                ExpireDate = $cert.EndDateTime
                ServerName = $appId
                KeyId      = [string]$cert.KeyId
            })
        }
    }

    return $list
}

# Built-in sample data so the merge/backup logic can be tested without a tenant.
function Get-MockApps {
    [pscustomobject]@{
        DisplayName = 'psToDo-Graph-Connector'
        AppId       = '11111111-1111-1111-1111-111111111111'
        PasswordCredentials = @(
            [pscustomobject]@{ KeyId = 'aaaaaaaa-0000-0000-0000-000000000001'; DisplayName = 'rotation-2026'; EndDateTime = (Get-Date).AddDays(45) }
        )
        KeyCredentials = @(
            [pscustomobject]@{ KeyId = 'aaaaaaaa-0000-0000-0000-000000000002'; DisplayName = 'signing-cert'; EndDateTime = (Get-Date).AddDays(120) }
        )
    }
    [pscustomobject]@{
        DisplayName = 'psToDo-Automation-App'
        AppId       = '22222222-2222-2222-2222-222222222222'
        PasswordCredentials = @(
            [pscustomobject]@{ KeyId = 'bbbbbbbb-0000-0000-0000-000000000001'; DisplayName = ''; EndDateTime = (Get-Date).AddDays(10) }
        )
        KeyCredentials = @()
    }
}

#------------------------------- Load defaults & existing data -------------------------------

Write-Host 'psToDo :: Import-EntraAppRegistrations' -ForegroundColor Cyan

if (Test-Path $versionPath) {
    $version = Get-Content -Raw -Encoding UTF8 $versionPath | ConvertFrom-Json
    Write-Host "- Version : $($version.Entraversion)" -ForegroundColor DarkGray
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

#------------------------------- Fetch credentials -------------------------------

if ($UseMockData) {
    Write-Host '- Using MOCK data (no Graph call).' -ForegroundColor Yellow
    $apps = Get-MockApps
} else {
    $functionFiles = Get-ChildItem -Path $functionFolder -Filter '*.ps1' -File
    foreach ($file in $functionFiles) { . $file.FullName }

    Initialize-RequiredModules -Modules @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')

    if (-not (Test-Path $graphSettingsPath)) { throw "Cannot find Graph settings file: $graphSettingsPath" }
    $settings = Get-Content -Raw -Encoding UTF8 $graphSettingsPath | ConvertFrom-Json
    foreach ($k in 'TenantId', 'AppId', 'CertificateThumbprint') {
        if ([string]::IsNullOrWhiteSpace($settings.$k)) { throw "MsGraphSettings.json is missing $k" }
    }

    $certificate = Get-ChildItem "Cert:\LocalMachine\My\$($settings.CertificateThumbprint)" -ErrorAction SilentlyContinue
    if (-not $certificate) { throw "Certificate $($settings.CertificateThumbprint) not found in Cert:\LocalMachine\My" }

    Connect-CalenderReminderGraph -TenantId $settings.TenantId -AppId $settings.AppId -Certificate $certificate | Out-Null

    if ('Application.Read.All' -notin (Get-MgContext).Scopes) {
        Write-Warning "Token has no Application.Read.All scope. Reading applications may fail. Current scopes: $((Get-MgContext).Scopes -join ', ')"
    }

    Write-Host '- Reading app registrations from Entra ID...' -ForegroundColor DarkGray
    $apps = Get-MgApplication -All -Property 'id,appId,displayName,passwordCredentials,keyCredentials'
}

$credentials = Get-CredentialListFromApps -Apps $apps
Write-Host "- Credentials with an expiry date found : $($credentials.Count)" -ForegroundColor DarkGray

#------------------------------- Merge -------------------------------

# Index existing Entra-imported objects by their entraKeyId.
$existingByKeyId = @{}
foreach ($obj in $existing) {
    if ($obj.PSObject.Properties.Name -contains 'entraKeyId' -and $obj.entraKeyId) {
        $existingByKeyId[[string]$obj.entraKeyId] = $obj
    }
}

# Next free numeric id (ids in the file are numeric strings).
$maxId = 0
foreach ($obj in $existing) {
    $n = 0
    if ([int]::TryParse([string]$obj.id, [ref]$n) -and $n -gt $maxId) { $maxId = $n }
}

$result  = [System.Collections.Generic.List[object]]::new()
foreach ($obj in $existing) { $result.Add($obj) }   # keep every existing object, order preserved

$added = 0; $updated = 0
foreach ($cred in $credentials) {
    if ($existingByKeyId.ContainsKey($cred.KeyId)) {
        $target = $existingByKeyId[$cred.KeyId]
        $newExpire = ([datetime]$cred.ExpireDate).ToString($expireDateFormat)
        if (-not $NoDateRefresh -and [string]$target.expireDate -ne $newExpire) {
            $target.expireDate = $newExpire
            $updated++
        }
    } else {
        $maxId++
        $result.Add((New-MonitorObjectFromCredential -Defaults $defaults -Credential $cred -Id $maxId))
        $added++
    }
}

Write-Host "- New objects to add      : $added"     -ForegroundColor Green
Write-Host "- Existing objects updated: $updated"   -ForegroundColor Green
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
