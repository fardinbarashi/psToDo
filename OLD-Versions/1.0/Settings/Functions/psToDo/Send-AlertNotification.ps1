function Send-AlertNotification {
    # Reads notifyMethodbyMail and notifyMethodbyTeams and dispatches.
    # Two independent ifs, not if/else - both can be true.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Alert)

    $result = [pscustomobject]@{
        Id        = $Alert.id
        Name      = $Alert.name
        Trigger   = $Alert.trigger
        Urgency   = $Alert.urgency
        StateKey  = $Alert.stateKey
        MailSent  = $false
        TeamsSent = $false
        Skipped   = $false
    }

    if (-not $Alert.mailOn -and -not $Alert.teamsOn) {
        Write-Warning "  Object $($Alert.id) - $($Alert.name): no notification channel enabled. Nothing sent."
        $result.Skipped = $true
        return $result
    }

    if ($Alert.mailOn)  { $result.MailSent  = Send-AlertMail  -Alert $Alert -WhatIf:$WhatIfPreference }
    if ($Alert.teamsOn) { $result.TeamsSent = Send-AlertTeams -Alert $Alert -WhatIf:$WhatIfPreference }

    return $result
}
