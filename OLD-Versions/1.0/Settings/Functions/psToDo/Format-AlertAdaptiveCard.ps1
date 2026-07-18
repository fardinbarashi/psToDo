function Format-AlertAdaptiveCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Alert)

    $p = Get-AlertPresentation -Alert $Alert

    @{
        type      = 'AdaptiveCard'
        version   = '1.4'
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        body      = @(
            @{
                type  = 'Container'
                style = $p.CardStyle
                items = @(
                    @{ type = 'TextBlock'; text = $Alert.urgency.ToUpper(); size = 'Small'
                       weight = 'Bolder'; spacing = 'None' }
                    @{ type = 'TextBlock'; text = $p.Headline; size = 'Medium'
                       weight = 'Bolder'; wrap = $true }
                )
            }
            @{ type = 'TextBlock'; text = $Alert.teamBody; wrap = $true }
            @{
                type  = 'FactSet'
                facts = @(
                    @{ title = 'Server';      value = "$($Alert.servername)"  }
                    @{ title = 'Template';    value = "$($Alert.template)"    }
                    @{ title = 'Environment'; value = "$($Alert.environment)" }
                    @{ title = 'Expires';     value = "$($p.ExpireText)"      }
                    @{ title = 'Days left';   value = "$($Alert.daysLeft)"    }
                    @{ title = 'Trigger';     value = "$($p.TriggerText)"     }
                )
            }
            @{
                type      = 'TextBlock'
                text      = "**Action required**`n`n$($Alert.action)"
                wrap      = $true
                separator = $true
            }
        )
    }
}