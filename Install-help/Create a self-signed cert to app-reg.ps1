
       $cert = New-SelfSignedCertificate `
       -Subject           'CN=PsToDo' `
       -CertStoreLocation 'Cert:\LocalMachine\My' `
       -KeyExportPolicy   Exportable `
       -KeyAlgorithm      RSA `
       -KeyLength         2048 `
       -HashAlgorithm     SHA256 `
       -NotAfter          (Get-Date).AddYears(2) `
       -Provider          'Microsoft Software Key Storage Provider'

       $cert.Thumbprint
       Export-Certificate -Cert $cert -FilePath 'C:\temp\PsToDo.cer'
