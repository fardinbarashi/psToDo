function Send-AlertMail {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Alert,
        [switch] $SaveToSentItems
    )

    if (-not $Alert.mailOn) {
        Write-Verbose "Object $($Alert.id): notifyMethodbyMail is false - skipping mail."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Alert.mailSender)) {
        Write-Warning "  Object $($Alert.id) has no mailSender - skipping mail."
        return $false
    }

    $recipients = @($Alert.mailRecipients) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $recipients) {
        Write-Warning "  Object $($Alert.id) has no mailRecipients - skipping mail."
        return $false
    }

    $p = Get-AlertPresentation -Alert $Alert

    $payload = @{
        message = @{
            subject      = "$($p.Prefix) $($Alert.mailSubject)"
            body         = @{
                contentType = 'HTML'
                content     = Format-AlertMailBody -Alert $Alert
            }
            toRecipients = @(
                foreach ($r in $recipients) { @{ emailAddress = @{ address = $r } } }
            )
        }
        saveToSentItems = [bool]$SaveToSentItems
    }

    # The sender must be a real mailbox the app is allowed to send from.
    # An alias or a distribution group returns ErrorInvalidUser.
    $uri    = "https://graph.microsoft.com/v1.0/users/$($Alert.mailSender)/sendMail"
    $target = "$($recipients -join ', ') for object $($Alert.id) - $($Alert.name)"

    if (-not $PSCmdlet.ShouldProcess($target, 'Send alert mail')) { return $false }

    try {
        Invoke-MgGraphRequest -Method POST -Uri $uri `
            -Body ($payload | ConvertTo-Json -Depth 6) `
            -ContentType 'application/json' | Out-Null

        Write-Host "  Mail sent to $($recipients -join ', ')" -ForegroundColor Green
        return $true
    }
    catch {
        # Graph puts the useful part in the response body, not the exception message
        $detail = $_.ErrorDetails.Message
        if ($detail) { try { $detail = ($detail | ConvertFrom-Json).error.message } catch { } }
        Write-Warning "  Mail to $($recipients -join ', ') failed: $($detail ?? $_.Exception.Message)"
        return $false
    }
}