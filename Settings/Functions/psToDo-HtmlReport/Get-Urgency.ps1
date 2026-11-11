function Get-Urgency {
# Triggers sorted ascending: trigger[0] = critical, trigger[1] = warning
    param([int] $DaysLeft, [int[]] $Triggers)

    if ($DaysLeft -lt 0) { return 'expired' }
    if ($Triggers.Count -ge 1 -and $DaysLeft -le $Triggers[0]) { return 'critical' }
    if ($Triggers.Count -ge 2 -and $DaysLeft -le $Triggers[1]) { return 'warning'  }
    return 'ok'
}