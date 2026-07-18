# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# Relaunch as Administrator if needed
if (-not $isAdmin) {
    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

Clear-Host

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Windows Autopilot Hardware Hash Extractor"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Ask for filename
$fileName = Read-Host "Enter the file name (without .csv)"

if ([string]::IsNullOrWhiteSpace($fileName)) {
    Write-Host ""
    Write-Host "ERROR: File name cannot be empty." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# Remove .csv if user entered it
$fileName = $fileName -replace '\.csv$', ''

# Set folder and output path
$folderPath = "D:\hashfile"
$outputFile = Join-Path $folderPath "$fileName.csv"

try {

    # Create folder if it doesn't exist
    if (!(Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    }

    Write-Host ""
    Write-Host "Preparing Get-WindowsAutopilotInfo..." -ForegroundColor Yellow

    # Trust PowerShell Gallery
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    # Install script if not already available
    #if (!(Get-Command Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue)) {
    if (!(Get-Command Get-WindowsAutopilotInfo -Force)) {

        Write-Host "Installing Get-WindowsAutopilotInfo..." -ForegroundColor Yellow

        Install-Script `
            -Name Get-WindowsAutopilotInfo `
            -Force `
            -Confirm:$false
    }

    Write-Host ""
    Write-Host "Extracting hardware hash..." -ForegroundColor Yellow

    # Extract Autopilot hardware hash
    Get-WindowsAutopilotInfo -OutputFile $outputFile

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "       COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "File saved to:" -ForegroundColor Cyan
    Write-Host $outputFile -ForegroundColor White

}
catch {

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "              PROCESS FAILED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Read-Host "Press Enter to exit"


# before run the powhershell, make sure the steps 
#PowerShell as Administrator
#powershell.exe -NoProfile -ExecutionPolicy Bypass -File "your file path d:\file.ps1"
#or 
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force .\final-psfile.ps1
