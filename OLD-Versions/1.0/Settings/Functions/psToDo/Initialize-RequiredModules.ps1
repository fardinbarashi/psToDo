function Initialize-RequiredModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Modules
    )

    foreach ($module in $Modules) {
        Write-Host "`nChecking module: $module" -ForegroundColor Cyan

        if (Get-Module -ListAvailable -Name $module) {
            Write-Host '- Module found - Importing...' -ForegroundColor Green
            Import-Module $module -ErrorAction SilentlyContinue
        }
        else {
            Write-Host '- Module not found! - Installing...' -ForegroundColor Yellow
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
            Import-Module $module
        }
    }

    Write-Host "`nAll modules are ready!" -ForegroundColor Green
}