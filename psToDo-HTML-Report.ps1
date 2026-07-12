
<#
.DESCRIPTION
    SYSTEM REQUIREMENTS : This script requires PowerShell 5.1 or later and the following modules.

    This script is designed to read the monitorobjects.json file and generate a HTML report based on the data. 
    The report provides a visual representation of the status of monitored objects, 
    indicating whether they are expired, critical, warning, or ok based on their defined triggers.
    
    Reads monitorobjects.json and writes a HTML report to web-servers
    Change the $websitePath parameters to write to a web server's document root.

    Status is derived from the object's own triggers, sorted ascending.
    The smallest trigger is the most urgent because it sits closest to expiry.
        daysLeft < 0            -> expired
        daysLeft <= datetrigger1  -> critical
        daysLeft <= datetrigger2  -> warning
        otherwise <= datetrigger3  -> > ok

.EXAMPLE
    .\CalenderReminderHtmlReport.ps1 -Open

.NOTES
    Author : Fardin Barashi
    Title : CalenderReminderHtmlReport
    Version : 1.0
      Release day : 2026-06-22
      Github Link  : https://github.com/fardinbarashi

.NEWS
 
#>

#----------------------------------- Settings ------------------------------------------
[CmdletBinding()]
param(
    [string] $JsonPath   = "$PSScriptRoot\Files\db\monitorobjects.json",
    [string] $ScriptSettingsPath   = "$PSScriptRoot\Settings\Config\ScriptSettings.json",
    [string] $DateFormat = 'yyyy-MM-dd',
    [string] $fileDate = (Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'),
    [string] $websitePath = "$PSScriptRoot\Files\report\index.html",
    [string] $backupWebsitePath = "$PSScriptRoot\Files\backup\psToDo-HTML-Report\index-$($fileDate).html",
    [string[]] $TriggerKeys = @('1dateTrigger', '2dateTrigger', '3dateTrigger')
)

# Transcript
$ScriptName = $MyInvocation.MyCommand.Name
$LogFileDate = (Get-Date -Format yyyy/MM/dd/HH.mm.ss)
$TranScriptLogFile = "$PSScriptRoot\Logs\$ScriptName - $LogFileDate.Txt" 
$StartTranscript = Start-Transcript -Path $TranScriptLogFile -Force
Get-Date -Format "yyyy/MM/dd HH:mm:ss"
Write-Host ".. Starting TranScript"

# Error-Settings
$ErrorActionPreference = 'Continue'

#----------------------------------- Functionlist ------------------------------------------

#------------------------------- Functions List -------------------------------

Write-Host 'Checking required Functions...' -ForegroundColor Yellow

$functionFolder = "$PSScriptRoot\\Settings\Functions\psToDo-HtmlReport"
if (-not (Test-Path $functionFolder)) { throw "Function folder not found: $functionFolder"}
$functionFiles = Get-ChildItem -Path $functionFolder -Filter '*.ps1' -File
if (-not $functionFiles) { throw "No .ps1 files found in $functionFolder"}

foreach ($file in $functionFiles) 
{ 
 try {
        . $file.FullName
        Write-Host "- Loaded $($file.Name)" -ForegroundColor DarkGray
    }
catch { throw "Failed to load function file '$($file.Name)': $($_.Exception.Message)" }
}
Write-Host "All $($functionFiles.Count) function file(s) loaded." -ForegroundColor Green

Initialize-RequiredModules -Modules @('Microsoft.Graph.Authentication')

Write-host ""


#----------------------------------- Start Script ------------------------------------------
# Section 1 : Read monitorobjects.json
$Section = "Section 1 : Read monitorobjects.json"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
if (-not (Test-Path $JsonPath)) { throw "Cannot find the monitoring objects file: $JsonPath"}
try { 
      $monitoringObjects = Get-Content -Raw -Encoding UTF8 $JsonPath | ConvertFrom-Json 
      
         Write-host ""
         $scriptSettings = Get-Content -Raw -Encoding UTF8 $ScriptSettingsPath | ConvertFrom-Json
         Write-Host "$scriptSettings.Version" -ForegroundColor Green
    }
catch { throw "Failed to parse JSON in '$JsonPath': $($_.Exception.Message)"}
if (-not $monitoringObjects) { throw 'The monitoring objects file is empty or contains no objects.' }
Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------
# Section 2 : Build HTML data
$Section = "Section 2 : Build HTML data"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
$today       = (Get-Date).Date
$rows        = [System.Collections.Generic.List[object]]::new()
$invalid     = [System.Collections.Generic.List[object]]::new()
$placeholder = 0


foreach ($object in $monitoringObjects) {

    $label = "Object $($object.id) - $($object.name)"

    if ([string]::IsNullOrWhiteSpace($object.expireDate)) {
        Write-Warning "$label is missing expireDate - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = 'missing expireDate' })
        continue
    }

    try {
        $expireDate = [datetime]::ParseExact(
            $object.expireDate, $DateFormat, [cultureinfo]::InvariantCulture
        ).Date
    }
    catch {
        Write-Warning "$label has an invalid expireDate: '$($object.expireDate)' (expected $DateFormat) - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = "bad expireDate '$($object.expireDate)'" })
        continue
    }

    $daysLeft = ($expireDate - $today).Days

    # Quoted access: the keys start with a digit
    $rawTriggers = foreach ($key in $TriggerKeys) { $object.$key }

    [int[]] $triggers = $rawTriggers |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { [int]$_ } |
                        Sort-Object -Unique

    if (-not $triggers) {
        Write-Warning "$label has no valid date triggers - skipping."
        $invalid.Add([pscustomobject]@{ id = "$($object.id)"; name = "$($object.name)"; reason = 'no date triggers' })
        continue
    }

    $declared = @($rawTriggers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]$_ })
    if (($declared -join ',') -ne (($declared | Sort-Object) -join ',')) { Write-Warning "$label declares triggers out of order ($($declared -join ', ')). Sorted automatically."}
    if ($triggers.Count -lt 3) { Write-Warning "$label defines only $($triggers.Count) unique trigger(s). Levels above that collapse into 'ok'."}

    $urgency = Get-Urgency -DaysLeft $daysLeft -Triggers $triggers

    # The window currently in effect, or $null when the object is outside all of them
    $hit = $triggers | Where-Object { $daysLeft -le $_ -and $daysLeft -ge 0 } | Select-Object -First 1
    $mailOn  = Test-NotifyFlag $object.notifyMethodbyMail
    $teamsOn = Test-NotifyFlag $object.notifyMethodbyTeams
    if (-not $mailOn  -and "$($object.notifyMethodbyMail)"  -match 'True or null') { $placeholder++ }
    if (-not $teamsOn -and "$($object.notifyMethodbyTeams)" -match 'True or null') { $placeholder++ }

    $levels   = @('critical', 'warning', 'ok')
    $schedule = for ($i = 0; $i -lt $triggers.Count; $i++) {
        $t = $triggers[$i]
        [pscustomobject]@{
            trigger = $t
            level   = if ($i -lt $levels.Count) { $levels[$i] } else { 'ok' }
            date    = $expireDate.AddDays(-$t).ToString('yyyy-MM-dd')
            passed  = ($expireDate.AddDays(-$t) -le $today)
        }
    }

    $rows.Add([pscustomobject]@{
        id             = "$($object.id)"
        name           = "$($object.name)"
        servername     = "$($object.servername)"
        template       = "$($object.template)"
        environment    = "$($object.environment)"
        action         = "$($object.description)"
        expireDate     = $expireDate.ToString('yyyy-MM-dd')
        daysLeft       = $daysLeft
        trigger        = $hit
        allTriggers    = @($triggers)
        maxTrigger     = $triggers[-1]
        schedule       = @($schedule | Sort-Object trigger -Descending)
        urgency        = $urgency

        mailOn         = $mailOn
        mailSender     = "$($object.mail.mailSender)"
        mailSubject    = "$($object.mail.mailSubject)"
        mailBody       = "$($object.mail.mailBody)"
        mailRecipients = @($object.mail.mailRecipients)

        teamsOn        = $teamsOn
        teamWebhookUrl = "$($object.teams.teamWebhookUrl)"
        teamSubject    = "$($object.teams.teamSubject)"
        teamBody       = "$($object.teams.teamBody)"
        
    })
}

if (-not $rows.Count) { throw 'No valid objects to report on. Check the warnings above.'}
Write-Host "Processed $($rows.Count) object(s)." -ForegroundColor Green

$rows | Group-Object urgency | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.Name, $_.Count) }
if ($invalid.Count) { Write-Warning "$($invalid.Count) object(s) were skipped and are NOT being monitored." }
if ($placeholder) { Write-Warning "$placeholder notify field(s) still hold the placeholder string. Replace them with true / false." }

#------------------------------- Embed as JSON -------------------------------

$dataJson = $rows | ConvertTo-Json -Depth 6 -Compress
if ($rows.Count -eq 1) { $dataJson = "[$dataJson]" }

$invalidJson = if ($invalid.Count) {
    $j = $invalid | ConvertTo-Json -Depth 3 -Compress
    if ($invalid.Count -eq 1) { "[$j]" } else { $j }
} else { '[]' }

$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$sourceEsc = [System.Net.WebUtility]::HtmlEncode($JsonPath)

Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------
# Section 3 : Create HTML-Report file
$Section = "Section 3 : Create HTML-Report file"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title> PsToDo - Calender Reminder - status</title>
<style>
  :root {
    --bg: #14171a; --panel: #1b1f23; --panel-2: #21262b;
    --line: #2d343a; --line-2: #3a434a;
    --fg: #e6e9ea; --muted: #8c979e; --dim: #667079;
    --green: #4ec98f; --green-bg: #16281f; --green-line: #24523c;
    --expired: #ff6b6b; --critical: #ff8a5b; --warning: #f0b429; --ok: #4ec98f;
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 2rem; background: var(--bg); color: var(--fg);
         font: 14px/1.6 "Segoe UI", system-ui, sans-serif; }
  h1 { font-size: 22px; font-weight: 500; margin: 0 0 4px; display: flex; align-items: center; gap: 10px; }
  h1::before { content: ''; width: 8px; height: 22px; background: var(--green); border-radius: 2px; }
  .meta { color: var(--dim); font-size: 13px; margin-bottom: 24px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
           gap: 12px; margin-bottom: 24px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
          padding: 14px 16px; cursor: pointer; transition: border-color .12s, background .12s; }
  .card:hover { border-color: var(--line-2); }
  .card.active { border-color: var(--green); background: var(--green-bg); }
  .card .n { font-size: 26px; font-weight: 500; line-height: 1.2; }
  .card .l { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
  .card .h { font-size: 11px; color: var(--dim); margin-top: 2px; }
  .card.expired .n { color: var(--expired); }
  .card.critical .n { color: var(--critical); }
  .card.warning .n { color: var(--warning); }
  .card.ok .n { color: var(--ok); }

  .controls { display: flex; gap: 10px; align-items: center; margin-bottom: 12px; flex-wrap: wrap; }
  input[type=search] { width: 260px; max-width: 100%; padding: 8px 12px; color: var(--fg);
    border: 1px solid var(--line); border-radius: 6px; font-size: 14px; background: var(--panel); }
  input[type=search]::placeholder { color: var(--dim); }
  input[type=search]:focus { outline: none; border-color: var(--green); }

  button { padding: 8px 16px; border-radius: 6px; font-size: 14px; cursor: pointer;
           border: 1px solid var(--line); background: var(--panel); color: var(--fg);
           transition: border-color .12s, background .12s; }
  button:hover { border-color: var(--line-2); background: var(--panel-2); }
  button.primary { background: #1f6feb; border-color: #1f6feb; color: #fff; }
  button.primary:hover { background: #1a5fd0; border-color: #1a5fd0; }
  .count { margin-left: auto; font-size: 13px; color: var(--dim); }

  table { width: 100%; border-collapse: collapse; background: var(--panel);
          border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  th { text-align: left; font-weight: 500; font-size: 12px; color: var(--muted);
       text-transform: uppercase; letter-spacing: .04em; padding: 10px 12px;
       border-bottom: 1px solid var(--line); cursor: pointer; user-select: none;
       white-space: nowrap; background: var(--panel-2); }
  th:hover { color: var(--green); }
  th .arrow { color: var(--green); font-size: 10px; margin-left: 4px; }
  td { padding: 10px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tbody tr.row:hover td { background: var(--panel-2); }
  tbody tr.row { cursor: pointer; }
  .id { color: var(--dim); }
  .name { font-weight: 500; }
  .date, .days, .trigger { white-space: nowrap; }
  .dim { color: var(--dim); }
  .chev { display: inline-block; width: 12px; color: var(--dim); transition: transform .12s; }
  tr.open .chev { transform: rotate(90deg); color: var(--green); }

  .badge { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 12px; white-space: nowrap; }
  .b-expired { background: #3a1c1c; color: #ff8f8f; }
  .b-critical { background: #3a2418; color: #ffa87f; }
  .b-warning { background: #382c12; color: #f5c85a; }
  .b-ok { background: var(--green-bg); color: var(--green); }

  .pill { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px;
          border: 1px solid var(--line-2); color: var(--dim); margin-right: 4px; white-space: nowrap; }
  .pill.on { border-color: var(--green-line); background: var(--green-bg); color: var(--green); }

  tr.detail td { background: #101316; border-bottom: 1px solid var(--line); padding: 0; }
  .panel { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
           gap: 20px; padding: 18px 22px 20px 34px; }
  .block h4 { margin: 0 0 8px; font-size: 12px; font-weight: 500; color: var(--muted);
              text-transform: uppercase; letter-spacing: .04em; }
  .block.off h4 { color: var(--dim); }
  .kv { display: grid; grid-template-columns: 96px 1fr; gap: 3px 12px; font-size: 13px; }
  .kv dt { color: var(--dim); }
  .kv dd { margin: 0; word-break: break-word; }
  .mono { font-family: ui-monospace, Consolas, monospace; font-size: 12px; }
  .off .kv dd { color: var(--dim); }

  .sched { list-style: none; margin: 0; padding: 0; font-size: 13px; }
  .sched li { display: flex; justify-content: space-between; gap: 12px; padding: 3px 0;
              border-bottom: 1px solid var(--line); }
  .sched li:last-child { border-bottom: none; }
  .sched .lvl { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; margin-left: 8px; }
  .sched .passed { color: var(--dim); }
  .sched .passed .d { text-decoration: line-through; }
  .lvl-critical { color: var(--critical); }
  .lvl-warning { color: var(--warning); }
  .lvl-ok { color: var(--ok); }

  .msg { padding: 16px; background: var(--panel); border: 1px solid var(--line);
         border-radius: 8px; color: var(--muted); }
  .warn { border-color: #5a4a1a; background: #241f10; color: #f5c85a; margin-bottom: 16px; }
  .bad { border-color: #5a2020; background: #241010; color: #ff8f8f; margin-bottom: 16px; }
  footer { margin-top: 20px; color: var(--dim); font-size: 12px; }
  @media (max-width: 1000px) { body { padding: 1rem; } }
</style>
</head>
<body>

<h1>PsToDo - Calender Reminder </h1>
<div class="meta">Generated $generated &middot; source: $sourceEsc &middot; $($rows.Count) monitored objects</div>

<div class="cards" id="cards"></div>

<div class="controls">
  <input type="search" id="filter" placeholder="Filter by name, server, recipient...">
  <button class="primary" id="reload">Reload</button>
  <button id="reset">Reset filters</button>
  <span class="count" id="count"></span>
</div>

<div id="mount"></div>

<footer>Status follows each object's own triggers: the smallest trigger is critical, the middle one is warning, anything beyond is ok. Click a row for its mail and Teams configuration.</footer>

<script id="data" type="application/json">$dataJson</script>
<script id="invalid" type="application/json">$invalidJson</script>

<script>
const DATA    = JSON.parse(document.getElementById('data').textContent);
const INVALID = JSON.parse(document.getElementById('invalid').textContent);

const URGENCY = [
  { key: 'expired',  label: 'Expired',  hint: 'Past the expiry date' },
  { key: 'critical', label: 'Critical', hint: 'Inside Datetrigger 1' },
  { key: 'warning',  label: 'Warning',  hint: 'Inside Datetrigger 2' },
  { key: 'ok',       label: 'Ok',       hint: 'Inside Datetrigger 3 or beyond' }
];

const DEFAULTS = { filter: '', urgency: null, sortKey: 'daysLeft', sortDir: 1 };
let state = { ...DEFAULTS };
let openRows = new Set();

const esc = s => { const d = document.createElement('div'); d.textContent = s ?? ''; return d.innerHTML; };

function daysText(n) {
  if (n < 0)   return Math.abs(n) + (Math.abs(n) === 1 ? ' day ago' : ' days ago');
  if (n === 0) return 'expires today';
  if (n === 1) return '1 day left';
  return n + ' days left';
}

function renderCards() {
  document.getElementById('cards').innerHTML = URGENCY.map(u => {
    const n = DATA.filter(r => r.urgency === u.key).length;
    const on = state.urgency === u.key ? ' active' : '';
    return '<div class="card ' + u.key + on + '" data-u="' + u.key + '">' +
           '<div class="n">' + n + '</div>' +
           '<div class="l">' + u.label + '</div>' +
           '<div class="h">' + u.hint + '</div></div>';
  }).join('');
}

function searchBlob(r) {
  return [r.id, r.name, r.servername, r.template, r.environment, r.action,
          r.mailSender, r.mailSubject, (r.mailRecipients || []).join(' '),
          r.teamSubject, r.teamChannelId].join(' ').toLowerCase();
}

function visibleRows() {
  const q = state.filter.toLowerCase();
  let view = DATA.slice();
  if (state.urgency) view = view.filter(r => r.urgency === state.urgency);
  if (q) view = view.filter(r => searchBlob(r).includes(q));

  return view.sort((a, b) => {
    const x = a[state.sortKey], y = b[state.sortKey];
    if (typeof x === 'number' && typeof y === 'number') return state.sortDir * (x - y);
    return state.sortDir * String(x ?? '').localeCompare(String(y ?? ''));
  });
}

const COLS = [
  ['', ''], ['id','Id'], ['name','Name'], ['servername','Server'],
  ['environment','Environment'], ['expireDate','Expires'], ['daysLeft','Days left'],
  ['trigger','Window'], ['urgency','Status'], ['notify','Notify']
];

function scheduleHtml(r) {
  const items = (r.schedule || []).map(s =>
    '<li class="' + (s.passed ? 'passed' : '') + '">' +
      '<span>' + s.trigger + '-day' +
        '<span class="lvl lvl-' + s.level + '">' + s.level + '</span></span>' +
      '<span class="d">' + esc(s.date) + '</span>' +
    '</li>').join('');
  return '<ul class="sched">' + items + '</ul>';
}

function detailHtml(r) {
  const recipients = (r.mailRecipients || []).length
    ? (r.mailRecipients || []).map(esc).join('<br>')
    : '<span class="dim">none</span>';

  return '<tr class="detail"><td colspan="' + COLS.length + '"><div class="panel">' +

    '<div class="block' + (r.mailOn ? '' : ' off') + '"><h4>Mail ' +
      (r.mailOn ? '<span class="pill on">on</span>' : '<span class="pill">off</span>') + '</h4>' +
      '<dl class="kv">' +
        '<dt>Sender</dt><dd>' + esc(r.mailSender) + '</dd>' +
        '<dt>Recipients</dt><dd>' + recipients + '</dd>' +
        '<dt>Subject</dt><dd>' + esc(r.mailSubject) + '</dd>' +
        '<dt>Body</dt><dd>' + esc(r.mailBody) + '</dd>' +
      '</dl></div>' +

    '<div class="block' + (r.teamsOn ? '' : ' off') + '"><h4>Teams ' +
      (r.teamsOn ? '<span class="pill on">on</span>' : '<span class="pill">off</span>') + '</h4>' +
      '<dl class="kv">' +
       '<dt>Team Webhook</dt><dd class="mono">' + esc(r.teamWebhookUrl) + '</dd>' +
        '<dt>Subject</dt><dd>' + esc(r.teamSubject) + '</dd>' +
        '<dt>Body</dt><dd>' + esc(r.teamBody) + '</dd>' +
      '</dl></div>' +

    '<div class="block"><h4>Alert schedule</h4>' + scheduleHtml(r) + '</div>' +

    '<div class="block"><h4>Action required</h4>' +
      '<div>' + esc(r.action) + '</div>' +
      '<dl class="kv" style="margin-top:10px">' +
        '<dt>Template</dt><dd>' + esc(r.template) + '</dd>' +
        '<dt>Triggers</dt><dd>' + (r.allTriggers || []).join(', ') + '</dd>' +
      '</dl></div>' +

  '</div></td></tr>';
}

function notifyCell(r) {
  return '<span class="pill' + (r.mailOn  ? ' on' : '') + '">Mail</span>' +
         '<span class="pill' + (r.teamsOn ? ' on' : '') + '">Teams</span>';
}

function windowCell(r) {
  if (r.trigger !== null) return r.trigger + '-day';
  return '<span class="dim">&gt; ' + r.maxTrigger + '-day</span>';
}

function render() {
  renderCards();

  const view = visibleRows();
  document.getElementById('count').textContent =
    view.length === DATA.length ? DATA.length + ' objects'
                                : view.length + ' of ' + DATA.length + ' objects';

  let banners = '';

  if (INVALID.length) {
    banners += '<div class="msg bad"><b>' + INVALID.length + ' object(s) are NOT monitored.</b><br>' +
      INVALID.map(o => esc(o.id) + ' - ' + esc(o.name) + ': ' + esc(o.reason)).join('<br>') + '</div>';
  }

  const noChannel = DATA.filter(r => !r.mailOn && !r.teamsOn).length;
  if (noChannel) {
    banners += '<div class="msg warn">' + noChannel + ' object(s) have no notification channel enabled. ' +
      'Set <b>notifyMethodbyMail</b> and <b>notifyMethodbyTeams</b> to real booleans in the JSON.</div>';
  }

  if (!view.length) {
    document.getElementById('mount').innerHTML = banners + '<div class="msg">No objects match the current filter.</div>';
    return;
  }

  const head = COLS.map(c => {
    if (!c[0]) return '<th style="width:28px"></th>';
    const arrow = state.sortKey === c[0]
      ? '<span class="arrow">' + (state.sortDir === 1 ? '&#9650;' : '&#9660;') + '</span>' : '';
    return '<th data-k="' + c[0] + '">' + c[1] + arrow + '</th>';
  }).join('');

  const body = view.map(r => {
    const isOpen = openRows.has(r.id);
    const main =
      '<tr class="row' + (isOpen ? ' open' : '') + '" data-id="' + esc(r.id) + '">' +
        '<td><span class="chev">&#9654;</span></td>' +
        '<td class="id">' + esc(r.id) + '</td>' +
        '<td class="name">' + esc(r.name) + '</td>' +
        '<td>' + esc(r.servername) + '</td>' +
        '<td>' + esc(r.environment) + '</td>' +
        '<td class="date">' + esc(r.expireDate) + '</td>' +
        '<td class="days">' + daysText(r.daysLeft) + '</td>' +
        '<td class="trigger">' + windowCell(r) + '</td>' +
        '<td><span class="badge b-' + r.urgency + '">' + r.urgency + '</span></td>' +
        '<td>' + notifyCell(r) + '</td>' +
      '</tr>';
    return main + (isOpen ? detailHtml(r) : '');
  }).join('');

  document.getElementById('mount').innerHTML =
    banners + '<table><thead><tr>' + head + '</tr></thead><tbody>' + body + '</tbody></table>';
}

document.getElementById('filter').addEventListener('input', e => {
  state.filter = e.target.value;
  render();
});

document.getElementById('reload').addEventListener('click', () => location.reload());

document.getElementById('reset').addEventListener('click', () => {
  state = { ...DEFAULTS };
  openRows.clear();
  document.getElementById('filter').value = '';
  render();
});

document.getElementById('cards').addEventListener('click', e => {
  const card = e.target.closest('.card');
  if (!card) return;
  state.urgency = (state.urgency === card.dataset.u) ? null : card.dataset.u;
  render();
});

document.getElementById('mount').addEventListener('click', e => {
  const th = e.target.closest('th');
  if (th && th.dataset.k) {
    state.sortDir = (th.dataset.k === state.sortKey) ? -state.sortDir : 1;
    state.sortKey = th.dataset.k;
    render();
    return;
  }
  const tr = e.target.closest('tr.row');
  if (tr) {
    const id = tr.dataset.id;
    openRows.has(id) ? openRows.delete(id) : openRows.add(id);
    render();
  }
});

render();
</script>

</body>
</html>
"@

Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#-----------------------------------------------------------------------------

# Section 4 : Export html file and create backups
$Section = "Section 4 : Export HTML-Report file"
Try
{ # Start Try, $Section
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host $Section... "0%" -ForegroundColor Yellow

 # Run Query
$outDir = Split-Path $websitePath -Parent
if ($outDir -and -not (Test-Path $outDir)) {New-Item -Path $outDir -ItemType Directory -Force | Out-Null}
$html | Set-Content -Path $websitePath -Encoding UTF8 -Verbose
Write-Host "Report written to $websitePath" -ForegroundColor Green
get-childitem -Path $websitePath -Force -File | Copy-Item -Destination $backupWebsitePath -Force -Verbose 

Write-Host "Report written to $backupWebsitePath" -ForegroundColor Green
Write-Host "HTML file written to $websitePath" -ForegroundColor Green



Write-Host $Section... "100%" -ForegroundColor Green
Write-Host ""
} # End Try

Catch
{ # Start Catch
 Get-Date -Format "yyyy/MM/dd HH:mm:ss"
 Write-Host "ERROR on $Section" -ForegroundColor Red
 Write-Warning $Error[0]
 Write-Host "Stopping Transcript and Script!" -ForegroundColor Red
 Stop-Transcript
 Exit
} # End Catch

#----------------------------------- End Script ------------------------------------------
Stop-Transcript