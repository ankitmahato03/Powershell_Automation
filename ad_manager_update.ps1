Import-Module ActiveDirectory
Import-Module ImportExcel

# Excel path
$path = "your Excel file path"

# Import Excel
$users = Import-Excel $path

foreach ($user in $users) {

    try {

        # Get manager DN directly from Excel column
        $managerDN = (Get-ADUser -Identity $user.Reporting_To).DistinguishedName

        # Update manager
        Set-ADUser -Identity $user.SamAccountName -Manager $managerDN

        Write-Host "UPDATED: $($user.SamAccountName) --> $($user.Reporting_To)" -ForegroundColor Green
    }
    catch {

        Write-Host "ERROR: $($user.SamAccountName)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
