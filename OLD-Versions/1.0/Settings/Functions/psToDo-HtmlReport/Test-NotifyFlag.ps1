function Test-NotifyFlag {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value)  { return $false }
    return ("$Value".Trim() -match '^(true|1|yes|ja)$')
}