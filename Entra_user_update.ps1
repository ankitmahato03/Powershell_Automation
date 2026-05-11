Import-Module Microsoft.Graph.Users
Import-Module ImportExcel

# Connect to Graph 
$TenantId = "b5db11ac-8f37-4109-a146-5d7a302f5881"
$ClientId = "27b823ed-3629-42c2-8a47-4bd5e734a8a1"
$ClientSecret = "4oJ8Q~6K6wklriRHVxG~528OWqrdenhqK2PcIciz"

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