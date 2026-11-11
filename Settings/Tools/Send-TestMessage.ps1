<#
.DESCRIPTION
    Sends the alert of one object as a test, marked [TEST]. Used by Tools in the
    dashboard (psToDo-Tools-v1.0.ps1). The sent state is not touched.

.EXAMPLE
    .\Send-TestMessage.ps1 -ObjectId 12 -Channel mail -To admin@contoso.com
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ObjectId,
    [ValidateSet('mail', 'teams', 'both')] [string] $Channel = 'mail',
    [string] $To = ''
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent (Split-Path -Parent $here)
$ErrorActionPreference = 'Stop'

try {
    Get-ChildItem -Path "$root\Settings\Functions\psToDo" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
    . "$root\Settings\Functions\psToDo-HtmlReport\Get-Urgency.ps1"

    $objects = @((Get-Content -Raw -Encoding UTF8 "$root\Files\db\monitorobjects.json" | ConvertFrom-Json))
    $object  = $objects | Where-Object { "$($_.id)" -eq $ObjectId } | Select-Object -First 1
    if (-not $object) { throw "Object $ObjectId is not in monitorobjects.json." }

    try { $expireDate = [datetime]::ParseExact("$($object.expireDate)", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture).Date }
    catch { throw "Object $ObjectId has no valid expireDate, so there is no alert to test." }
    $daysLeft = ($expireDate - (Get-Date).Date).Days

    $rawTriggers = foreach ($key in '1dateTrigger', '2dateTrigger', '3dateTrigger') { $object.$key }
    [int[]] $triggers = $rawTriggers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]$_ } | Sort-Object -Unique
    if (-not $triggers) { $triggers = @(7) }
    $hit = $triggers | Where-Object { $daysLeft -le $_ -and $daysLeft -ge 0 } | Select-Object -First 1

    $recipients = @($object.mail.mailRecipients)
    if ($To) { $recipients = @($To) }

    $alert = [pscustomobject]@{
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
        urgency        = Get-Urgency -DaysLeft $daysLeft -Triggers $triggers
        stateKey       = $null
        mailOn         = ($Channel -in 'mail', 'both')
        mailSender     = "$($object.mail.mailSender)"
        mailSubject    = "[TEST] $($object.mail.mailSubject)"
        mailBody       = "$($object.mail.mailBody)"
        mailRecipients = $recipients
        teamsOn        = ($Channel -in 'teams', 'both')
        teamSubject    = "[TEST] $($object.teams.teamSubject)"
        teamBody       = "$($object.teams.teamBody)"
        teamWebhookUrl = "$($object.teams.teamWebhookUrl)"
    }
    Write-Host "Test for object $($alert.id) - $($alert.name) ($Channel)"

    $results = @()
    $failed  = $false

    if ($alert.mailOn) {
        if (-not $WhatIfPreference) {
            Initialize-RequiredModules -Modules @('Microsoft.Graph.Authentication')
            $settings = Get-Content -Raw -Encoding UTF8 "$root\Settings\Config\MsGraphSettings.json" | ConvertFrom-Json
            foreach ($k in 'TenantId', 'AppId', 'CertificateThumbprint') { if ([string]::IsNullOrWhiteSpace($settings.$k)) { throw "MsGraphSettings.json is missing $k" } }
            $certificate = Get-ChildItem "Cert:\LocalMachine\My\$($settings.CertificateThumbprint)" -ErrorAction SilentlyContinue
            if (-not $certificate) { throw "Certificate $($settings.CertificateThumbprint) not found in Cert:\LocalMachine\My" }
            Connect-CalenderReminderGraph -TenantId $settings.TenantId -AppId $settings.AppId -Certificate $certificate | Out-Null
        }
        try {
            if (Send-AlertMail -Alert $alert -WhatIf:$WhatIfPreference) { $results += "mail sent to $($recipients -join ', ')" }
            elseif ($WhatIfPreference) { $results += "mail would be sent to $($recipients -join ', ')" }
            else { $results += 'mail NOT sent'; $failed = $true }
        }
        finally { if (-not $WhatIfPreference -and (Get-MgContext)) { Disconnect-MgGraph | Out-Null } }
    }

    if ($alert.teamsOn) {
        if (Send-AlertTeams -Alert $alert -WhatIf:$WhatIfPreference) { $results += 'Teams message posted' }
        elseif ($WhatIfPreference) { $results += 'Teams message would be posted' }
        else { $results += 'Teams message NOT posted'; $failed = $true }
    }

    Write-Host "Result: $($results -join '; ')"
    if ($failed) { exit 1 }
}
catch {
    Write-Host "Result: $($_.Exception.Message)"
    exit 1
}
