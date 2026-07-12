function Get-Urgency {
<#
   Triggers must be sorted ascending. trigger[0] is the smallest, and
   therefore the last alert before expiry - the critical one.
   Objects with fewer than three triggers degrade gracefully:
   the highest defined level is used as the outer boundary.
#>
    param([int] $DaysLeft, [int[]] $Triggers)

    if ($DaysLeft -lt 0) { return 'expired' }
    if ($Triggers.Count -ge 1 -and $DaysLeft -le $Triggers[0]) { return 'critical' }
    if ($Triggers.Count -ge 2 -and $DaysLeft -le $Triggers[1]) { return 'warning'  }
    return 'ok'
}