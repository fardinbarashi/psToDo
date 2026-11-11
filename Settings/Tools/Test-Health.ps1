<#
.DESCRIPTION
    Health check for psToDo, run as the account that runs the scheduled tasks.
    Used by Tools in the dashboard (psToDo-Tools-v1.0.ps1).

.EXAMPLE
    .\Test-Health.ps1
#>

[CmdletBinding()]
param()

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent (Split-Path -Parent $here)
$counts = @{ OK = 0; WARN = 0; FAIL = 0 }

function Add-Check {
    param([ValidateSet('OK', 'WARN', 'FAIL')] [string] $State, [string] $Text)
    $counts[$State]++
    Write-Host ('[{0}] {1}' -f $State.PadRight(4), $Text)
}

function Get-Age {
    param([datetime] $When)
    $span = (Get-Date) - $When
    if ($span.TotalHours -lt 1) { return "$([int]$span.TotalMinutes) min ago" }
    if ($span.TotalHours -lt 48) { return "$([int]$span.TotalHours) h ago" }
    return "$([int]$span.TotalDays) days ago"
}

Write-Host "psToDo health check - $([Environment]::MachineName) as $([Environment]::UserName) - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"

# monitorobjects.json
$dbPath = "$root\Files\db\monitorobjects.json"
$objects = @()
try {
    $objects = @((Get-Content -Raw -Encoding UTF8 $dbPath | ConvertFrom-Json))
    Add-Check OK "monitorobjects.json: $($objects.Count) object(s)"
}
catch { Add-Check FAIL "monitorobjects.json cannot be read: $($_.Exception.Message)" }

$needsMail = @($objects | Where-Object { $_.notifyMethodbyMail -eq $true }).Count -gt 0

# Graph settings and certificate (mail)
$settingsPath = "$root\Settings\Config\MsGraphSettings.json"
$settings = $null
try {
    $settings = Get-Content -Raw -Encoding UTF8 $settingsPath | ConvertFrom-Json
    $missing = @('TenantId', 'AppId', 'CertificateThumbprint' | Where-Object { [string]::IsNullOrWhiteSpace($settings.$_) -or "$($settings.$_)" -match '\s' })
    if ($missing) { Add-Check $(if ($needsMail) { 'FAIL' } else { 'WARN' }) "MsGraphSettings.json: not filled in: $($missing -join ', ')"; $settings = $null }
    else { Add-Check OK 'MsGraphSettings.json: TenantId, AppId and CertificateThumbprint are set' }
}
catch { Add-Check $(if ($needsMail) { 'FAIL' } else { 'WARN' }) "MsGraphSettings.json cannot be read: $($_.Exception.Message)" }

if ($settings) {
    $cert = $null
    try { $cert = Get-ChildItem "Cert:\LocalMachine\My\$($settings.CertificateThumbprint)" -ErrorAction Stop } catch { }
    if (-not $cert) { Add-Check FAIL "Certificate $($settings.CertificateThumbprint) not found in Cert:\LocalMachine\My" }
    else {
        $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
        if ($days -lt 0)      { Add-Check FAIL "Graph certificate expired $($cert.NotAfter.ToString('yyyy-MM-dd'))" }
        elseif ($days -lt 30) { Add-Check WARN "Graph certificate expires in $days days ($($cert.NotAfter.ToString('yyyy-MM-dd')))" }
        else                  { Add-Check OK "Graph certificate valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))" }
        try {
            $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            if ($key) { Add-Check OK 'Private key of the certificate can be read by this account' }
            else { Add-Check FAIL 'The certificate has no private key this account can use' }
        }
        catch { Add-Check FAIL "Private key cannot be read (no Read on the key file): $($_.Exception.Message)" }
    }
}

# Network
foreach ($hostName in 'login.microsoftonline.com', 'graph.microsoft.com') {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect($hostName, 443, $null, $null)
        if ($wait.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) { Add-Check OK "Network: $hostName port 443 reachable" }
        else { Add-Check $(if ($needsMail) { 'FAIL' } else { 'WARN' }) "Network: $hostName port 443 not reachable" }
    }
    catch { Add-Check $(if ($needsMail) { 'FAIL' } else { 'WARN' }) "Network: $hostName - $($_.Exception.Message)" }
    finally { $client.Close() }
}

# Alert script
$lastLog = Get-ChildItem "$root\Logs" -Filter 'psToDo-v1.3.ps1 - *' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $lastLog) { Add-Check WARN 'Alert script: no run found in Logs' }
elseif (((Get-Date) - $lastLog.LastWriteTime).TotalHours -gt 26) { Add-Check WARN "Alert script: last run $(Get-Age $lastLog.LastWriteTime) ($($lastLog.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" }
else { Add-Check OK "Alert script: last run $(Get-Age $lastLog.LastWriteTime)" }

$statePath = "$root\Files\state\sent-state.json"
if (Test-Path $statePath) {
    try {
        $raw = Get-Content -Raw -Encoding UTF8 $statePath
        $n = if ([string]::IsNullOrWhiteSpace($raw)) { 0 } else { @(($raw | ConvertFrom-Json).PSObject.Properties).Count }
        Add-Check OK "sent-state.json: $n alert record(s)"
    }
    catch { Add-Check WARN "sent-state.json cannot be read: $($_.Exception.Message)" }
}
else { Add-Check OK 'sent-state.json: no alerts sent yet' }

# Dashboard
$staleHours = 24
try {
    $rs = Get-Content -Raw -Encoding UTF8 "$root\Settings\Config\ReportSettings.json" | ConvertFrom-Json
    if ($rs.StaleAfterHours) { $staleHours = [double]$rs.StaleAfterHours }
} catch { }
$index = Get-Item "$root\Files\report\index.html" -ErrorAction SilentlyContinue
if (-not $index) { Add-Check WARN 'Dashboard: Files\report\index.html not found' }
elseif (((Get-Date) - $index.LastWriteTime).TotalHours -gt $staleHours) { Add-Check WARN "Dashboard: index.html built $(Get-Age $index.LastWriteTime)" }
else { Add-Check OK "Dashboard: index.html built $(Get-Age $index.LastWriteTime)" }

# Scheduled tasks that run psToDo scripts
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    try {
        $tasks = @(Get-ScheduledTask | Where-Object { ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'psToDo' })
        if (-not $tasks) { Add-Check WARN 'Scheduled tasks: none found that run a psToDo script' }
        foreach ($task in $tasks) {
            $info = $task | Get-ScheduledTaskInfo
            $text = "Task '$($task.TaskName)': last run $(if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }), result $($info.LastTaskResult), state $($task.State)"
            # 0 = ok, 267009 = running, 267011 = not run yet
            if ($task.State -eq 'Disabled') { Add-Check WARN $text }
            elseif ($info.LastTaskResult -in 0, 267009, 267011) { Add-Check OK $text }
            else { Add-Check WARN $text }
        }
    }
    catch { Add-Check WARN "Scheduled tasks cannot be listed: $($_.Exception.Message)" }
}

Write-Host "Result: $($counts.OK) OK, $($counts.WARN) warning(s), $($counts.FAIL) failed"
if ($counts.FAIL) { exit 1 }
