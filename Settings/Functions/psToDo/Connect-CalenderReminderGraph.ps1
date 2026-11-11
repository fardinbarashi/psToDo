function Connect-CalenderReminderGraph {
    # Mail.Send (application). Scope it with New-ApplicationAccessPolicy.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    if (-not $Certificate.HasPrivateKey) {
        throw "Certificate $($Certificate.Thumbprint) has no private key. Graph cannot sign the token."
    }

    # "Keyset does not exist" = no Read on %ProgramData%\Microsoft\Crypto\Keys
    try {
        try {
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'GetRSAPrivateKey returned null.' }

    $null = $rsa.SignData(
        [byte[]](1,2,3),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
}
catch {
    throw "The private key for $($Certificate.Thumbprint) cannot be used by $($env:USERNAME): $($_.Exception.Message)"
}
    }
    catch {
        throw "The private key for $($Certificate.Thumbprint) cannot be used by $env:USERNAME. Grant Read on the key file under %ProgramData%\Microsoft\Crypto\Keys."
    }

    if ($Certificate.NotAfter -lt (Get-Date)) {
        throw "The Graph client certificate expired on $($Certificate.NotAfter.ToString('yyyy-MM-dd'))."
    }
    if ($Certificate.NotAfter -lt (Get-Date).AddDays(30)) {
        Write-Warning "The Graph client certificate expires on $($Certificate.NotAfter.ToString('yyyy-MM-dd')). Renew it soon."
    }

    Connect-MgGraph -TenantId $TenantId -ClientId $AppId -Certificate $Certificate -NoWelcome

    $ctx = Get-MgContext
    if (-not $ctx) {
        throw 'Connect-MgGraph returned no context. Check TenantId, AppId and the thumbprint.'
    }

    if ('Mail.Send' -notin $ctx.Scopes) {
        Write-Warning "The token has no Mail.Send scope. Current scopes: $($ctx.Scopes -join ', ')"
    }

    Write-Host "Connected to Graph as app $($ctx.ClientId) in tenant $($ctx.TenantId)." -ForegroundColor Green
    return $ctx
}