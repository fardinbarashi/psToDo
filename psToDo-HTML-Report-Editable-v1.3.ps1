<#
.DESCRIPTION
    SYSTEM REQUIREMENTS : Windows PowerShell 5.1 or PowerShell 7.x. No modules.

    psToDo - editable dashboard.

    Writes edit.html next to the normal status page. In the browser people can change
    the monitored objects directly - name, expire date, status, triggers, mail and Teams
    settings - add, duplicate and delete objects, and save straight back to
    monitorobjects.json.

    How saving works
      The page itself is static. It loads and saves through psToDo-api.ashx, a small
      ASP.NET handler in the same IIS folder (this script copies it there from
      Settings\Web on every run, so the handler is always the shipped version).
        - Everyone the site lets in can SEE the data.
        - Only members of the editors group (appSettings psToDo:EditorsGroup in web.config)
          can SAVE. Others get a read-only page.
        - Each save is checked against the version the page loaded. If the file changed
          in between (another editor, a plugin run) the save is refused and nothing is lost.
        - Each save takes a backup of monitorobjects.json first and is logged
          (Logs\psToDo-web-edits.log).
      One-time IIS setup (ASP.NET, editors group, rights): Install-help\Setup-IisReportEditor.ps1

    If the handler cannot be reached (page opened as a file, ASP.NET not installed) the page
    shows the snapshot embedded below, read-only, and says why.

    The normal report (psToDo-HTML-Report-v1.3.ps1) is unchanged and still writes
    index.html. Both can run side by side.

.EXAMPLE
    .\psToDo-HTML-Report-Editable-v1.3.ps1
    .\psToDo-HTML-Report-Editable-v1.3.ps1 -websitePath 'C:\inetpub\pstodo\edit.html'

.NOTES
    Author      : Fardin Barashi
    Title       : psToDo editable dashboard
    Version     : 1.4
    Release day : 2026-10-28
    Github Link : https://github.com/fardinbarashi
#>

#----------------------------------- Settings ------------------------------------------
[CmdletBinding()]
param(
    [string] $JsonPath = '',
    [string] $websitePath = '',
    [string] $backupWebsitePath = '',
    [string] $TemplatePath = '',
    [string] $ApiSourcePath = '',
    [string] $fileDate = (Get-Date -Format 'yyyy-MM-dd_HH.mm.ss')
)

# Resolve the folder this script lives in. $PSScriptRoot is empty when the code is
# run with F8 / "Run Selection" in ISE or VS Code. Fall back to the script path, then
# to the current folder.
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($JsonPath))          { $JsonPath          = "$scriptRoot\Files\db\monitorobjects.json" }
if ([string]::IsNullOrWhiteSpace($websitePath))       { $websitePath       = "$scriptRoot\Files\report\edit.html" }
if ([string]::IsNullOrWhiteSpace($backupWebsitePath)) { $backupWebsitePath = "$scriptRoot\Files\backup\psToDo-HTML-Report\edit-$($fileDate).html" }
if ([string]::IsNullOrWhiteSpace($TemplatePath))      { $TemplatePath      = "$scriptRoot\Settings\Web\edit-template.html" }
if ([string]::IsNullOrWhiteSpace($ApiSourcePath))     { $ApiSourcePath     = "$scriptRoot\Settings\Web\psToDo-api.ashx" }

# Full paths: the .NET file API used below resolves a relative path against the process
# folder, not the PowerShell location, so resolve every path through PowerShell first.
$JsonPath          = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
$websitePath       = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($websitePath)
$backupWebsitePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($backupWebsitePath)
$TemplatePath      = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TemplatePath)
$ApiSourcePath     = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ApiSourcePath)

$apiFileName = Split-Path $ApiSourcePath -Leaf

# Transcript
$ScriptName        = $MyInvocation.MyCommand.Name
$LogFileDate       = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
$TranScriptLogFile = "$scriptRoot\Logs\$ScriptName - $LogFileDate.txt"
Start-Transcript -Path $TranScriptLogFile -Force | Out-Null
Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
Write-Host '.. Starting TranScript'

$ErrorActionPreference = 'Stop'

#----------------------------------- Section 1 ------------------------------------------
$Section = 'Section 1 : Read monitorobjects.json'
try {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

    if (-not (Test-Path $JsonPath)) { throw "Cannot find the monitoring objects file: $JsonPath" }
    $raw = Get-Content -Raw -Encoding UTF8 $JsonPath
    if ($null -eq $raw) { $raw = '' }
    $raw = $raw.TrimStart([char]0xFEFF).Trim()
    if ($raw.Length -eq 0) { $raw = '[]' }

    # Validate only - the page gets the file text unchanged, so no field is ever lost.
    try   { $objects = @(($raw | ConvertFrom-Json)) }
    catch { throw "Failed to parse JSON in '$JsonPath': $($_.Exception.Message)" }
    Write-Host "- $($objects.Count) object(s) read." -ForegroundColor DarkGray

    # Base64 so nothing in the data (</script>, quotes, non-ASCII) can break the page.
    $snapshotB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($raw))

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
    Write-Host 'Stopping Transcript and Script!' -ForegroundColor Red
    Stop-Transcript
    exit 1
}

#----------------------------------- Section 2 ------------------------------------------
$Section = 'Section 2 : Build edit.html from the template'
try {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

    if (-not (Test-Path $TemplatePath)) { throw "Template not found: $TemplatePath" }
    $template = Get-Content -Raw -Encoding UTF8 $TemplatePath

    foreach ($token in '__PSTODO_SNAPSHOT_B64__', '__PSTODO_API_URL__', '__PSTODO_GENERATED__') {
        if ($template.IndexOf($token) -lt 0) { throw "The template is missing the placeholder $token." }
    }

    # .Replace (literal), not -replace (regex): the data must never be read as a pattern.
    $html = $template.Replace('__PSTODO_SNAPSHOT_B64__', $snapshotB64)
    $html = $html.Replace('__PSTODO_API_URL__', $apiFileName)
    $html = $html.Replace('__PSTODO_GENERATED__', (Get-Date -Format 'yyyy-MM-dd HH:mm'))

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
    Write-Host 'Stopping Transcript and Script!' -ForegroundColor Red
    Stop-Transcript
    exit 1
}

#----------------------------------- Section 3 ------------------------------------------
$Section = 'Section 3 : Write edit.html, the save handler and a backup'
try {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "Start $Section ... 0%" -ForegroundColor Yellow

    $outDir = Split-Path $websitePath -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    # UTF-8 without BOM for the page (the <meta charset> declares it).
    [System.IO.File]::WriteAllText($websitePath, $html, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "- Page written: $websitePath" -ForegroundColor Green

    $backupDir = Split-Path $backupWebsitePath -Parent
    if ($backupDir -and -not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    Copy-Item -Path $websitePath -Destination $backupWebsitePath -Force
    Write-Host "- Backup written: $backupWebsitePath" -ForegroundColor DarkGray

    # Keep the handler next to the page identical to the shipped one.
    if (Test-Path $ApiSourcePath) {
        $apiTarget = Join-Path $outDir $apiFileName
        $same = $false
        if (Test-Path $apiTarget) {
            $same = (Get-FileHash $ApiSourcePath -Algorithm SHA256).Hash -eq (Get-FileHash $apiTarget -Algorithm SHA256).Hash
        }
        if (-not $same) {
            Copy-Item -Path $ApiSourcePath -Destination $apiTarget -Force
            Write-Host "- Save handler updated: $apiTarget" -ForegroundColor Green
        }
        else { Write-Host "- Save handler is up to date: $apiTarget" -ForegroundColor DarkGray }
    }
    else { Write-Warning "Save handler not found at $ApiSourcePath - the page will open read-only (snapshot)." }

    # Friendly hints if the one-time IIS setup has not been done for this folder.
    $webConfig = Join-Path $outDir 'web.config'
    if (-not (Test-Path $webConfig)) {
        Write-Warning "No web.config in $outDir. Run Install-help\Setup-IisReportSecurity.ps1 and Install-help\Setup-IisReportEditor.ps1."
    }
    else {
        $wc = Get-Content -Raw -Encoding UTF8 $webConfig
        if ($wc -notmatch 'psToDo:EditorsGroup') {
            Write-Warning "web.config has no editors group: the page will be read-only for everyone. Run Install-help\Setup-IisReportEditor.ps1 to enable saving."
        }
        if ($wc -match 'allowUnlisted="false"' -and $wc -notmatch '"\.ashx"') {
            Write-Warning "web.config request filtering does not allow .ashx: the page cannot reach the save handler. Run Install-help\Setup-IisReportEditor.ps1."
        }
    }

    Write-Host "Start $Section ... 100%" -ForegroundColor Green
    Write-Host ''
}
catch {
    Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Write-Host "ERROR on $Section" -ForegroundColor Red
    Write-Host 'ERROR:' $_.Exception.Message
    Write-Host 'Stopping Transcript and Script!' -ForegroundColor Red
    Stop-Transcript
    exit 1
}

#----------------------------------- End Script ------------------------------------------
Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
Write-Host 'Script finished.' -ForegroundColor Green
Stop-Transcript
