<#
.DESCRIPTION
    Clears the alert history of one object in Files\state\sent-state.json, so the
    object alerts again on the next run of psToDo-v1.3.ps1. Used by Tools in the
    dashboard (psToDo-Tools-v1.0.ps1).

.EXAMPLE
    .\Reset-AlertState.ps1 -ObjectId 12
#>

[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)] [string] $ObjectId)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent (Split-Path -Parent $here)
$ErrorActionPreference = 'Stop'

try {
    $objects = @((Get-Content -Raw -Encoding UTF8 "$root\Files\db\monitorobjects.json" | ConvertFrom-Json))
    $object  = $objects | Where-Object { "$($_.id)" -eq $ObjectId } | Select-Object -First 1
    if (-not $object) { throw "Object $ObjectId is not in monitorobjects.json." }

    $statePath = "$root\Files\state\sent-state.json"
    $state = [ordered]@{}
    if (Test-Path $statePath) {
        $raw = Get-Content -Raw -Encoding UTF8 $statePath
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
        }
    }

    # State keys: <id>_<expireDate>_<window>
    $prefix = "$($object.id)_$($object.expireDate)_"
    $remove = @($state.Keys | Where-Object { "$_".StartsWith($prefix, [StringComparison]::Ordinal) })
    foreach ($key in $remove) {
        $sent = $state[$key]
        if ($sent -is [datetime]) { $sent = $sent.ToString('yyyy-MM-dd HH:mm') }
        Write-Host "- $key (sent $sent)"
        if ($PSCmdlet.ShouldProcess($key, 'Remove from sent-state.json')) { $state.Remove($key) }
    }

    if ($remove.Count -and -not $WhatIfPreference) {
        $json = if ($state.Count) { $state | ConvertTo-Json -Depth 3 } else { '{}' }
        $json | Set-Content -Path $statePath -Encoding UTF8
    }
    Write-Host "Result: $($remove.Count) alert record(s) cleared for object $($object.id) - $($object.name)."
}
catch {
    Write-Host "Result: $($_.Exception.Message)"
    exit 1
}
