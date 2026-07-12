<#
System requirements
PSVersion                      7.3.1
PSEdition                      Core

About Script :
Author : Fardin Barashi
Title : psToDo
Description : This script is designed to send calendar reminders to users based on specific criteria in the monitoring objects file.
Creates html file for future use to iis.
Alerts team or user based on the configuration in the monitoring objects file.
For more information, please visit the GitHub repository: https://github.com/fardinbarashi

Alerting rule:
    An object alerts once per trigger window, not once per trigger day.

    The window opens when daysLeft drops to or below a trigger, and the
    narrowest open window wins. With triggers 7/15/30:

        daysLeft 30..16 -> the 30-day window
        daysLeft 15..8  -> the 15-day window
        daysLeft 7..0   -> the 7-day window

    Files\state\sent-state.json remembers which windows have already been
    alerted, so each one fires exactly once even if the script runs daily.
    A missed run is caught up on the next run, which plain -eq matching
    could never do.

    Two extra cases: the expiry day itself, and a reminder every
    $expiredNotifyDays once the object has already expired.

    The state key is id_expireDate_trigger. Renewing a certificate changes
    expireDate, which retires the old keys and re-arms every window.

JSON key note:
    The trigger keys start with a digit, so PowerShell cannot reach them with
    plain dot notation - $object.1dateTrigger is a parse error, because 1d is
    read as a decimal literal. Quoted member access is required throughout:
    $object.'1dateTrigger', or $object.$key when $key holds the name.

Teams note:
    Teams goes through a Workflows webhook, not Graph. Posting a channel
    message with application permissions is a protected API - ChannelMessage.Send
    is not offered as an app permission without Microsoft's approval.
    The JSON needs teamWebhookUrl instead of teamId and teamChannelId.

Folder layout:
    psToDo.ps1
    CalenderReminderHtmlReport.ps1
    Settings\Config\MsGraphSettings.json
    Files\db\monitorobjects.json
    Files\state\sent-state.json
    Files\report\
    Logs\

Version : 3.0
Release day : 2026-07-10
Github Link  : https://github.com/fardinbarashi
News : sent-state.json. One alert per trigger window, missed runs caught up.

#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Wipe the state file before running. Every open window alerts again.
    [switch] $ResetState
)

#------------------------------- Settings -------------------------------

# Filename and Folderspath
 $scriptName   = $MyInvocation.MyCommand.Name # Scriptname
 $logFolder    = "$PSScriptRoot\Logs" # Log Path
 $reportFolder = "$PSScriptRoot\Files\report" # Report Path
 $stateFolder  = "$PSScriptRoot\Files\state" # State Path

# Monitoring objects, Configration and State file path
 $monitoringObjectsPath = "$PSScriptRoot\Files\db\monitorobjects.json"
 $graphSettingsPath     = "$PSScriptRoot\Settings\Config\MsGraphSettings.json"
 $statePath             = "$stateFolder\sent-state.json"
 $scriptSettingsPath = "$PSScriptRoot\Settings\Config\ScriptSettings.json"

# backup paths for monitorobjects.json, sent-state.json
  $backupMonitorObjectPath = "$PSScriptRoot\Files\backup\psToDo\"
  $backupSendStateJsonPath = "$PSScriptRoot\Files\backup\psToDo\"
  $backupMsGraphSettingsPath = "$PSScriptRoot\Files\backup\psToDo\"

# The three trigger keys, in the order they appear in the JSON
 $triggerKeys = @('1dateTrigger', '2dateTrigger', '3dateTrigger')

# Date format used inside monitorobjects.json
 $expireDateFormat = 'yyyy-MM-dd'
 $today            = (Get-Date).Date

# How often to notify about objects that have already expired
$expiredNotifyDays = 7

# Transcript. Dashes, not slashes: slashes become directory separators in the file name.
$logFileDate       = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
$tranScriptLogFile = "$logFolder\$scriptName - $logFileDate.txt"

Start-Transcript -Path $tranScriptLogFile -Force | Out-Null
Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
Write-Host '.. Starting TranScript'

# Error settings
$ErrorActionPreference = 'Continue'

#------------------------------- Functions List -------------------------------

Write-Host 'Checking required Functions...' -ForegroundColor Yellow

$functionFolder = "$PSScriptRoot\Settings\Functions\psToDo"
if (-not (Test-Path $functionFolder)) { throw "Function folder not found: $functionFolder"}
$functionFiles = Get-ChildItem -Path $functionFolder -Filter '*.ps1' -File
if (-not $functionFiles) { throw "No .ps1 files found in $functionFolder"}

foreach ($file in $functionFiles) 
{ 
 try {
        . $file.FullName
        Write-Host "- Loaded $($file.Name)" -ForegroundColor DarkGray
    }
catch { throw "Failed to load function file '$($file.Name)': $($_.Exception.Message)" }
}
Write-Host "All $($functionFiles.Count) function file(s) loaded." -ForegroundColor Green

Initialize-RequiredModules -Modules @('Microsoft.Graph.Authentication')

Write-host ""
#------------------------------- Section 1 -------------------------------
$Section = 'Section 1 : Read the monitorobjects.json file and the sent state'
try {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "Start $Section ... 0%" -ForegroundColor Yellow
    if (-not (Test-Path $monitoringObjectsPath)) { throw "Cannot find monitoring objects file: $monitoringObjectsPath"}
    try { 
         $monitoringObjects = Get-Content -Raw -Encoding UTF8 $monitoringObjectsPath | ConvertFrom-Json
         $scriptSettings = Get-Content -Raw -Encoding UTF8 $scriptSettingsPath | ConvertFrom-Json
         Write-Host "$scriptSettings.Version" -ForegroundColor Green
         Write-host ""
   
        }
    catch { throw "Failed to parse JSON in '$monitoringObjectsPath': $($_.Exception.Message)"}
    if (-not $monitoringObjects) { throw 'The monitoring objects file is empty or contains no objects.'}
    Write-Host "Loaded $(@($monitoringObjects).Count) object(s)."

    if ($ResetState -and (Test-Path $statePath)) {
        if ($PSCmdlet.ShouldProcess($statePath, 'Delete state file')) {
            Remove-Item $statePath -Force
            Write-Warning 'State file deleted. Every open trigger window will alert again.'
        }
    }

    $state = Get-SentState -Path $statePath

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
    Write-Host 'Stopping Transcript and Script!' -ForegroundColor Red
    Stop-Transcript
    exit 1
}


#------------------------------- Section 2 -------------------------------
$Section = 'Section 2 : Find objects inside a trigger window that has not alerted yet'
try {
      Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
      Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

      $alerts    = [System.Collections.Generic.List[object]]::new()
      $liveKeys  = [System.Collections.Generic.List[string]]::new()
      foreach ($object in $monitoringObjects) 
       {
         $label = "Object $($object.id) - $($object.name)"
        # --- Validate and parse expireDate ---
        if ([string]::IsNullOrWhiteSpace($object.expireDate)) {
         Write-Warning "--> $label is missing expireDate - skipping."
         continue
        }

        try {
             $expireDate = [datetime]::ParseExact(
             $object.expireDate,
             $expireDateFormat,
             [cultureinfo]::InvariantCulture
            ).Date
        }
        catch {
            Write-Warning "--> $label has an invalid expireDate: '$($object.expireDate)' (expected $expireDateFormat) - skipping."
            continue
        }

        $daysLeft = ($expireDate - $today).Days

        # Prefix for every state key belonging to this object at this expiry date.
        # Renewing the changes the prefix, retiring the old keys.
        $keyPrefix = "$($object.id)_$($object.expireDate)"
        $liveKeys.Add($keyPrefix)

        # --- Collect triggers. Quoted access: the keys start with a digit. ---
        $rawTriggers = foreach ($key in $triggerKeys) { $object.$key }

        [int[]] $triggers = $rawTriggers |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            ForEach-Object { [int]$_ } |
                            Sort-Object -Unique

        if (-not $triggers) {
            Write-Warning "--> $label has no valid date triggers - skipping."
            continue
        }

        # ascending order      
        $declared = @($rawTriggers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]$_ })
        if (($declared -join ',') -ne (($declared | Sort-Object) -join ',')) {
            Write-Warning "--> $label declares triggers out of order ($($declared -join ', ')). Sorted automatically." # order-independent, but a mismatch is flagging.
        }

        # --- The narrowest open window. Triggers are ascending, so the first
        $hit = $triggers | Where-Object { $daysLeft -le $_ -and $daysLeft -ge 0 } | Select-Object -First 1  #  match is the smallest trigger that still covers daysLeft. ---
        $expiredNotifyDay = ($daysLeft -lt 0) -and ($daysLeft % $expiredNotifyDays -eq 0)
        $expiryDay  = ($daysLeft -eq 0)

        # Expiry-day and expired reminders are time based, not window based
        $stateKey = if     ($expiryDay)       { "${keyPrefix}_expiryday" }
                    elseif ($daysLeft -lt 0)  { "${keyPrefix}_expired-$($today.ToString('yyyy-MM-dd'))" }
                    elseif ($null -ne $hit)   { "${keyPrefix}_$hit" }
                    else                      { $null }

        if ($null -eq $stateKey) { Write-Host "  $label - $daysLeft days left, no trigger window open." -ForegroundColor DarkGray
            continue }

        if (-not $expiryDay -and $daysLeft -lt 0 -and -not $expiredNotifyDay) { Write-Host "  $label - expired $([Math]::Abs($daysLeft)) days ago, not a reminder day." -ForegroundColor DarkGray
            continue}

        if ($state.ContainsKey($stateKey)) {
            $when = try { ([datetime]$state[$stateKey]).ToString('yyyy-MM-dd HH:mm') } catch { 'earlier' }
            Write-Host "  $label - $daysLeft days left, already alerted ($stateKey) on $when." -ForegroundColor DarkGray
            continue
        }

        # Smallest trigger sits closest to expiry, so it is the most urgent
        $urgency = if     ($daysLeft -lt 0)            { 'expired'  }
                   elseif ($daysLeft -le $triggers[0]) { 'critical' }
                   elseif ($triggers.Count -ge 2 -and $daysLeft -le $triggers[1]) { 'warning' }
                   else                                { 'ok'       }

        $alerts.Add([pscustomobject]@{
            id             = "$($object.id)"
            name           = "$($object.name)"
            servername     = "$($object.servername)"
            template       = "$($object.template)"
            environment    = "$($object.environment)"
            action         = "$($object.description)"
            expireDate     = $expireDate
            daysLeft       = $daysLeft
            trigger        = $hit
            allTriggers    = @($triggers)
            urgency        = $urgency
            stateKey       = $stateKey

            mailOn         = [bool]$object.notifyMethodbyMail
            mailSender     = "$($object.mail.mailSender)"
            mailSubject    = "$($object.mail.mailSubject)"
            mailBody       = "$($object.mail.mailBody)"
            mailRecipients = @($object.mail.mailRecipients)

            teamsOn        = [bool]$object.notifyMethodbyTeams
            teamSubject    = "$($object.teams.teamSubject)"
            teamBody       = "$($object.teams.teamBody)"
            teamWebhookUrl = "$($object.teams.teamWebhookUrl)"
        })

        $why = if     ($expiryDay)      { 'expiry day'        }
               elseif ($daysLeft -lt 0) { 'expired reminder'  }
               else                     { "$hit-day window"   }

        Write-Host "  $($urgency.ToUpper()): $label - $daysLeft days left ($why)." -ForegroundColor Red
    }

    Write-Host ''
    Write-Host "$($alerts.Count) object(s) need an alert today." -ForegroundColor Yellow
    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
    Write-Host 'Stopping Transcript and Script!' -ForegroundColor Red
    Stop-Transcript
    exit 1
}

#------------------------------- Section 3 -------------------------------

$Section = 'Section 3 : Connect to Microsoft Graph'

# Only mail needs Graph. Teams goes through a webhook.
$needsGraph = @($alerts | Where-Object mailOn).Count -gt 0

if (-not $needsGraph) {
    Write-Host "Skipping $Section - no mail to send today." -ForegroundColor DarkGray
    Write-Host ''
}
else {
    try {
        Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

        if (-not (Test-Path $graphSettingsPath)) { throw "Cannot find Graph settings file: $graphSettingsPath"}

        $settings = Get-Content -Raw -Encoding UTF8 $graphSettingsPath | ConvertFrom-Json
        foreach ($k in 'TenantId', 'AppId', 'CertificateThumbprint') { if ([string]::IsNullOrWhiteSpace($settings.$k)) { throw "MsGraphSettings.json is missing $k" } }

        $certificate = Get-ChildItem "Cert:\LocalMachine\My\$($settings.CertificateThumbprint)" -ErrorAction SilentlyContinue
        if (-not $certificate) { throw "Certificate $($settings.CertificateThumbprint) not found in Cert:\LocalMachine\My"}

        Connect-CalenderReminderGraph `
            -TenantId    $settings.TenantId `
            -AppId       $settings.AppId `
            -Certificate $certificate | Out-Null

        Write-Host "Start $Section ... 100%" -ForegroundColor Green
        Write-Host ''
    }
    catch {
        Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        Write-Host "ERROR on $Section" -ForegroundColor Red
        Write-Host 'ERROR:' $_.Exception.Message
        Write-Host 'Cannot send mail without a Graph connection. Stopping.' -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
}

#------------------------------- Section 4 -------------------------------

$Section = 'Section 4 : Send alerts on the channels each object asks for'

if ($alerts.Count) {
    try {
        Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

        $results = [System.Collections.Generic.List[object]]::new()
        $groups = $alerts | Group-Object trigger | Sort-Object { [int]($_.Name -as [int]) }
        foreach ($group in $groups) 
        {
            $heading = if ($group.Name) { "$($group.Name)-day window" } else { 'Expired / expiry day' }
            Write-Host "-- $heading ($($group.Count) object(s))" -ForegroundColor Cyan
            foreach ($alert in $group.Group) 
            {
                Write-Host "   $($alert.id) - $($alert.name) [$($alert.urgency)]" -ForegroundColor Cyan
                $r = Send-AlertNotification -Alert $alert
                $results.Add($r)
                if (-not $WhatIfPreference -and ($r.MailSent -or $r.TeamsSent)) { $state[$alert.stateKey] = (Get-Date).ToString('o') }# Record only what actually went out. A failed send stays unrecorded, so the next run tries again. -WhatIf never records.
            }
            Write-Host ''
        }

        $mailSent   = @($results | Where-Object MailSent).Count
        $teamsSent  = @($results | Where-Object TeamsSent).Count
        $skipped    = @($results | Where-Object Skipped).Count
        $mailTried  = @($alerts  | Where-Object mailOn).Count
        $teamsTried = @($alerts  | Where-Object teamsOn).Count

        Write-Host "Mail:  $mailSent of $mailTried sent"   -ForegroundColor Yellow
        Write-Host "Teams: $teamsSent of $teamsTried sent" -ForegroundColor Yellow

        if ($skipped) { Write-Warning "$skipped object(s) had no channel enabled and were not notified."}

        Write-Host "Start $Section ... 100%" -ForegroundColor Green
        Write-Host ''
    }
    catch 
    {
        Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        Write-Host "ERROR on $Section" -ForegroundColor Red
        Write-Host 'ERROR:' $_.Exception.Message
    }
    finally { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } }
}
else {
    Write-Host "Skipping $Section - nothing to send today." -ForegroundColor DarkGray
    Write-Host ''
}

#------------------------------- Section 5 -------------------------------

$Section = 'Section 5 : Save the sent state'
try {
     Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
     Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

    if ($WhatIfPreference) { Write-Host 'WhatIf: the state file was not written.' -ForegroundColor DarkGray }
    else { Save-SentState -State $state -Path $statePath -LiveKeyPrefixes $liveKeys }

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
}

#------------------------------- Section 6 -------------------------------

$Section = 'Section 6 : Create backup copies of monitorobjects.json and sent-state.json'
try {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

    # Create a backup of the monitorobjects.json and sent-state.json files with a timestamp in the filename
    $backupfileDate = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
    get-childitem -Path $monitoringObjectsPath | Copy-Item -Destination "$backupMonitorObjectPath\monitorobjects-$($backupfileDate).json" -Force -Verbose
    get-childitem -Path $statePath | Copy-Item -Destination "$backupSendStateJsonPath\sendstate-$($backupfileDate).json" -Force -Verbose
    get-childitem -Path $graphSettingsPath | Copy-Item -Destination "$backupMsGraphSettingsPath\MsGraphSettings-$($backupfileDate).json" -Force -Verbose

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
}


#------------------------------- End -------------------------------

Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
Write-Host 'Script finished.' -ForegroundColor Green
Stop-Transcript
