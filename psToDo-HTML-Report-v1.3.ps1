
<#
.DESCRIPTION
    SYSTEM REQUIREMENTS : PowerShell 5.1 or later.

    Reads monitorobjects.json and writes the HTML dashboard (index.html).
    Change $websitePath to write to a web server's document root.

    Urgency per object, from its own triggers (sorted ascending):
        daysLeft < 0             -> expired
        daysLeft <= datetrigger1 -> critical
        daysLeft <= datetrigger2 -> warning
        otherwise                -> ok

    Page template : Settings\Web\report-template.html
    Settings      : Settings\Config\ReportSettings.json
    Sent alerts   : Files\state\sent-state.json (written by psToDo-v1.3.ps1)

.EXAMPLE
    .\psToDo-HTML-Report-v1.3.ps1

.EXAMPLE
    .\psToDo-HTML-Report-v1.3.ps1 -OrganizationName 'CONTOSO' -LogoPath '.\Settings\Config\logo.png'

.NOTES
    Author : Fardin Barashi
    Title : CalendarReminderHtmlReport
    Version : 1.5
      Release day : 2026-06-22
      Github Link  : https://github.com/fardinbarashi

.NEWS
 
#>

#----------------------------------- Settings ------------------------------------------
[CmdletBinding()]
param(
    [string] $JsonPath   = '',
    [string] $CompleteJsonPath = '',
    [string] $ScriptSettingsPath   = '',
    [string] $DateFormat = 'yyyy-MM-dd',
    [string] $fileDate = (Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'),
    [string] $websitePath = '',
    [string] $backupWebsitePath = '',
    [string[]] $TriggerKeys = @('1dateTrigger', '2dateTrigger', '3dateTrigger'),
    [string] $StatePath = '',
    [string] $ReportSettingsPath = '',
    [string] $TemplatePath = '',
    [string] $OrganizationName = '',
    [string] $LogoPath = ''
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($JsonPath))           { $JsonPath           = "$scriptRoot\Files\db\monitorobjects.json" }
if ([string]::IsNullOrWhiteSpace($CompleteJsonPath))   { $CompleteJsonPath   = "$scriptRoot\Files\config\MonitorObjectComplete.json" }
if ([string]::IsNullOrWhiteSpace($ScriptSettingsPath)) { $ScriptSettingsPath = "$scriptRoot\Settings\Config\version.json" }
if ([string]::IsNullOrWhiteSpace($websitePath))        { $websitePath        = "$scriptRoot\Files\report\index.html" }
if ([string]::IsNullOrWhiteSpace($backupWebsitePath))  { $backupWebsitePath  = "$scriptRoot\Files\backup\psToDo-HTML-Report\index-$($fileDate).html" }
if ([string]::IsNullOrWhiteSpace($StatePath))          { $StatePath          = "$scriptRoot\Files\state\sent-state.json" }
if ([string]::IsNullOrWhiteSpace($ReportSettingsPath)) { $ReportSettingsPath = "$scriptRoot\Settings\Config\ReportSettings.json" }
if ([string]::IsNullOrWhiteSpace($TemplatePath))       { $TemplatePath       = "$scriptRoot\Settings\Web\report-template.html" }

Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue -WhatIf:$false

# Transcript
$ScriptName = $MyInvocation.MyCommand.Name
$LogFileDate = (Get-Date -Format 'yyyy-MM-dd_HH.mm.ss')
$TranScriptLogFile = "$scriptRoot\Logs\$ScriptName - $LogFileDate.Txt" 
$StartTranscript = Start-Transcript -Path $TranScriptLogFile -Force
Get-Date -Format "yyyy/MM/dd HH:mm:ss"
Write-Host ".. Starting TranScript"

# Error-Settings
$ErrorActionPreference = 'Continue'

#----------------------------------- Functionlist ------------------------------------------

#------------------------------- Functions List -------------------------------

Write-Host 'Checking required Functions...' -ForegroundColor Yellow

$functionFolder = "$scriptRoot\Settings\Functions\psToDo-HtmlReport"
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


#----------------------------------- Start Script ------------------------------------------
# Section 1 : Read monitorobjects.json
$Section = "Section 1 : Read monitorobjects.json"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
if (-not (Test-Path $JsonPath)) { throw "Cannot find the monitoring objects file: $JsonPath"}
try { 
      $monitoringObjects = Get-Content -Raw -Encoding UTF8 $JsonPath | ConvertFrom-Json 
      
         Write-host ""
    }
catch { throw "Failed to parse JSON in '$JsonPath': $($_.Exception.Message)"}
if (-not $monitoringObjects) { throw 'The monitoring objects file is empty or contains no objects.' }

# Copy Completed objects to MonitorObjectComplete.json
$completedObjectsRaw = @($monitoringObjects | Where-Object { "$($_.status)" -ieq 'Completed' })
$monitoredObjectsRaw = @($monitoringObjects | Where-Object { "$($_.status)" -ine 'Completed' })

function Get-CompleteKey {
    param($o)
    foreach ($k in @($o.entraKeyId, $o.messageId, $o.appId)) {
        if (-not [string]::IsNullOrWhiteSpace($k)) { return "$k" }
    }
    return ('{0}|{1}|{2}' -f $o.name, $o.servername, $o.expireDate)
}

# Keep the first copy date
$existingCopyDates = @{}
if (Test-Path $CompleteJsonPath) {
    try {
        foreach ($p in @((Get-Content -Raw -Encoding UTF8 $CompleteJsonPath | ConvertFrom-Json))) {
            if (-not [string]::IsNullOrWhiteSpace($p.copiedDate)) {
                $existingCopyDates[(Get-CompleteKey $p)] = "$($p.copiedDate)"
            }
        }
    } catch { Write-Warning "Could not read existing $CompleteJsonPath - copy dates will be reset. $($_.Exception.Message)" }
}

$copyStamp = (Get-Date -Format 'yyyy-MM-dd')
foreach ($o in $completedObjectsRaw) {
    $key  = Get-CompleteKey $o
    $date = if ($existingCopyDates.ContainsKey($key)) { $existingCopyDates[$key] } else { $copyStamp }
    $o | Add-Member -NotePropertyName copiedDate -NotePropertyValue $date -Force
}

$completeDir = Split-Path $CompleteJsonPath -Parent
if ($completeDir -and -not (Test-Path $completeDir)) { New-Item -ItemType Directory -Force -Path $completeDir | Out-Null }
ConvertTo-Json -InputObject @($completedObjectsRaw) -Depth 20 | Set-Content -Encoding UTF8 $CompleteJsonPath
Write-Host "- Copied $($completedObjectsRaw.Count) completed object(s) to $CompleteJsonPath" -ForegroundColor DarkGray

$completedObjects = if (Test-Path $CompleteJsonPath) {
    @((Get-Content -Raw -Encoding UTF8 $CompleteJsonPath | ConvertFrom-Json))
} else { @() }

Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------
# Section 2 : Build HTML data
$Section = "Section 2 : Build HTML data"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
$today         = (Get-Date).Date

# Sent state from psToDo-v1.3.ps1
$sentState = @{}
if (Test-Path $StatePath) {
    try {
        $rawState = Get-Content -Raw -Encoding UTF8 $StatePath
        if (-not [string]::IsNullOrWhiteSpace($rawState)) {
            ($rawState | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sentState[$_.Name] = $_.Value }
        }
        Write-Host "- Sent state: $($sentState.Count) alert(s) recorded in $StatePath" -ForegroundColor DarkGray
    } catch { Write-Warning "Could not read $StatePath - Next alert / Last alerted assume nothing was sent. $($_.Exception.Message)" }
} else { Write-Host "- No sent state yet ($StatePath)." -ForegroundColor DarkGray }

$rows          = [System.Collections.Generic.List[object]]::new()
$completedRows = [System.Collections.Generic.List[object]]::new()
$invalid       = [System.Collections.Generic.List[object]]::new()
$noCreds       = [System.Collections.Generic.List[object]]::new()
$placeholder   = 0

# Row for an object without a usable expiry date
function New-InventoryRow {
    param($Object)
    [pscustomobject]@{
        id             = "$($Object.id)"
        name           = "$($Object.name)"
        owner          = "$($Object.owner)"
        servername     = "$($Object.servername)"
        template       = "$($Object.template)"
        environment    = "$($Object.environment)"
        action         = "$($Object.description)"
        expireDate     = '—'
        daysLeft       = $null
        trigger        = $null
        allTriggers    = @()
        maxTrigger     = $null
        windows        = @()
        nextAlertDate  = $null
        nextAlertLabel = ''
        nextAlertDue   = $false
        nextAlertChannel = ''
        lastAlerted    = $null
        lastAlertedLabel = ''
        urgency        = 'none'
        status         = $(if ([string]::IsNullOrWhiteSpace($Object.status)) { 'Backlog' } else { "$($Object.status)" })
        copiedDate     = "$($Object.copiedDate)"
        severity       = "$($Object.severity)"
        messageLink    = "$($Object.messageLink)"
        source         = "$($Object.source)"
        appId          = "$($Object.appId)"
        messageId      = "$($Object.messageId)"
        mailOn         = $false
        mailSender     = "$($Object.mail.mailSender)"
        mailSubject    = "$($Object.mail.mailSubject)"
        mailBody       = "$($Object.mail.mailBody)"
        mailRecipients = @($Object.mail.mailRecipients)
        teamsOn        = $false
        teamWebhook    = (Get-MaskedWebhook "$($Object.teams.teamWebhookUrl)")
        teamSubject    = "$($Object.teams.teamSubject)"
        teamBody       = "$($Object.teams.teamBody)"
    }
}

# Row for a Completed object
function New-CompletedRow {
    param($Object)

    if ([string]::IsNullOrWhiteSpace($Object.expireDate)) { return (New-InventoryRow $Object) }
    try {
        $expireDate = [datetime]::ParseExact($Object.expireDate, $DateFormat, [cultureinfo]::InvariantCulture).Date
    } catch { return (New-InventoryRow $Object) }

    $daysLeft    = ($expireDate - $today).Days
    $rawTriggers = foreach ($key in $TriggerKeys) { $Object.$key }
    [int[]] $triggers = $rawTriggers |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { [int]$_ } |
                        Sort-Object -Unique
    if (-not $triggers) { return (New-InventoryRow $Object) }

    $urgency = Get-Urgency -DaysLeft $daysLeft -Triggers $triggers
    $hit     = $triggers | Where-Object { $daysLeft -le $_ -and $daysLeft -ge 0 } | Select-Object -First 1
    $plan    = Get-AlertPlan -ExpireDate $expireDate -Today $today -Triggers $triggers `
                   -KeyPrefix "$($Object.id)_$($Object.expireDate)" -State $sentState `
                   -MailOn (Test-NotifyFlag $Object.notifyMethodbyMail) -TeamsOn (Test-NotifyFlag $Object.notifyMethodbyTeams)

    [pscustomobject]@{
        id             = "$($Object.id)"
        name           = "$($Object.name)"
        owner          = "$($Object.owner)"
        servername     = "$($Object.servername)"
        template       = "$($Object.template)"
        environment    = "$($Object.environment)"
        action         = "$($Object.description)"
        expireDate     = $expireDate.ToString('yyyy-MM-dd')
        daysLeft       = $daysLeft
        trigger        = $hit
        allTriggers    = @($triggers)
        maxTrigger     = $triggers[-1]
        windows        = @($plan.windows)
        nextAlertDate  = $plan.nextAlertDate
        nextAlertLabel = $plan.nextAlertLabel
        nextAlertDue   = $plan.nextAlertDue
        nextAlertChannel = $plan.nextAlertChannel
        lastAlerted    = $plan.lastAlerted
        lastAlertedLabel = $plan.lastAlertedLabel
        urgency        = $urgency
        status         = $(if ([string]::IsNullOrWhiteSpace($Object.status)) { 'Completed' } else { "$($Object.status)" })
        copiedDate     = "$($Object.copiedDate)"
        severity       = "$($Object.severity)"
        messageLink    = "$($Object.messageLink)"
        source         = "$($Object.source)"
        appId          = "$($Object.appId)"
        messageId      = "$($Object.messageId)"
        mailOn         = (Test-NotifyFlag $Object.notifyMethodbyMail)
        mailSender     = "$($Object.mail.mailSender)"
        mailSubject    = "$($Object.mail.mailSubject)"
        mailBody       = "$($Object.mail.mailBody)"
        mailRecipients = @($Object.mail.mailRecipients)
        teamsOn        = (Test-NotifyFlag $Object.notifyMethodbyTeams)
        teamWebhook    = (Get-MaskedWebhook "$($Object.teams.teamWebhookUrl)")
        teamSubject    = "$($Object.teams.teamSubject)"
        teamBody       = "$($Object.teams.teamBody)"
    }
}


foreach ($object in $monitoredObjectsRaw) {

    $label = "Object $($object.id) - $($object.name)"
    $isCompleted = ("$($object.status)" -ieq 'Completed')

    # No-credentials apps get their own tab, unless Completed
    if (($object.noCredentials -eq $true -or ($object.source -eq 'EntraAppReg' -and [string]::IsNullOrWhiteSpace($object.expireDate))) -and -not $isCompleted) {
        $noCreds.Add([pscustomobject]@{
            id          = "$($object.id)"
            name        = "$($object.name)"
            servername  = "$($object.servername)"
            environment = "$($object.environment)"
            status      = $(if ([string]::IsNullOrWhiteSpace($object.status)) { 'Backlog' } else { "$($object.status)" })
            template    = "$($object.template)"
            description = "$($object.description)"
            source      = "$($object.source)"
            entraKeyId  = "$($object.entraKeyId)"
        })
        continue
    }

    if ([string]::IsNullOrWhiteSpace($object.expireDate)) {
        if ($isCompleted) { $rows.Add((New-InventoryRow $object)); continue }
        Write-Warning "$label is missing expireDate - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = 'missing expireDate' })
        continue
    }

    try {
        $expireDate = [datetime]::ParseExact(
            $object.expireDate, $DateFormat, [cultureinfo]::InvariantCulture
        ).Date
    }
    catch {
        if ($isCompleted) { $rows.Add((New-InventoryRow $object)); continue }
        Write-Warning "$label has an invalid expireDate: '$($object.expireDate)' (expected $DateFormat) - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = "bad expireDate '$($object.expireDate)'" })
        continue
    }

    $daysLeft = ($expireDate - $today).Days

    # Quoted access: the keys start with a digit
    $rawTriggers = foreach ($key in $TriggerKeys) { $object.$key }

    [int[]] $triggers = $rawTriggers |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { [int]$_ } |
                        Sort-Object -Unique

    if (-not $triggers) {
        Write-Warning "$label has no valid date triggers - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = 'no date triggers' })
        continue
    }

    $declared = @($rawTriggers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]$_ })
    if (($declared -join ',') -ne (($declared | Sort-Object) -join ',')) { Write-Warning "$label declares triggers out of order ($($declared -join ', ')). Sorted automatically."}
    if ($triggers.Count -lt 3) { Write-Warning "$label defines only $($triggers.Count) unique trigger(s). Levels above that collapse into 'ok'."}

    $urgency = Get-Urgency -DaysLeft $daysLeft -Triggers $triggers

        $hit = $triggers | Where-Object { $daysLeft -le $_ -and $daysLeft -ge 0 } | Select-Object -First 1
    $mailOn  = Test-NotifyFlag $object.notifyMethodbyMail
    $teamsOn = Test-NotifyFlag $object.notifyMethodbyTeams
    if (-not $mailOn  -and "$($object.notifyMethodbyMail)"  -match 'True or null') { $placeholder++ }
    if (-not $teamsOn -and "$($object.notifyMethodbyTeams)" -match 'True or null') { $placeholder++ }

        $plan = Get-AlertPlan -ExpireDate $expireDate -Today $today -Triggers $triggers `
                -KeyPrefix "$($object.id)_$($object.expireDate)" -State $sentState -MailOn $mailOn -TeamsOn $teamsOn

    $rows.Add([pscustomobject]@{
        id             = "$($object.id)"
        name           = "$($object.name)"
        owner          = "$($object.owner)"
        servername     = "$($object.servername)"
        template       = "$($object.template)"
        environment    = "$($object.environment)"
        action         = "$($object.description)"
        expireDate     = $expireDate.ToString('yyyy-MM-dd')
        daysLeft       = $daysLeft
        trigger        = $hit
        allTriggers    = @($triggers)
        maxTrigger     = $triggers[-1]
        windows        = @($plan.windows)
        nextAlertDate  = $plan.nextAlertDate
        nextAlertLabel = $plan.nextAlertLabel
        nextAlertDue   = $plan.nextAlertDue
        nextAlertChannel = $plan.nextAlertChannel
        lastAlerted    = $plan.lastAlerted
        lastAlertedLabel = $plan.lastAlertedLabel
        urgency        = $urgency
        status         = $(if ([string]::IsNullOrWhiteSpace($object.status)) { 'Backlog' } else { "$($object.status)" })
        severity       = "$($object.severity)"
        messageLink    = "$($object.messageLink)"
        source         = "$($object.source)"
        appId          = "$($object.appId)"
        messageId      = "$($object.messageId)"

        mailOn         = $mailOn
        mailSender     = "$($object.mail.mailSender)"
        mailSubject    = "$($object.mail.mailSubject)"
        mailBody       = "$($object.mail.mailBody)"
        mailRecipients = @($object.mail.mailRecipients)

        teamsOn        = $teamsOn
        teamWebhook    = (Get-MaskedWebhook "$($object.teams.teamWebhookUrl)")
        teamSubject    = "$($object.teams.teamSubject)"
        teamBody       = "$($object.teams.teamBody)"
        
    })
}

# Completed tab
foreach ($object in $completedObjects) {
    $completedRows.Add((New-CompletedRow $object))
}

if (-not ($rows.Count + $completedRows.Count + $noCreds.Count + $invalid.Count)) {
    throw 'No valid objects to report on. Check the warnings above.'
}
Write-Host "Processed $($rows.Count) monitored + $($completedRows.Count) completed object(s)." -ForegroundColor Green

$rows | Group-Object urgency | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.Name, $_.Count) }
if ($invalid.Count) { Write-Warning "$($invalid.Count) object(s) were skipped and are NOT being monitored." }
if ($placeholder) { Write-Warning "$placeholder notify field(s) still hold the placeholder string. Replace them with true / false." }

#------------------------------- Report settings -------------------------------

# ReportSettings.json, parameters override
$reportSettings = $null
if (Test-Path $ReportSettingsPath) {
    try { $reportSettings = Get-Content -Raw -Encoding UTF8 $ReportSettingsPath | ConvertFrom-Json }
    catch { Write-Warning "Could not read $ReportSettingsPath - using defaults. $($_.Exception.Message)" }
}
function Get-ReportSetting {
    param([string] $Name, $Default)
    if ($null -ne $reportSettings -and $reportSettings.PSObject.Properties[$Name] -and
        -not [string]::IsNullOrWhiteSpace("$($reportSettings.$Name)")) { return $reportSettings.$Name }
    return $Default
}
if ([string]::IsNullOrWhiteSpace($OrganizationName)) { $OrganizationName = "$(Get-ReportSetting 'OrganizationName' '')" }
if ([string]::IsNullOrWhiteSpace($LogoPath))         { $LogoPath         = "$(Get-ReportSetting 'LogoPath' '')" }
$staleAfterHours = 24; try { $staleAfterHours = [double](Get-ReportSetting 'StaleAfterHours' 24) } catch { Write-Warning 'StaleAfterHours is not a number - using 24.' }
$timelineDays    = 90; try { $timelineDays    = [int](Get-ReportSetting 'TimelineDays' 90) }       catch { Write-Warning 'TimelineDays is not a number - using 90.' }
if ($timelineDays -lt 7) { $timelineDays = 7 }
$editorUrl = "$(Get-ReportSetting 'EditorUrl' '')"

# EditorUrl: "" = edit.html if it exists, "off" = none
if ($editorUrl -ieq 'off') { $editorUrl = '' }
elseif ([string]::IsNullOrWhiteSpace($editorUrl)) {
    $editPage = [IO.Path]::Combine((Split-Path $websitePath -Parent), 'edit.html')
    $editorUrl = if (Test-Path $editPage) { 'edit.html' } else { '' }
}

# Logo as data URI
$logoDataUri = ''
if (-not [string]::IsNullOrWhiteSpace($LogoPath)) {
    $logoFull = if ([IO.Path]::IsPathRooted($LogoPath)) { $LogoPath } else { [IO.Path]::Combine($scriptRoot, $LogoPath) }
    $logoFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($logoFull)
    $mimeTypes = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'; '.webp' = 'image/webp' }
    $logoExt = [IO.Path]::GetExtension($logoFull).ToLowerInvariant()
    if (-not (Test-Path $logoFull))            { Write-Warning "Logo not found: $logoFull - the report is written without it." }
    elseif (-not $mimeTypes.ContainsKey($logoExt)) { Write-Warning "Logo must be .png, .jpg, .gif, .svg or .webp: $logoFull" }
    elseif ((Get-Item $logoFull).Length -gt 512KB) { Write-Warning "Logo is larger than 512 KB - use a smaller file: $logoFull" }
    else {
        $logoDataUri = "data:$($mimeTypes[$logoExt]);base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logoFull))
        Write-Host "- Logo embedded from $logoFull" -ForegroundColor DarkGray
    }
}

$reportVersion = ''
if (Test-Path $ScriptSettingsPath) {
    try { $reportVersion = "$((Get-Content -Raw -Encoding UTF8 $ScriptSettingsPath | ConvertFrom-Json).version)" } catch { $reportVersion = '' }
}

$completeDisplay = $CompleteJsonPath
if ($scriptRoot -and $completeDisplay.StartsWith($scriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $completeDisplay = $completeDisplay.Substring($scriptRoot.Length).TrimStart('\', '/')
}

#------------------------------- Embed as JSON -------------------------------

$dataJson      = ConvertTo-EmbedJson $rows
$completedJson = ConvertTo-EmbedJson $completedRows
$invalidJson   = ConvertTo-EmbedJson $invalid -Depth 3
$noCredsJson   = ConvertTo-EmbedJson $noCreds -Depth 3

# Page settings
$meta = [ordered]@{
    organization    = $OrganizationName
    logo            = $logoDataUri
    generated       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [cultureinfo]::InvariantCulture)
    staleAfterHours = $staleAfterHours
    timelineDays    = $timelineDays
    completeSource  = $completeDisplay
    editorUrl       = $editorUrl
    version         = $reportVersion
    expiredNotifyDays = 7
}
$metaJson = ConvertTo-EmbedJson ([pscustomobject]$meta) -Single

Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------
# Section 3 : Create HTML-Report file
$Section = "Section 3 : Create HTML-Report file"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
if (-not (Test-Path $TemplatePath)) { throw "Report template not found: $TemplatePath" }
$template = Get-Content -Raw -Encoding UTF8 $TemplatePath

$html = $template.Replace('__PSTODO_META__', $metaJson)
$html = $html.Replace('__PSTODO_DATA__', $dataJson)
$html = $html.Replace('__PSTODO_COMPLETED__', $completedJson)
$html = $html.Replace('__PSTODO_INVALID__', $invalidJson)
$html = $html.Replace('__PSTODO_NONCRED__', $noCredsJson)

Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------

# Section 4 : Export html file and create backups
$Section = "Section 4 : Export HTML-Report file"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
$outDir = Split-Path $websitePath -Parent
if ($outDir -and -not (Test-Path $outDir)) {New-Item -Path $outDir -ItemType Directory -Force | Out-Null}
$html | Set-Content -Path $websitePath -Encoding UTF8 -Verbose
Write-Host "Report written to $websitePath" -ForegroundColor Green

$backupDir = Split-Path $backupWebsitePath -Parent
if ($backupDir -and -not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }

get-childitem -Path $websitePath -Force -File | Copy-Item -Destination $backupWebsitePath -Force -Verbose

Write-Host "Report written to $backupWebsitePath" -ForegroundColor Green
Write-Host "HTML file written to $websitePath" -ForegroundColor Green



Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#----------------------------------- End Script ------------------------------------------
Stop-Transcript