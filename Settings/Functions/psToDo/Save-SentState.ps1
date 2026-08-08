function Save-SentState {
    <#
        Drops keys for objects that no longer exist, and for expireDate values
        that have changed - a renewed certificate re-arms all of its windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [string]    $Path,
        [Parameter(Mandatory)] [string[]]  $LiveKeyPrefixes
    )

    # @() around .Keys: removing from a hashtable while enumerating it throws
    foreach ($key in @($State.Keys)) {
        $prefix = ($key -split '_')[0..1] -join '_'
        if ($prefix -notin $LiveKeyPrefixes) {
            $State.Remove($key)
            Write-Verbose "Retired stale state key: $key"
        }
    }

    # Make sure the state folder exists (first run creates Files\state).
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    try {
        if ($State.Count) {
            $State | ConvertTo-Json -Depth 3 | Set-Content -Path $Path -Encoding UTF8
        }
        else {
            '{}' | Set-Content -Path $Path -Encoding UTF8
        }
        Write-Host "State saved: $($State.Count) window(s) recorded." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Could not write the state file. The next run may resend: $($_.Exception.Message)"
    }
}