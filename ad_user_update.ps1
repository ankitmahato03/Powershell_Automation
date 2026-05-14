Import-Module ActiveDirectory
Import-Module ImportExcel

$path = "C:\Users\optad1\Desktop\alluser\Final_List.xlsx"
$users = Import-Excel $path

foreach ($user in $users) {
    try {
        # Check if user exists in AD
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'" -ErrorAction SilentlyContinue

        if ($adUser) {
            # Update attribute (example: Title)
            Set-ADUser -Identity $user.SamAccountName -EmployeeID $user.employeeID

            Write-Host "UPDATED: $($user.SamAccountName)" -ForegroundColor Green
        }
        else {
            Write-Host "SKIPPED (Not Found): $($user.SamAccountName)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "ERROR: $($user.SamAccountName)" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
}
