<#
System requirements
    PSVersion  7.3.1 (Core) or later
    Module     ExchangeOnlineManagement

psToDo setup helper : Setup-SenderMailbox-and-AccessPolicy
    Author  : Fardin Barashi
    Purpose : Create a dedicated shared mailbox for psToDo alerts and lock the
              app registration to it with an Application Access Policy, so the
              app's Mail.Send permission can ONLY send from that one mailbox
              (not from every mailbox in the tenant).

    Run this once, as an Exchange Online administrator, after the app
    registration and its Mail.Send permission exist.

What it does
    1. Connects to Exchange Online (interactive admin sign-in).
    2. Creates a shared mailbox (no license required) to send alerts from.
    3. Creates a mail-enabled security group and adds the shared mailbox to it.
    4. Creates an Application Access Policy (RestrictAccess) scoping the app to
       that group.
    5. Tests the policy against the shared mailbox.

    Each step is skipped if the object already exists, so the script is safe to
    re-run.

Parameters
    -SharedMailboxAddress   Address to send alerts from, e.g. pstodo-noreply@contoso.com  (required)
    -SharedMailboxDisplayName  Display name for that mailbox (default 'psToDo Alerts')
    -AppId                  Application (client) ID of the app registration.
                            If omitted, it is read from Settings\Config\MsGraphSettings.json.
    -ScopeGroupName         Name of the security group used by the policy (default 'psToDo-Senders')
    -ScopeGroupAddress      Address of that group (default: pstodo-senders@<mailbox domain>)
    -SkipAccessPolicy       Only create the mailbox, skip the policy.

Examples
    .\Setup-SenderMailbox-and-AccessPolicy.ps1 -SharedMailboxAddress pstodo-noreply@contoso.com -WhatIf
    .\Setup-SenderMailbox-and-AccessPolicy.ps1 -SharedMailboxAddress pstodo-noreply@contoso.com
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SharedMailboxAddress,
    [string] $SharedMailboxDisplayName = 'psToDo Alerts',
    [string] $AppId,
    [string] $ScopeGroupName = 'psToDo-Senders',
    [string] $ScopeGroupAddress,
    [switch] $SkipAccessPolicy
)

$ErrorActionPreference = 'Stop'

#------------------------------- Resolve inputs -------------------------------

$domain = ($SharedMailboxAddress -split '@')[-1]
if ([string]::IsNullOrWhiteSpace($domain) -or $domain -eq $SharedMailboxAddress) {
    throw "SharedMailboxAddress must be a full address like pstodo-noreply@contoso.com"
}
if (-not $ScopeGroupAddress) { $ScopeGroupAddress = "pstodo-senders@$domain" }

# AppId: use the parameter, otherwise find MsGraphSettings.json by walking up
# from the script folder (works even if this script sits in a subfolder like
# Install-help\). A placeholder value that is not a GUID is ignored.
if (-not $AppId) {
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        $candidate = Join-Path $dir 'Settings\Config\MsGraphSettings.json'
        if (Test-Path $candidate) {
            $val = (Get-Content -Raw -Encoding UTF8 $candidate | ConvertFrom-Json).AppId
            if ($val -match '^[0-9a-fA-F-]{36}$') { $AppId = $val }
            break
        }
        $dir = Split-Path $dir -Parent
    }
}
if (-not $SkipAccessPolicy) {
    if ([string]::IsNullOrWhiteSpace($AppId) -or $AppId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "AppId is missing or not a GUID ('$AppId'). Pass -AppId <Application (client) ID>, or fill it into MsGraphSettings.json. (Use the Application (client) ID, NOT the Object ID.)"
    }
}

Write-Host 'psToDo :: Setup-SenderMailbox-and-AccessPolicy' -ForegroundColor Cyan
Write-Host "- Shared mailbox : $SharedMailboxAddress ($SharedMailboxDisplayName)" -ForegroundColor DarkGray
Write-Host "- Scope group    : $ScopeGroupAddress ($ScopeGroupName)" -ForegroundColor DarkGray
if (-not $SkipAccessPolicy) { Write-Host "- App (client) ID: $AppId" -ForegroundColor DarkGray }

#------------------------------- Connect -------------------------------

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host '- Installing ExchangeOnlineManagement module...' -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Write-Host '- Connecting to Exchange Online (admin sign-in)...' -ForegroundColor DarkGray
    Connect-ExchangeOnline -ShowBanner:$false
}

#------------------------------- 1. Shared mailbox -------------------------------

$mbx = Get-Mailbox -Identity $SharedMailboxAddress -ErrorAction SilentlyContinue
if ($mbx) {
    Write-Host "- Shared mailbox already exists - skipping create." -ForegroundColor Green
} elseif ($PSCmdlet.ShouldProcess($SharedMailboxAddress, 'Create shared mailbox')) {
    New-Mailbox -Shared -Name $SharedMailboxDisplayName -DisplayName $SharedMailboxDisplayName -PrimarySmtpAddress $SharedMailboxAddress | Out-Null
    Write-Host "- Shared mailbox created." -ForegroundColor Green

    # Provisioning is async; wait until it is queryable before using it.
    for ($i = 0; $i -lt 12 -and -not $mbx; $i++) {
        Start-Sleep -Seconds 5
        $mbx = Get-Mailbox -Identity $SharedMailboxAddress -ErrorAction SilentlyContinue
    }
    if (-not $mbx) { Write-Warning "Mailbox not queryable yet. Wait a few minutes and re-run to finish the group + policy." }
}

#------------------------------- 2. Scope group -------------------------------

$group = Get-DistributionGroup -Identity $ScopeGroupAddress -ErrorAction SilentlyContinue
if ($group) {
    Write-Host "- Scope group already exists - skipping create." -ForegroundColor Green
} elseif ($PSCmdlet.ShouldProcess($ScopeGroupAddress, 'Create mail-enabled security group')) {
    New-DistributionGroup -Name $ScopeGroupName -Type Security -PrimarySmtpAddress $ScopeGroupAddress | Out-Null
    Write-Host "- Scope group created." -ForegroundColor Green
    Start-Sleep -Seconds 5
}

# Ensure the shared mailbox is a member of the group.
if ($PSCmdlet.ShouldProcess($ScopeGroupAddress, "Add $SharedMailboxAddress as member")) {
    try {
        Add-DistributionGroupMember -Identity $ScopeGroupAddress -Member $SharedMailboxAddress -ErrorAction Stop
        Write-Host "- Added shared mailbox to the scope group." -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match 'already a member') {
            Write-Host "- Shared mailbox already a member of the group." -ForegroundColor Green
        } else { throw }
    }
}

#------------------------------- 3. Application Access Policy -------------------------------

if ($SkipAccessPolicy) {
    Write-Host "- SkipAccessPolicy set - not creating the policy." -ForegroundColor Yellow
    return
}

$existingPolicy = Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue |
    Where-Object { $_.AppId -eq $AppId -and $_.ScopeIdentity -eq $ScopeGroupAddress }

if ($existingPolicy) {
    Write-Host "- Application Access Policy already exists for this app + group." -ForegroundColor Green
} elseif ($PSCmdlet.ShouldProcess("App $AppId -> $ScopeGroupAddress", 'Create Application Access Policy (RestrictAccess)')) {
    New-ApplicationAccessPolicy -AppId $AppId -PolicyScopeGroupId $ScopeGroupAddress `
        -AccessRight RestrictAccess -Description 'Restrict psToDo app to its alert sender mailbox' | Out-Null
    Write-Host "- Application Access Policy created. It can take up to 30 minutes to apply." -ForegroundColor Green
}

#------------------------------- 4. Test -------------------------------

if (-not $WhatIfPreference) {
    Write-Host "`n- Testing the policy against the shared mailbox..." -ForegroundColor DarkGray
    try {
        Test-ApplicationAccessPolicy -Identity $SharedMailboxAddress -AppId $AppId |
            Select-Object AppId, Mailbox, AccessCheckResult | Format-List
    } catch {
        Write-Warning "Test-ApplicationAccessPolicy could not run yet: $($_.Exception.Message). Wait for propagation and test again."
    }
}

Write-Host "`nDone. Set mailSender to $SharedMailboxAddress in your plugin defaults files." -ForegroundColor Cyan
