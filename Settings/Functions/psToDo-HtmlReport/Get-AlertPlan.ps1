function ConvertTo-StateTime {
# Sent-state value (string or DateTime) to local DateTime, $null if unreadable
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Utc) { return $Value.ToLocalTime() }
        return $Value
    }
    try { return ([DateTimeOffset]::Parse("$Value", [cultureinfo]::InvariantCulture)).LocalDateTime }
    catch { return $null }
}

function Get-AlertPlan {
# Alert windows, next alert and last alert for one object.
# Same rules and state keys as psToDo-v1.3.ps1:
#   <id>_<expireDate>_<trigger> | _expiryday | _expired-<yyyy-MM-dd>
    param(
        [datetime]  $ExpireDate,
        [datetime]  $Today,
        [int[]]     $Triggers,
        [string]    $KeyPrefix,
        [hashtable] $State,
        [bool]      $MailOn,
        [bool]      $TeamsOn,
        [int]       $ExpiredNotifyDays = 7
    )

    if ($null -eq $State) { $State = @{} }
    $fmtDay  = 'yyyy-MM-dd'
    $fmtTime = 'yyyy-MM-dd HH:mm'
    $inv     = [cultureinfo]::InvariantCulture
    $levels  = @('critical', 'warning', 'ok')

    $channels = @()
    if ($MailOn)  { $channels += 'Mail' }
    if ($TeamsOn) { $channels += 'Teams' }
    $hasChannel = ($channels.Count -gt 0)

    $items      = [System.Collections.Generic.List[object]]::new()
    $candidates = [System.Collections.Generic.List[object]]::new()

    # Trigger windows
    $prev = 0
    for ($i = 0; $i -lt $Triggers.Count; $i++) {
        $t     = $Triggers[$i]
        $level = if ($i -lt $levels.Count) { $levels[$i] } else { 'ok' }
        if ($t -lt 1) { $prev = $t; continue }

        $opens  = $ExpireDate.AddDays(-$t)
        $closes = $ExpireDate.AddDays(-($prev + 1))
        $sentAt = ConvertTo-StateTime $State["${KeyPrefix}_$t"]

        $status = if ($sentAt)                                { 'sent' }
                  elseif ($Today -ge $opens -and $Today -le $closes) { if ($hasChannel) { 'due' } else { 'nochannel' } }
                  elseif ($Today -lt $opens)                  { 'upcoming' }
                  else                                        { 'missed' }

        $items.Add([pscustomobject]@{
            kind    = 'window'
            trigger = $t
            level   = $level
            label   = "$t-day window"
            opens   = $opens.ToString($fmtDay, $inv)
            closes  = $closes.ToString($fmtDay, $inv)
            status  = $status
            sentAt  = $(if ($sentAt) { $sentAt.ToString($fmtTime, $inv) } else { '' })
        })

        if ($status -eq 'due')      { $candidates.Add(@{ date = $Today; label = "$t-day window"; due = $true }) }
        if ($status -eq 'upcoming') { $candidates.Add(@{ date = $opens; label = "$t-day window"; due = $false }) }
        $prev = $t
    }

    # Expiry day
    $sentAt = ConvertTo-StateTime $State["${KeyPrefix}_expiryday"]
    $status = if ($sentAt)                 { 'sent' }
              elseif ($Today -eq $ExpireDate) { if ($hasChannel) { 'due' } else { 'nochannel' } }
              elseif ($Today -lt $ExpireDate) { 'upcoming' }
              else                         { 'missed' }
    $items.Add([pscustomobject]@{
        kind = 'expiry'; trigger = 0; level = 'expired'; label = 'Expiry day'
        opens = $ExpireDate.ToString($fmtDay, $inv); closes = $ExpireDate.ToString($fmtDay, $inv)
        status = $status; sentAt = $(if ($sentAt) { $sentAt.ToString($fmtTime, $inv) } else { '' })
    })
    if ($status -eq 'due')      { $candidates.Add(@{ date = $Today;      label = 'Expiry day'; due = $true }) }
    if ($status -eq 'upcoming') { $candidates.Add(@{ date = $ExpireDate; label = 'Expiry day'; due = $false }) }

    # Expired reminders
    $reminderPrefix = "${KeyPrefix}_expired-"
    $lastReminder = $null
    foreach ($k in @($State.Keys)) {
        if (-not "$k".StartsWith($reminderPrefix, [System.StringComparison]::Ordinal)) { continue }
        $at = ConvertTo-StateTime $State[$k]
        if ($at -and (-not $lastReminder -or $at -gt $lastReminder)) { $lastReminder = $at }
    }
    $step = [Math]::Max(1, $ExpiredNotifyDays)
    $nextReminder = $ExpireDate.AddDays($step)
    while ($nextReminder -lt $Today) { $nextReminder = $nextReminder.AddDays($step) }
    if ($nextReminder -eq $Today -and $State.ContainsKey($reminderPrefix + $Today.ToString($fmtDay, $inv))) {
        $nextReminder = $nextReminder.AddDays($step)
    }
    $reminderDue = ($nextReminder -eq $Today)
    $status = if ($reminderDue) { if ($hasChannel) { 'due' } else { 'nochannel' } } else { 'upcoming' }
    $items.Add([pscustomobject]@{
        kind = 'reminder'; trigger = $null; level = 'expired'; label = "Reminder every $step days after expiry"
        opens = $nextReminder.ToString($fmtDay, $inv); closes = ''
        status = $status; sentAt = $(if ($lastReminder) { $lastReminder.ToString($fmtTime, $inv) } else { '' })
    })
    $candidates.Add(@{ date = $nextReminder; label = 'Expired reminder'; due = $reminderDue })

    # Next alert
    $next = $null
    if ($hasChannel) {
        $next = $candidates | Sort-Object { $_.date } | Select-Object -First 1
    }

    # Last alert sent
    $lastAt = $null; $lastKey = $null
    $ownPrefix = "${KeyPrefix}_"
    foreach ($k in @($State.Keys)) {
        if (-not "$k".StartsWith($ownPrefix, [System.StringComparison]::Ordinal)) { continue }
        $at = ConvertTo-StateTime $State[$k]
        if ($at -and (-not $lastAt -or $at -gt $lastAt)) { $lastAt = $at; $lastKey = "$k".Substring($ownPrefix.Length) }
    }
    $lastLabel = if (-not $lastKey)                 { '' }
                 elseif ($lastKey -eq 'expiryday')  { 'Expiry day' }
                 elseif ($lastKey -like 'expired-*') { 'Expired reminder' }
                 else                               { "$lastKey-day window" }

    [pscustomobject]@{
        windows          = @($items)
        nextAlertDate    = $(if ($next) { ([datetime]$next.date).ToString($fmtDay, $inv) } else { $null })
        nextAlertLabel   = $(if ($next) { "$($next.label)" } else { '' })
        nextAlertDue     = $(if ($next) { [bool]$next.due } else { $false })
        nextAlertChannel = ($channels -join ' + ')
        lastAlerted      = $(if ($lastAt) { $lastAt.ToString($fmtTime, $inv) } else { $null })
        lastAlertedLabel = $lastLabel
    }
}

function Get-MaskedWebhook {
# Show only host and last four characters of a webhook URL
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $u = $Url.Trim()
    $tail = if ($u.Length -gt 8) { $u.Substring($u.Length - 4) } else { '' }
    $ellipsis = [string][char]0x2026
    if ($u -match '^(https?://[^/?#]+)') { return "$($Matches[1])/$ellipsis$tail" }
    return "$ellipsis$tail"
}

function ConvertTo-EmbedJson {
# JSON array for a <script> block, '<' escaped
    param($Items, [int] $Depth = 6, [switch] $Single)
    if ($Single) { $json = ConvertTo-Json -InputObject $Items -Depth $Depth -Compress }
    else {
        $list = @($Items | Where-Object { $null -ne $_ })
        if (-not $list.Count) { return '[]' }
        $json = ConvertTo-Json -InputObject $list -Depth $Depth -Compress
    }
    return $json.Replace('<', ([string][char]0x5C + 'u003c'))
}
