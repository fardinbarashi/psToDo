<#
System requirements
    Windows PowerShell 5.1 or PowerShell 7 (run as Administrator) on the IIS server.
    The server must be domain-joined.

psToDo setup helper : Setup-IisReportSecurity
    Author  : Fardin Barashi
    Purpose : Lock the psToDo HTML dashboard down so ONLY members of the AD group
              psToDo-Viewers can open it. Everyone else (anonymous and every other
              domain user) gets 401.

What it does
    1. Installs the two IIS role services needed, if missing:
         Windows Authentication (Web-Windows-Auth) and URL Authorization (Web-Url-Auth).
    2. Looks the group up in AD (name -> SID -> DOMAIN\name). This checks that the group
       exists and adds the NetBIOS domain prefix that URL Authorization needs.
    3. Writes web.config into the report folder with an IIS URL Authorization rule that
       allows only that group (an existing web.config is backed up first).
    4. On the IIS site/application: enables Windows Authentication and disables Anonymous
       Authentication. These settings are locked at server level, so they are written to
       applicationHost.config with a <location> tag - not to web.config.
    5. Gives the group and the site's app pool identity NTFS Read on the report folder.
       With Windows Authentication IIS reads index.html AS THE SIGNED-IN USER, and reads
       web.config as the app pool, so both need Read (skip with -SkipNtfs).
    6. Optionally creates the site (-CreateSite) with its own app pool, pointing at the
       report folder.

    Every step is idempotent - safe to re-run. If the editable dashboard has been set up
    (Setup-IisReportEditor.ps1), its editors group stays allowed in.

Parameters
    -SiteName      IIS site name. Default: 'psToDo'
    -AppPath       Sub-application/virtual directory under the site, e.g. 'pstodo'
                   (leave empty if the site itself points at the report folder)
    -PhysicalPath  Folder that holds index.html. Default: <psToDo>\Files\report
    -Group         AD security group allowed to see the dashboard, with or without the
                   domain prefix. Default: 'psToDo-Viewers'.
    -CreateSite    Create the IIS site if it does not exist.
    -Port          HTTP port for -CreateSite (default 8080). Add an https binding afterwards.
    -SkipFeatureInstall  Do not try to install IIS role services.
    -SkipNtfs      Do not change NTFS permissions on the report folder.

Examples
    .\Setup-IisReportSecurity.ps1 -WhatIf                        # site psToDo
    .\Setup-IisReportSecurity.ps1                                # site psToDo
    .\Setup-IisReportSecurity.ps1 -CreateSite -Port 8080         # create site psToDo
    .\Setup-IisReportSecurity.ps1 -SiteName 'Default Web Site' -AppPath pstodo
    .\Setup-IisReportSecurity.ps1 -Group 'CONTOSO\psToDo-Viewers'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SiteName = 'psToDo',
    [string] $AppPath,
    [string] $PhysicalPath,
    [string] $Group = 'psToDo-Viewers',
    [switch] $CreateSite,
    [int]    $Port = 8080,
    [switch] $SkipFeatureInstall,
    [switch] $SkipNtfs
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($PhysicalPath)) { $PhysicalPath = Join-Path $repoRoot 'Files\report' }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

#------------------------------- 1. IIS role services -------------------------------

Write-Host '1. IIS role services' -ForegroundColor Cyan
if ($SkipFeatureInstall) {
    Write-Host '   Skipped (-SkipFeatureInstall).' -ForegroundColor DarkGray
}
elseif (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    # Windows Server
    foreach ($f in 'Web-Windows-Auth', 'Web-Url-Auth') {
        $feature = Get-WindowsFeature -Name $f
        if ($feature.Installed) { Write-Host "   $f already installed." -ForegroundColor DarkGray }
        elseif ($PSCmdlet.ShouldProcess($f, 'Install-WindowsFeature')) {
            Install-WindowsFeature -Name $f | Out-Null
            Write-Host "   Installed $f." -ForegroundColor Green
        }
    }
}
else {
    # Windows client (IIS on Windows 10/11)
    foreach ($f in 'IIS-WindowsAuthentication', 'IIS-URLAuthorization') {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $f
        if ($feature.State -eq 'Enabled') { Write-Host "   $f already enabled." -ForegroundColor DarkGray }
        elseif ($PSCmdlet.ShouldProcess($f, 'Enable-WindowsOptionalFeature')) {
            Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart | Out-Null
            Write-Host "   Enabled $f." -ForegroundColor Green
        }
    }
}

Import-Module WebAdministration -ErrorAction Stop

#------------------------------- 2. Resolve the group -------------------------------

Write-Host '2. Group allowed to see the dashboard' -ForegroundColor Cyan
try {
    # name -> SID -> name: proves the group exists and returns it as DOMAIN\Group,
    # the form IIS URL Authorization matches against the user's token.
    $sid   = (New-Object Security.Principal.NTAccount($Group)).Translate([Security.Principal.SecurityIdentifier])
    $Group = $sid.Translate([Security.Principal.NTAccount]).Value
}
catch {
    throw "Could not find the AD group '$Group' ($($_.Exception.Message)). Check the name, or pass -Group 'DOMAIN\psToDo-Viewers'."
}
if ($Group -notmatch '\\') { Write-Warning "'$Group' has no domain prefix - is it a LOCAL group on this server? It should be an AD security group." }
Write-Host "   $Group ($($sid.Value))" -ForegroundColor Green
Write-Host '   Must be a SECURITY group (a distribution group is not in the user''s sign-in token).' -ForegroundColor DarkGray

#------------------------------- 3. web.config -------------------------------

Write-Host '3. web.config' -ForegroundColor Cyan
if (-not (Test-Path $PhysicalPath)) {
    if ($PSCmdlet.ShouldProcess($PhysicalPath, 'Create report folder')) { New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null }
}
$webConfigPath = Join-Path $PhysicalPath 'web.config'

# Template: the web.config shipped in Files\report (keeps its comments), else a minimal one.
$templatePath = Join-Path $repoRoot 'Files\report\web.config'
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
if (Test-Path $webConfigPath)    { $xml.Load($webConfigPath) }
elseif (Test-Path $templatePath) { $xml.Load($templatePath) }
else {
    $xml.LoadXml('<?xml version="1.0" encoding="utf-8"?><configuration><system.webServer><security><authorization><clear /><add accessType="Allow" roles="DOMAIN\psToDo-Viewers" /></authorization></security></system.webServer></configuration>')
}

$authz = $xml.SelectSingleNode('/configuration/system.webServer/security/authorization')
if (-not $authz) { throw "The existing $webConfigPath has no system.webServer/security/authorization section. Merge it by hand from Files\report\web.config." }

# Rules: clear + allow the viewer group. If the editable dashboard is set up
# (appSettings psToDo:EditorsGroup, written by Setup-IisReportEditor.ps1), its editors
# group is allowed in too, so re-running this script never locks the editors out.
$editorsNode  = $xml.SelectSingleNode("/configuration/appSettings/add[@key='psToDo:EditorsGroup']")
$editorsGroup = if ($editorsNode) { $editorsNode.GetAttribute('value') } else { '' }

foreach ($n in @($authz.ChildNodes)) { if ($n.NodeType -eq 'Element') { [void]$authz.RemoveChild($n) } }
$clear = $xml.CreateElement('clear'); [void]$authz.AppendChild($clear)
foreach ($g in @($Group, $editorsGroup)) {
    if ([string]::IsNullOrWhiteSpace($g)) { continue }
    if ($g -ne $Group -or $authz.SelectNodes('add').Count -eq 0) {
        $allow = $xml.CreateElement('add')
        $allow.SetAttribute('accessType', 'Allow')
        $allow.SetAttribute('roles', $g)
        [void]$authz.AppendChild($allow)
    }
}
if ($editorsGroup -and $editorsGroup -ne $Group) { Write-Host "   Editors group kept: $editorsGroup" -ForegroundColor DarkGray }

if ($PSCmdlet.ShouldProcess($webConfigPath, "Write web.config (allow only $Group)")) {
    if (Test-Path $webConfigPath) {
        $backup = "$webConfigPath.$(Get-Date -Format 'yyyy-MM-dd_HH.mm.ss').bak"
        Copy-Item $webConfigPath $backup -Force
        Write-Host "   Backup: $backup" -ForegroundColor DarkGray
    }
    $xml.Save($webConfigPath)
    Write-Host "   Written: $webConfigPath" -ForegroundColor Green
}

#------------------------------- 4. Site + authentication -------------------------------

Write-Host '4. IIS site and authentication' -ForegroundColor Cyan
$site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if (-not $site) {
    if (-not $CreateSite) { throw "IIS site '$SiteName' not found. Create it in IIS Manager or re-run with -CreateSite." }
    if ($PSCmdlet.ShouldProcess($SiteName, "Create app pool and site on port $Port -> $PhysicalPath")) {
        # A dedicated app pool, so the site's identity is 'IIS AppPool\<SiteName>' and not the shared DefaultAppPool.
        if (-not (Test-Path "IIS:\AppPools\$SiteName")) { New-WebAppPool -Name $SiteName | Out-Null }
        New-Website -Name $SiteName -PhysicalPath $PhysicalPath -Port $Port -ApplicationPool $SiteName | Out-Null
        Write-Host "   Created app pool and site '$SiteName' on http port $Port." -ForegroundColor Green
    }
}

$location = if ([string]::IsNullOrWhiteSpace($AppPath)) { $SiteName } else { "$SiteName/$($AppPath.Trim('/'))" }

if ($PSCmdlet.ShouldProcess($location, 'Disable Anonymous, enable Windows Authentication')) {
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $location `
        -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name enabled -Value $false
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $location `
        -Filter 'system.webServer/security/authentication/windowsAuthentication' -Name enabled -Value $true
    Write-Host "   $location : Anonymous = off, Windows Authentication = on" -ForegroundColor Green
}

#------------------------------- 5. NTFS on the report folder -------------------------------

Write-Host '5. NTFS permissions on the report folder' -ForegroundColor Cyan
if ($SkipNtfs) {
    Write-Host '   Skipped (-SkipNtfs).' -ForegroundColor DarkGray
}
else {
    $pool = $null
    try {
        if ([string]::IsNullOrWhiteSpace($AppPath)) { $pool = (Get-Item "IIS:\Sites\$SiteName" -ErrorAction Stop).applicationPool }
        else { $pool = (Get-WebApplication -Site $SiteName -Name $AppPath.Trim('/') -ErrorAction Stop).applicationPool }
    } catch { }
    if (-not $pool -and $CreateSite) { $pool = $SiteName }   # -WhatIf: the site does not exist yet

    $grants = @("$($Group):(OI)(CI)R")
    if ($pool) { $grants += "IIS AppPool\$($pool):(OI)(CI)R" } else { Write-Warning "Could not find the app pool of '$location'. Give its identity Read on $PhysicalPath by hand." }

    foreach ($g in $grants) {
        if ($PSCmdlet.ShouldProcess($PhysicalPath, "icacls /grant $g")) {
            & icacls.exe $PhysicalPath /grant $g | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "icacls failed for $g (exit $LASTEXITCODE)." }
            else { Write-Host "   Read: $($g.Split(':')[0])" -ForegroundColor Green }
        }
    }
}

#------------------------------- Summary -------------------------------

Write-Host ''
Write-Host 'Done. Test it:' -ForegroundColor Cyan
Write-Host "  - As a member of $Group : the dashboard opens (Edge/Chrome sign you in automatically on the intranet zone)."
Write-Host "  - As anyone else        : HTTP 401 Unauthorized."
Write-Host ''
Write-Host 'Notes:' -ForegroundColor Cyan
Write-Host "  - The reports must be written into $PhysicalPath (the default for psToDo-HTML-Report-v1.3.ps1 and psToDo-HTML-Report-Editable-v1.4.ps1). Otherwise run them with -websitePath."
Write-Host '  - Group membership is read at sign-in: a user added to the group must sign out/in (new Kerberos ticket) before access works.'
Write-Host '  - Add an https binding with a certificate: over plain http the sign-in is protected but the page content is not.'
Write-Host '  - To let a group edit the data in the browser (edit.html), run Setup-IisReportEditor.ps1 next.'
