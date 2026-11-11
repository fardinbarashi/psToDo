<#
.DESCRIPTION
    SYSTEM REQUIREMENTS : Windows PowerShell 5.1 or PowerShell 7.x.

    Runs the tools that editors order from the dashboard (Tools).
    The web page only writes a request file to Files\queue\requests. This script
    picks the requests up, runs the matching script from the list below and writes
    status and output to Files\queue\runs and Files\queue\logs.

    Run it every minute from a scheduled task, as the same account that runs
    psToDo-v1.3.ps1. Setup: Install-help\Setup-ToolsRunner.ps1

.EXAMPLE
    .\psToDo-Tools-v1.0.ps1

.NOTES
    Author      : Fardin Barashi
    Title       : psToDo tools runner
    Version     : 1.0
    Github Link : https://github.com/fardinbarashi
#>

[CmdletBinding()]
param(
    [string] $QueuePath = '',
    [int] $TimeoutMinutes = 15,
    [int] $KeepRuns = 50
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($QueuePath)) { $QueuePath = [IO.Path]::Combine($scriptRoot, 'Files', 'queue') }
$QueuePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($QueuePath)

Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'
$runnerVersion = '1.0'

$requestDir = [IO.Path]::Combine($QueuePath, 'requests')
$runDir     = [IO.Path]::Combine($QueuePath, 'runs')
$logDir     = [IO.Path]::Combine($QueuePath, 'logs')
$heartbeat  = [IO.Path]::Combine($QueuePath, 'runner.json')
$dbPath     = [IO.Path]::Combine($scriptRoot, 'Files', 'db', 'monitorobjects.json')
foreach ($d in @($QueuePath, $requestDir, $runDir, $logDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

#------------------------------- Tools -------------------------------
# The only scripts that can be run. Paths are relative to this script.

$rebuild = @(
    @{ File = 'psToDo-HTML-Report-v1.3.ps1' }
    @{ File = 'psToDo-HTML-Report-Editable-v1.3.ps1'; Optional = $true }
)
$objectArg = [ordered]@{ name = 'objectId'; type = 'object'; label = 'Object' }

$tools = @(
    @{
        id = 'import-entra'; group = 'Import'; label = 'Import Entra app registrations'
        description = 'Reads secrets and certificates of all app registrations and updates their expiry dates. The dashboard is rebuilt afterwards.'
        steps = @(@{ File = 'Settings\plugin\Import-EntraAppRegistrations-v1.3.ps1' }) + $rebuild
        summary = 'New objects to add|Nothing to change'
    }
    @{
        id = 'import-messagecenter'; group = 'Import'; label = 'Import Microsoft 365 Message Center'
        description = 'Reads Message Center advisories that have a deadline. The dashboard is rebuilt afterwards.'
        steps = @(@{ File = 'Settings\plugin\Import-M365MessageCenter-v1.1.3.ps1' }) + $rebuild
        summary = 'New objects to add|Nothing to change'
    }
    @{
        id = 'rebuild'; group = 'Dashboard'; label = 'Update dashboard now'
        description = 'Runs the report scripts, so saved changes show without waiting for the next scheduled run.'
        steps = $rebuild
        summary = 'Processed \d+ monitored'
    }
    @{
        id = 'alerts-whatif'; group = 'Alerts'; label = "Preview today's alerts"
        description = 'Runs the alert script with -WhatIf and shows which alerts would go out now. Nothing is sent.'
        steps = @(@{ File = 'psToDo-v1.3.ps1'; Args = @('-WhatIf') })
        summary = 'need an alert today'
    }
    @{
        id = 'test-message'; group = 'Alerts'; label = 'Send test message'
        description = "Sends one object's alert as a test, marked [TEST]. Leave the address empty to use the object's own recipients."
        args = @(
            $objectArg
            [ordered]@{ name = 'channel'; type = 'choice'; label = 'Channel'; options = @('mail', 'teams', 'both') }
            [ordered]@{ name = 'to'; type = 'email'; label = 'Send mail to (optional)'; optional = $true }
        )
        steps = @(@{ File = 'Settings\Tools\Send-TestMessage.ps1'; Args = @('-ObjectId', '{objectId}', '-Channel', '{channel}', '-To', '{to}') })
        summary = '^Result:'
    }
    @{
        id = 'resend-alert'; group = 'Alerts'; label = 'Send alert again'
        description = 'Clears the alert history of one object, so it alerts again on the next run of the alert script.'
        confirm = 'Clear the alert history for this object?'
        args = @($objectArg)
        steps = @(@{ File = 'Settings\Tools\Reset-AlertState.ps1'; Args = @('-ObjectId', '{objectId}') })
        summary = '^Result:'
    }
    @{
        id = 'health'; group = 'Health'; label = 'Health check'
        description = 'Checks the Graph settings and certificate, the network to Microsoft, and when the alert and report scripts last ran.'
        steps = @(@{ File = 'Settings\Tools\Test-Health.ps1' })
        summary = '^Result:'
    }
)

#------------------------------- Functions -------------------------------

function Write-JsonFile {
    param([string] $Path, $Object)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-Heartbeat {
    param([string] $Current = '')
    $catalog = foreach ($t in $tools) {
        [ordered]@{
            id = $t.id; group = $t.group; label = $t.label; description = $t.description
            confirm = "$($t.confirm)"; args = @($t.args | Where-Object { $_ })
        }
    }
    Write-JsonFile $heartbeat ([ordered]@{
        lastSeen = (Get-Date).ToString('o'); host = [Environment]::MachineName; user = [Environment]::UserName
        version = $runnerVersion; current = $Current; tools = @($catalog)
    })
}

function Get-RequestArgs {
    # Validated arguments for one tool, or a message when they are not valid
    param($Tool, $Request)
    $values = @{}
    foreach ($a in @($Tool.args | Where-Object { $_ })) {
        $v = ''
        if ($Request.args -and $Request.args.PSObject.Properties[$a.name]) { $v = "$($Request.args.($a.name))".Trim() }
        if ($v -eq '') {
            if ($a.optional) { $values[$a.name] = ''; continue }
            return "Missing value: $($a.label)."
        }
        switch ($a.type) {
            'object' {
                if ($v -notmatch '^[\w.\-]{1,64}$') { return 'The object id is not valid.' }
                $objects = @((Get-Content -Raw -Encoding UTF8 $dbPath | ConvertFrom-Json))
                if (-not ($objects | Where-Object { "$($_.id)" -eq $v })) { return "Object $v is not in monitorobjects.json." }
            }
            'choice' { if (@($a.options) -notcontains $v) { return "$($a.label) must be one of: $($a.options -join ', ')." } }
            'email'  { if ($v.Length -gt 254 -or $v -notmatch '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$') { return "$v is not a valid e-mail address." } }
            default  { return "Unknown argument type for $($a.name)." }
        }
        $values[$a.name] = $v
    }
    return $values
}

function Invoke-Step {
    # Runs one script in its own PowerShell process. Returns the exit code, or 'timeout'.
    param([string] $File, [string[]] $Arguments, [string] $LogFile, [datetime] $Deadline, [string] $RunId)

    $out = "$LogFile.out"; $err = "$LogFile.err"
    $quoted = foreach ($a in @($File) + @($Arguments)) { if ($a -match '[\s]' -or $a -eq '') { '"' + $a + '"' } else { $a } }
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + ($quoted -join ' ')
    $exe = (Get-Process -Id $PID).Path

    $p = Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $scriptRoot -NoNewWindow -PassThru `
             -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    $result = $null
    while (-not $p.WaitForExit(15000)) {
        Write-Heartbeat -Current $RunId
        if ((Get-Date) -gt $Deadline) {
            try { $p.Kill() } catch { }
            $result = 'timeout'
            break
        }
    }
    if ($null -eq $result) { $p.WaitForExit(); $result = $p.ExitCode }

    $text = ''
    if (Test-Path $out) { $text = [IO.File]::ReadAllText($out) ; Remove-Item $out -Force }
    if (Test-Path $err) {
        $e = [IO.File]::ReadAllText($err); Remove-Item $err -Force
        if ($e.Trim()) { $text += "`r`n--- errors ---`r`n$e" }
    }
    # Console colour codes
    $text = [regex]::Replace($text, "$([char]27)\[[0-9;]*m", '')
    Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
    return @{ Code = $result; Text = $text }
}

function Invoke-Request {
    param([IO.FileInfo] $File)

    $id = ($File.BaseName -replace '^\d+-', '')
    $run = [ordered]@{
        id = $id; tool = ''; label = ''; requestedBy = ''; requestedAt = ''; args = @{}
        startedAt = (Get-Date).ToString('o'); finishedAt = ''; status = 'running'; exitCode = $null; summary = ''
    }
    $runFile = [IO.Path]::Combine($runDir, "$id.json")
    $logFile = [IO.Path]::Combine($logDir, "$id.txt")

    $reject = {
        param($why)
        $run.status = 'rejected'; $run.summary = $why; $run.finishedAt = (Get-Date).ToString('o')
        Write-JsonFile $runFile $run
        Remove-Item -LiteralPath $File.FullName -Force
    }

    if ($id -notmatch '^[0-9a-f]{32}$') { Remove-Item -LiteralPath $File.FullName -Force; return }
    try { $request = Get-Content -Raw -Encoding UTF8 -LiteralPath $File.FullName | ConvertFrom-Json }
    catch { & $reject 'The request could not be read.'; return }

    $run.tool = "$($request.tool)"; $run.requestedBy = "$($request.requestedBy)"; $run.requestedAt = "$($request.requestedAt)"
    $tool = $tools | Where-Object { $_.id -eq $run.tool } | Select-Object -First 1
    if (-not $tool) { & $reject "Unknown tool '$($run.tool)'."; return }
    $run.label = $tool.label

    $values = Get-RequestArgs -Tool $tool -Request $request
    if ($values -is [string]) { & $reject $values; return }
    $run.args = $values

    Remove-Item -LiteralPath $File.FullName -Force
    Write-JsonFile $runFile $run
    Write-Heartbeat -Current $id

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $allText = ''
    $status = 'ok'
    foreach ($step in $tool.steps) {
        $path = [IO.Path]::Combine($scriptRoot, ($step.File -replace '\\', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path $path)) {
            if ($step.Optional) { continue }
            Add-Content -LiteralPath $logFile -Value "Script not found: $($step.File)" -Encoding UTF8
            $status = 'failed'; $run.summary = "Script not found: $($step.File)"; break
        }
        $stepArgs = @()
        $list = @($step.Args | Where-Object { $null -ne $_ })
        for ($i = 0; $i -lt $list.Count; $i++) {
            $a = $list[$i]
            if ($a -match '^\{(\w+)\}$') {
                $v = $values[$Matches[1]]
                # An empty optional value: drop it together with its switch
                if ([string]::IsNullOrEmpty($v)) { if ($stepArgs.Count) { $stepArgs = @($stepArgs | Select-Object -SkipLast 1) }; continue }
                $stepArgs += $v
            }
            else { $stepArgs += $a }
        }

        Add-Content -LiteralPath $logFile -Value "===== $($step.File) $($stepArgs -join ' ')  ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))" -Encoding UTF8
        $r = Invoke-Step -File $path -Arguments $stepArgs -LogFile $logFile -Deadline $deadline -RunId $id
        $allText += $r.Text
        $run.exitCode = $r.Code
        if ($r.Code -eq 'timeout') { $status = 'timeout'; $run.summary = "Stopped after $TimeoutMinutes minutes."; break }
        if ($r.Code -ne 0 -or $r.Text -match '(?m)^\s*ERROR on ') { $status = 'failed'; break }
    }

    if (-not $run.summary) {
        $lines = @($allText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $hit = $lines | Where-Object { $_ -match $tool.summary } | Select-Object -Last 1
        if ($status -eq 'failed') {
            $bad = $lines | Where-Object { $_ -match '^(ERROR|Result:|WARNING:)' -or $_ -match 'Exception|not found|Cannot ' } | Select-Object -Last 1
            if ($bad) { $hit = $bad }
        }
        if (-not $hit) { $hit = $lines | Select-Object -Last 1 }
        $run.summary = "$hit" -replace '^Result:\s*', ''
        if ($run.summary.Length -gt 240) { $run.summary = $run.summary.Substring(0, 240) }
    }
    $run.status = $status
    $run.finishedAt = (Get-Date).ToString('o')
    Write-JsonFile $runFile $run
}

#------------------------------- Run -------------------------------

# One instance at a time
$lock = $null
try { $lock = [IO.File]::Open([IO.Path]::Combine($QueuePath, 'runner.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Host 'Another instance is running.'; exit 0 }

try {
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

    # A run left as "running" was interrupted
    foreach ($f in Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File) {
        try {
            $old = Get-Content -Raw -Encoding UTF8 -LiteralPath $f.FullName | ConvertFrom-Json
            if ($old.status -eq 'running') {
                $old.status = 'failed'; $old.summary = 'Interrupted.'; $old.finishedAt = (Get-Date).ToString('o')
                Write-JsonFile $f.FullName $old
            }
        } catch { }
    }

    Write-Heartbeat
    $done = 0
    while ($true) {
        $next = Get-ChildItem -LiteralPath $requestDir -Filter '*.json' -File | Sort-Object Name | Select-Object -First 1
        if (-not $next) { break }
        Write-Host "Running $($next.Name)"
        try { Invoke-Request -File $next }
        catch {
            Write-Warning "Request $($next.Name) failed: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $next.FullName) { Remove-Item -LiteralPath $next.FullName -Force }
        }
        $done++
    }
    Write-Heartbeat

    # Keep the newest runs
    $old = @(Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepRuns)
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force
        $l = [IO.Path]::Combine($logDir, "$($f.BaseName).txt")
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force }
    }
    Write-Host "$done request(s) handled."
}
finally {
    if ($lock) { $lock.Dispose() }
}
