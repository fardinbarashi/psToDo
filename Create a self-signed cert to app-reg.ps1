# Export public key to azure 
<#
.SYNOPSIS
    Creates an exportable certificate, grants an account read access to the
    private key, and exports the public .cer and private .pfx to disk.

.DESCRIPTION
    Run as administrator.

    The ACL step is what prevents "Keyset does not exist" from Connect-MgGraph.
    A certificate in Cert:\LocalMachine\My has its private key stored as a file
    with its own permissions, separate from the certificate itself.

.PARAMETER Subject
    Certificate subject. Default: CN=CalenderReminder

.PARAMETER ServiceAccount
    Account that runs CalenderReminder.ps1, in DOMAIN\user form.
    Gets Read on the private key. Default: the current user.

.PARAMETER Years
    Validity in years. Default: 2

.PARAMETER ExportPath
    Folder for the .cer and .pfx. Default: C:\temp\certs

.PARAMETER PfxPassword
    Password for the .pfx. Prompted for if omitted.

.EXAMPLE
    .\New-CalenderReminderCertificate.ps1

.EXAMPLE
    .\New-CalenderReminderCertificate.ps1 `
        -ServiceAccount 'LAB\svc-calenderreminder' `
        -ExportPath 'D:\certs' `
        -Years 3
#>

[CmdletBinding()]
param(
    [string]       $Subject        = 'CN=CalenderReminder',
    [string]       $ServiceAccount = "$env:USERDOMAIN\$env:USERNAME",
    [int]          $Years          = 2,
    [string]       $ExportPath     = '$PSScriptRoot\Files\selfSignedCertificate\publicToAppReg\',
    [securestring] $PfxPassword
)

$ErrorActionPreference = 'Stop'
z
#------------------------------- Preflight -------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw 'Run this from an elevated PowerShell session. Cert:\LocalMachine\My needs administrator rights.'
}

# Resolve the account now, not after the certificate exists
try {
    $null = ([System.Security.Principal.NTAccount]$ServiceAccount).Translate(
        [System.Security.Principal.SecurityIdentifier]
    )
}
catch {
    throw "Cannot resolve the account '$ServiceAccount'. Use DOMAIN\user or MACHINE\user form."
}

if (-not $PfxPassword) {
    $PfxPassword = Read-Host -AsSecureString 'PFX password'
}
if ($PfxPassword.Length -eq 0) {
    throw 'The PFX password cannot be empty.'
}

if (-not (Test-Path $ExportPath)) {
    New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
}

#------------------------------- Create -------------------------------

Write-Host "Creating certificate '$Subject'..." -ForegroundColor Yellow

# KeySpec Signature: the key signs the client assertion, it does not encrypt.
# Microsoft Software Key Storage Provider is KSP, not the legacy CSP. KSP keys
# live under ProgramData\Microsoft\Crypto\Keys, which the ACL step below needs.
$cert = New-SelfSignedCertificate `
    -Subject           $Subject `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -KeyExportPolicy   Exportable `
    -KeySpec           Signature `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -NotAfter          (Get-Date).AddYears($Years) `
    -Provider          'Microsoft Software Key Storage Provider'

Write-Host "  Thumbprint  : $($cert.Thumbprint)" -ForegroundColor Green
Write-Host "  Valid until : $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Green

#------------------------------- ACL on the private key -------------------------------

Write-Host "Granting Read on the private key to '$ServiceAccount'..." -ForegroundColor Yellow

# Re-fetch from the store. The object New-SelfSignedCertificate returns does not
# always expose PrivateKey.Key in a usable state.
$stored  = Get-ChildItem "Cert:\LocalMachine\My\$($cert.Thumbprint)"
$keyName = $stored.PrivateKey.Key.UniqueName

if (-not $keyName) {
    throw 'The certificate was created but its private key name cannot be read.'
}

$keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $keyName

if (-not (Test-Path $keyPath)) {
    throw "Private key file not found at $keyPath"
}

$acl  = Get-Acl -Path $keyPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $ServiceAccount, 'Read', 'Allow'
)
$acl.AddAccessRule($rule)
Set-Acl -Path $keyPath -AclObject $acl

Write-Host "  Key file: $keyPath" -ForegroundColor Green

#------------------------------- Verify -------------------------------

$check = Get-ChildItem "Cert:\LocalMachine\My\$($cert.Thumbprint)"

if (-not $check.HasPrivateKey) {
    throw 'HasPrivateKey is false. The key did not survive creation.'
}

try   { $null = $check.PrivateKey.Key.UniqueName }
catch { throw "The private key exists but cannot be opened: $($_.Exception.Message)" }

Write-Host '  Private key verified as readable.' -ForegroundColor Green

#------------------------------- Export -------------------------------

$cerPath = Join-Path $ExportPath 'CalenderReminder.cer'
$pfxPath = Join-Path $ExportPath 'CalenderReminder.pfx'

Export-Certificate -Cert $stored -FilePath $cerPath -Force | Out-Null

# AES256_SHA256, not the weaker TripleDES_SHA1 default of older PowerShell versions
Export-PfxCertificate `
    -Cert                  $stored `
    -FilePath              $pfxPath `
    -Password              $PfxPassword `
    -CryptoAlgorithmOption AES256_SHA256 `
    -Force | Out-Null

Write-Host ''
Write-Host "Public key  (upload to Azure) : $cerPath" -ForegroundColor Cyan
Write-Host "Private key (keep secret)     : $pfxPath" -ForegroundColor Cyan
Write-Host ''
Write-Host "CertificateThumbprint: $($cert.Thumbprint)" -ForegroundColor White
Write-Host ''

[pscustomobject]@{
    Thumbprint = $cert.Thumbprint
    NotAfter   = $cert.NotAfter
    CerPath    = $cerPath
    PfxPath    = $pfxPath
}
