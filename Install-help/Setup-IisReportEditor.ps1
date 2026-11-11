<#
System requirements
    Windows PowerShell 5.1 or PowerShell 7 (run as Administrator) on the IIS server.
    Run Setup-IisReportSecurity.ps1 FIRST: this script builds on its site and web.config.

psToDo setup : Setup-IisReportEditor
    Author  : Fardin Barashi
    Purpose : Members of one AD group can save from edit.html. Everyone else who can
              open the site gets a read-only page.

What it does
    1. Installs ASP.NET 4.x for IIS if missing.
    2. Sets the app pool to .NET CLR v4.0.
    3. Looks the editors group up in AD.
    4. web.config: allows the editors group, allows .ashx, writes psToDo:EditorsGroup,
       psToDo:DbPath, psToDo:BackupFolder, psToDo:EditLog and psToDo:QueueFolder (backup first).
    5. NTFS: app pool Modify on the db, backup, log and queue folders; editors Read on
       the report folder.
    6. Copies psToDo-api.ashx into the report folder if missing.
    Safe to re-run.

    Keep the editors group small: editors decide who gets alert mail and which Teams
    channel is used. Saves are logged in Logs\psToDo-web-edits.log.

Parameters
    -SiteName      IIS site name. Default: 'psToDo'
    -AppPath       Sub-application under the site, e.g. 'pstodo' (empty = the site itself)
    -EditorsGroup  AD security group allowed to save. Default: 'psToDo-Editors'
    -PhysicalPath  Folder that holds edit.html. Default: <psToDo>\Files\report
    -DbPath        monitorobjects.json. Default: <psToDo>\Files\db\monitorobjects.json
    -BackupFolder  Default: <psToDo>\Files\backup\psToDo
    -LogFolder     Default: <psToDo>\Logs
    -QueueFolder   Tools requests. Default: <psToDo>\Files\queue
    -SkipFeatureInstall, -SkipNtfs

Examples
    .\Setup-IisReportEditor.ps1 -WhatIf
    .\Setup-IisReportEditor.ps1 -SiteName psToDo -EditorsGroup 'CONTOSO\psToDo-Editors'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SiteName = 'psToDo',
    [string] $AppPath,
    [string] $EditorsGroup = 'psToDo-Editors',
    [string] $PhysicalPath,
    [string] $DbPath,
    [string] $BackupFolder,
    [string] $LogFolder,
    [string] $QueueFolder,
    [switch] $SkipFeatureInstall,
    [switch] $SkipNtfs
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($PhysicalPath)) { $PhysicalPath = Join-Path $repoRoot 'Files\report' }
if ([string]::IsNullOrWhiteSpace($DbPath))       { $DbPath       = Join-Path $repoRoot 'Files\db\monitorobjects.json' }
if ([string]::IsNullOrWhiteSpace($BackupFolder)) { $BackupFolder = Join-Path $repoRoot 'Files\backup\psToDo' }
if ([string]::IsNullOrWhiteSpace($LogFolder))    { $LogFolder    = Join-Path $repoRoot 'Logs' }
if ([string]::IsNullOrWhiteSpace($QueueFolder))  { $QueueFolder  = Join-Path $repoRoot 'Files\queue' }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

#------------------------------- 1. ASP.NET -------------------------------

Write-Host '1. ASP.NET 4.x for IIS' -ForegroundColor Cyan
if ($SkipFeatureInstall) {
    Write-Host '   Skipped (-SkipFeatureInstall).' -ForegroundColor DarkGray
}
elseif (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    $f = Get-WindowsFeature -Name 'Web-Asp-Net45'
    if ($f.Installed) { Write-Host '   Web-Asp-Net45 already installed.' -ForegroundColor DarkGray }
    elseif ($PSCmdlet.ShouldProcess('Web-Asp-Net45', 'Install-WindowsFeature')) {
        Install-WindowsFeature -Name 'Web-Asp-Net45' | Out-Null
        Write-Host '   Installed Web-Asp-Net45.' -ForegroundColor Green
    }
}
else {
    $f = Get-WindowsOptionalFeature -Online -FeatureName 'IIS-ASPNET45'
    if ($f.State -eq 'Enabled') { Write-Host '   IIS-ASPNET45 already enabled.' -ForegroundColor DarkGray }
    elseif ($PSCmdlet.ShouldProcess('IIS-ASPNET45', 'Enable-WindowsOptionalFeature')) {
        Enable-WindowsOptionalFeature -Online -FeatureName 'IIS-ASPNET45' -All -NoRestart | Out-Null
        Write-Host '   Enabled IIS-ASPNET45.' -ForegroundColor Green
    }
}

Import-Module WebAdministration -ErrorAction Stop

#------------------------------- 2. Site and app pool -------------------------------

Write-Host '2. Site and app pool' -ForegroundColor Cyan
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    throw "IIS site '$SiteName' not found. Run Setup-IisReportSecurity.ps1 first (it can create the site with -CreateSite)."
}
$location = if ([string]::IsNullOrWhiteSpace($AppPath)) { $SiteName } else { "$SiteName/$($AppPath.Trim('/'))" }
$pool = if ([string]::IsNullOrWhiteSpace($AppPath)) { (Get-Item "IIS:\Sites\$SiteName").applicationPool }
        else { (Get-WebApplication -Site $SiteName -Name $AppPath.Trim('/')).applicationPool }
if (-not $pool) { throw "Could not find the app pool of '$location'." }

$clr = (Get-ItemProperty "IIS:\AppPools\$pool").managedRuntimeVersion
if ($clr -eq 'v4.0') { Write-Host "   App pool '$pool' runs .NET CLR v4.0." -ForegroundColor DarkGray }
elseif ($PSCmdlet.ShouldProcess($pool, "Set managedRuntimeVersion v4.0 (was '$clr')")) {
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value 'v4.0'
    Write-Host "   App pool '$pool' set to .NET CLR v4.0 (was '$clr')." -ForegroundColor Green
}

#------------------------------- 3. Editors group -------------------------------

Write-Host '3. Editors group' -ForegroundColor Cyan
try {
    $sid = (New-Object Security.Principal.NTAccount($EditorsGroup)).Translate([Security.Principal.SecurityIdentifier])
    $EditorsGroup = $sid.Translate([Security.Principal.NTAccount]).Value
}
catch {
    throw "Could not find the AD group '$EditorsGroup' ($($_.Exception.Message)). Create it first: New-ADGroup -Name psToDo-Editors -GroupScope Global -GroupCategory Security"
}
Write-Host "   $EditorsGroup ($($sid.Value))" -ForegroundColor Green

#------------------------------- 4. web.config -------------------------------

Write-Host '4. web.config' -ForegroundColor Cyan
$webConfigPath = Join-Path $PhysicalPath 'web.config'
if (-not (Test-Path $webConfigPath)) {
    throw "No web.config in $PhysicalPath. Run Setup-IisReportSecurity.ps1 first."
}
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($webConfigPath)
$config = $xml.DocumentElement

function Get-OrAddNode([System.Xml.XmlNode] $parent, [string] $name) {
    $node = $parent.SelectSingleNode($name)
    if (-not $node) { $node = $parent.AppendChild($parent.OwnerDocument.CreateElement($name)) }
    return $node
}

# a) URL Authorization: editors may enter the site too.
$authz = $xml.SelectSingleNode('/configuration/system.webServer/security/authorization')
if (-not $authz) { throw "web.config has no system.webServer/security/authorization. Run Setup-IisReportSecurity.ps1 first." }
$oldEditors = $xml.SelectSingleNode("/configuration/appSettings/add[@key='psToDo:EditorsGroup']")
$oldEditorsValue = if ($oldEditors) { $oldEditors.GetAttribute('value') } else { '' }
foreach ($n in @($authz.SelectNodes('add'))) {
    $r = $n.GetAttribute('roles')
    if ($oldEditorsValue -and $r -eq $oldEditorsValue -and $oldEditorsValue -ne $EditorsGroup) { [void]$authz.RemoveChild($n) }
}
$already = @($authz.SelectNodes('add') | Where-Object { $_.GetAttribute('accessType') -eq 'Allow' -and $_.GetAttribute('roles') -eq $EditorsGroup })
if (-not $already) {
    $allow = $xml.CreateElement('add')
    $allow.SetAttribute('accessType', 'Allow')
    $allow.SetAttribute('roles', $EditorsGroup)
    [void]$authz.AppendChild($allow)
}

# b) Request filtering: let .ashx through when only listed extensions are allowed.
$fe = $xml.SelectSingleNode('/configuration/system.webServer/security/requestFiltering/fileExtensions')
if ($fe -and -not $fe.SelectSingleNode("add[@fileExtension='.ashx']")) {
    $ext = $xml.CreateElement('add')
    $ext.SetAttribute('fileExtension', '.ashx')
    $ext.SetAttribute('allowed', 'true')
    [void]$fe.AppendChild($ext)
}

# c) appSettings for psToDo-api.ashx (absolute paths)
$appSettings = Get-OrAddNode $config 'appSettings'
$settings = [ordered]@{
    'psToDo:EditorsGroup' = $EditorsGroup
    'psToDo:DbPath'       = $DbPath
    'psToDo:BackupFolder' = $BackupFolder
    'psToDo:EditLog'      = [System.IO.Path]::Combine($LogFolder, 'psToDo-web-edits.log')
    'psToDo:QueueFolder'  = $QueueFolder
}
foreach ($key in $settings.Keys) {
    $node = $appSettings.SelectSingleNode("add[@key='$key']")
    if (-not $node) {
        $node = $xml.CreateElement('add')
        $node.SetAttribute('key', $key)
        [void]$appSettings.AppendChild($node)
    }
    $node.SetAttribute('value', $settings[$key])
}

if ($PSCmdlet.ShouldProcess($webConfigPath, "Allow $EditorsGroup, allow .ashx, write appSettings")) {
    $backup = "$webConfigPath.$(Get-Date -Format 'yyyy-MM-dd_HH.mm.ss').bak"
    Copy-Item $webConfigPath $backup -Force
    Write-Host "   Backup: $backup" -ForegroundColor DarkGray
    $xml.Save($webConfigPath)
    Write-Host "   Written: $webConfigPath" -ForegroundColor Green
    foreach ($key in $settings.Keys) { Write-Host "     $key = $($settings[$key])" -ForegroundColor DarkGray }
}

#------------------------------- 5. NTFS -------------------------------

Write-Host '5. NTFS permissions' -ForegroundColor Cyan
if ($SkipNtfs) {
    Write-Host '   Skipped (-SkipNtfs).' -ForegroundColor DarkGray
}
else {
    $dbFolder = Split-Path $DbPath -Parent
    $grants = @(
        @{ Path = $dbFolder;     Grant = "IIS AppPool\$($pool):(OI)(CI)M"; Why = 'app pool writes monitorobjects.json' }
        @{ Path = $BackupFolder; Grant = "IIS AppPool\$($pool):(OI)(CI)M"; Why = 'app pool writes backups' }
        @{ Path = $LogFolder;    Grant = "IIS AppPool\$($pool):(OI)(CI)M"; Why = 'app pool writes the edit log' }
        @{ Path = $QueueFolder;  Grant = "IIS AppPool\$($pool):(OI)(CI)M"; Why = 'app pool writes Tools requests' }
        @{ Path = $PhysicalPath; Grant = "$($EditorsGroup):(OI)(CI)R";     Why = 'IIS reads the page as the signed-in editor' }
    )
    foreach ($g in $grants) {
        if ($PSCmdlet.ShouldProcess($g.Path, "icacls /grant $($g.Grant)")) {
            if (-not (Test-Path $g.Path)) { New-Item -ItemType Directory -Path $g.Path -Force | Out-Null }
            & icacls.exe $g.Path /grant $g.Grant | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "icacls failed for $($g.Grant) on $($g.Path) (exit $LASTEXITCODE)." }
            else { Write-Host "   $($g.Grant.Split(':')[0]) -> $($g.Path)  ($($g.Why))" -ForegroundColor Green }
        }
    }
}

#------------------------------- 6. Save handler -------------------------------

Write-Host '6. Save handler' -ForegroundColor Cyan
$apiSource = Join-Path $repoRoot 'Settings\Web\psToDo-api.ashx'
$apiTarget = Join-Path $PhysicalPath 'psToDo-api.ashx'
if (Test-Path $apiTarget) { Write-Host "   $apiTarget already there (the editable report keeps it up to date)." -ForegroundColor DarkGray }
elseif (-not (Test-Path $apiSource)) { Write-Warning "Not found: $apiSource" }
elseif ($PSCmdlet.ShouldProcess($apiTarget, 'Copy psToDo-api.ashx')) {
    Copy-Item $apiSource $apiTarget -Force
    Write-Host "   Copied to $apiTarget" -ForegroundColor Green
}

#------------------------------- Summary -------------------------------

Write-Host ''
Write-Host 'Done. Next:' -ForegroundColor Cyan
Write-Host '  1. Run .\psToDo-HTML-Report-Editable-v1.3.ps1 (writes edit.html), or add it to the report task.'
Write-Host "  2. Open http(s)://<server>/edit.html as a member of $EditorsGroup : the page says 'Editing'."
Write-Host '     Anyone else who can open the site sees the same page read-only.'
Write-Host '  3. A user just added to the group must sign out and in again before saving works.'
Write-Host '  4. Saves are logged in Logs\psToDo-web-edits.log; backups land in Files\backup\psToDo.'
Write-Host '  5. Tools in the dashboard: run .\Install-help\Setup-ToolsRunner.ps1 to create the scheduled task.'
