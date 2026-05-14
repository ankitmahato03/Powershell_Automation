Import-Module Microsoft.Graph.Users
Import-Module ImportExcel

# Connect to Graph 
$TenantId = "Your Tenant ID "
$ClientId = "Your Client id"
$ClientSecret = "Your Client Secret"

$SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)

Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential

# Excel path
$path = "C:\Zoho_Employees_for_entra.xlsx"

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
        # if (![string]::IsNullOrWhiteSpace($user.Location_Name)) {
        #     Set-MgUser -UserId $upn -City $user.Location_Name
        #     Write-Host "City updated to $($user.Location_Name)" -ForegroundColor Green
        # }

        # Updating the Employee ID
        #  if (![string]::IsNullOrWhiteSpace($user.EmployeeID)) {
        #     Set-MgUser -UserId $upn -EmployeeId $user.EmployeeID
        #     Write-Host "Employee ID updated to $($user.EmployeeID)" -ForegroundColor Green
        # }

        # # Update OfficeLocation
        # if (![string]::IsNullOrWhiteSpace($user.Location_Name)) {
        #     Set-MgUser -UserId $upn -OfficeLocation $user.Location_Name
        #     Write-Host "OfficeLocation updated to $($user.Location_Name)" -ForegroundColor Green
        # }

        # Job Title
        # if (![string]::IsNullOrWhiteSpace($user.Title)) {
        #     Set-MgUser -UserId $upn -JobTitle $user.Title
        #     Write-Host "Job Title updated to $($user.Title)" -ForegroundColor Green
        # }

         # Update Deparment 
         if (![string]::IsNullOrWhiteSpace($user.Department)) {
             Set-MgUser -UserId $upn -Department $user.Department
             Write-Host "Department updated to $($user.Department)" -ForegroundColor Green
         }

         # Update the Mobile PHone
        #  if (![string]::IsNullOrWhiteSpace($user.Mobile_Phone)) {
        #      Set-MgUser -UserId $upn -MobilePhone $user.Mobile_Phone
        #      Write-Host "Mobile Number updated to $($user.Mobile_Phone)" -ForegroundColor Green
        #  }


        #Country Update
        #  if (![string]::IsNullOrWhiteSpace($user.Country)) {
        #     Set-MgUser -UserId $upn -Country $user.Country
        #     Write-Host "Country updated to $($user.Country)" -ForegroundColor Green
        # }

        # Manager Update
        # if (![string]::IsNullOrWhiteSpace($user.Reporting_To_F_E)) {
        #          Set-MgUserManagerByRef -UserId $user.UserPrincipalName -BodyParameter @{
        #         "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($user.Reporting_To_F_E)"
        #         }

        #         Write-Host "Manager updated to $($user.Reporting_To_F_E)" -ForegroundColor Green
        #     }


        # if ([string]::IsNullOrWhiteSpace($user.Location_Name) -and [string]::IsNullOrWhiteSpace($user.EmployeeID) -and [string]::IsNullOrWhiteSpace($user.Location_Name) -and [string]::IsNullOrWhiteSpace($user.Title) -and [string]::IsNullOrWhiteSpace($user.Deparment) -and [string]::IsNullOrWhiteSpace($user.Mobile_Phone) -and [string]::IsNullOrWhiteSpace($user.Country) ) {
        #     Write-Host "Skipped: No values to update" -ForegroundColor Yellow
        # }


         if ( [string]::IsNullOrWhiteSpace($user.Department) ) {
            Write-Host "Skipped: No values to update" -ForegroundColor Yellow
        }

    }
    catch {
        Write-Host "Error: $upn" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }

    Write-Host "----------------------------------------"
}
