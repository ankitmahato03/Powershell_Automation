# Connect to Microsoft Graph
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Devices
Import-Module ImportExcel

# Connect to Graph 
$TenantId = "your tenent id"
$ClientId = "your Client id"
$ClientSecret = "Your App Secret"

$SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)

Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential

# Get all users
$users = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName

$results = @()

foreach ($user in $users) {
    Write-Host "Processing: $($user.UserPrincipalName)" -ForegroundColor Cyan

    try {
        # Get registered devices
        $devices = Get-MgUserRegisteredDevice -UserId $user.Id -All
        $deviceCount = ($devices | Measure-Object).Count

        if ($deviceCount -eq 0) {
            $results += [PSCustomObject]@{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                DeviceCount       = 0
                DeviceName        = ""
                DeviceId          = ""
                OS                = ""
                TrustType         = ""
                IsCompliant       = ""
            }
        }
        else {
            foreach ($device in $devices) {

                # Get full device details
                $fullDevice = Get-MgDevice -DeviceId $device.Id -ErrorAction SilentlyContinue

                $results += [PSCustomObject]@{
                    DisplayName       = $user.DisplayName
                    UserPrincipalName = $user.UserPrincipalName
                    DeviceCount       = $deviceCount
                    DeviceName        = $fullDevice.DisplayName
                    DeviceId          = $fullDevice.Id
                    OS                = $fullDevice.OperatingSystem
                    TrustType         = $fullDevice.TrustType
                    IsCompliant       = $fullDevice.IsCompliant
                }
            }
        }
    }
    catch {
        Write-Host "ERROR: $($user.UserPrincipalName)" -ForegroundColor Red
    }
}

# Export to CSV
$results | Export-Csv "C:\Users\All_Users_Device_Details.csv" -NoTypeInformation

Write-Host "Report exported successfully" -ForegroundColor Green
