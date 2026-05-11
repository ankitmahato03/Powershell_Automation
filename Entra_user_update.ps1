Import-Module Microsoft.Graph.Users
Import-Module ImportExcel

# Connect to Graph 
$TenantId = "Your tenant id"
$ClientId = "Your client id"
$ClientSecret = "Your client secret"

$SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)

Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential

# Excel path
$path = "C:\Final_Entra_user.xlsx"

# Import Excel
$users = Import-Excel $path

foreach ($user in $users) {

    $upn = $user.UserPrincipalName

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Host "Skipped: Empty UPN" -ForegroundColor Yellow
        continue
    }

    try {
        Write-Host "Updating: $upn" -ForegroundColor Cyan

        # Update City
        if (![string]::IsNullOrWhiteSpace($user.City)) {
            Set-MgUser -UserId $upn -City $user.City
            Write-Host "City updated to $($user.City)" -ForegroundColor Green
        }

        # # Update OfficeLocation
        # if (![string]::IsNullOrWhiteSpace($user.OfficeLocation)) {
        #     Set-MgUser -UserId $upn -OfficeLocation $user.OfficeLocation
        #     Write-Host "OfficeLocation updated to $($user.OfficeLocation)" -ForegroundColor Green
        # }

        #Country Update
         if (![string]::IsNullOrWhiteSpace($user.Country)) {
            Set-MgUser -UserId $upn -Country $user.Country
            Write-Host "City updated to $($user.Country)" -ForegroundColor Green
        }


        if ([string]::IsNullOrWhiteSpace($user.City) -and [string]::IsNullOrWhiteSpace($user.OfficeLocation) -and [string]::IsNullOrWhiteSpace($user.Country) ) {
            Write-Host "Skipped: No values to update" -ForegroundColor Yellow
        }

    }
    catch {
        Write-Host "Error: $upn" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }

    Write-Host "----------------------------------------"
}
