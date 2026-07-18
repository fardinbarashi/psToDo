function Get-AlertPresentation {
    # Wording and severity shared by mail and Teams, so the two cannot drift apart
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Alert)

    $headline = if ($Alert.daysLeft -lt 0) {
        "$($Alert.name) expired $([Math]::Abs($Alert.daysLeft)) days ago"
    } elseif ($Alert.daysLeft -eq 0) {
        "$($Alert.name) expires today"
    } elseif ($Alert.daysLeft -eq 1) {
        "$($Alert.name) expires tomorrow"
    } else {
        "$($Alert.name) expires in $($Alert.daysLeft) days"
    }

    [pscustomobject]@{
        Headline    = $headline
        Prefix      = switch ($Alert.urgency) {
                          'expired'  { '[EXPIRED]'  }
                          'critical' { '[CRITICAL]' }
                          'warning'  { '[WARNING]'  }
                          default    { '[NOTICE]'   }
                      }
        Color       = switch ($Alert.urgency) {
                          'expired'  { '#B10E1E' }
                          'critical' { '#D13438' }
                          'warning'  { '#BA7517' }
                          default    { '#0078D4' }
                      }
        CardStyle   = switch ($Alert.urgency) {
                          'expired'  { 'attention' }
                          'critical' { 'attention' }
                          'warning'  { 'warning'   }
                          default    { 'emphasis'  }
                      }
        ExpireText  = $Alert.expireDate.ToString('dddd d MMMM yyyy', [cultureinfo]'en-GB')
        TriggerText = if ($null -ne $Alert.trigger)   { "$($Alert.trigger)-day window" }
                      elseif ($Alert.daysLeft -eq 0)  { 'expiry day'       }
                      else                            { 'expired reminder' }
    }
}