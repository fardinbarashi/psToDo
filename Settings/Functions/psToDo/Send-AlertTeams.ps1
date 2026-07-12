function Send-AlertTeams {
    <#
        Posts to a Teams Workflows (Power Automate) webhook.
        No app registration, no token, no Graph permission needed.

        The webhook URL IS the credential. Anyone holding it can post to the
        channel. Keep monitorobjects.json out of any web root and out of git.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Alert)

    if (-not $Alert.teamsOn) {
        Write-Verbose "Object $($Alert.id): notifyMethodbyTeams is false - skipping Teams."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Alert.teamWebhookUrl)) {
        Write-Warning "  Object $($Alert.id) has no teamWebhookUrl - skipping Teams."
        return $false
    }

    if ($Alert.teamWebhookUrl -notmatch '^https://') {
        Write-Warning "  Object $($Alert.id) has a teamWebhookUrl that is not an https URL - skipping Teams."
        return $false
    }

    $payload = @{
        type        = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl  = $null
                content     = Format-AlertAdaptiveCard -Alert $Alert
            }
        )
    }

    if (-not $PSCmdlet.ShouldProcess("Teams channel for object $($Alert.id)", 'Post Teams alert')) {
        return $false
    }

    try {
        # Depth 20: the default of 2 turns nested hashtables into type names
        Invoke-RestMethod -Method POST -Uri $Alert.teamWebhookUrl `
            -Body ($payload | ConvertTo-Json -Depth 20) `
            -ContentType 'application/json' | Out-Null

        Write-Host '  Teams message posted.' -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "  Teams post failed for object $($Alert.id): $($_.Exception.Message)"
        return $false
    }
}