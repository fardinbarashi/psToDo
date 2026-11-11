function Get-SentState {
    # Missing or corrupt file = empty state
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $state = @{}

    if (-not (Test-Path $Path)) {
        Write-Host 'No state file yet. Every open trigger window will alert.' -ForegroundColor DarkGray
        return $state
    }

    try {
        $raw = Get-Content -Raw -Encoding UTF8 $Path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

        ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
        Write-Host "State loaded: $($state.Count) window(s) already alerted." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Could not read the state file - starting fresh: $($_.Exception.Message)"
    }

    return $state
}