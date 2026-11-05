param(
    [string]$TenantId = "Ehter Your Tenant id",
    [string]$ClientId = "Enter your Client id",
    [string]$ClientSecret = $env:GRAPH_CLIENT_SECRET,
    [string]$OutputFolder = $PSScriptRoot
)

# =========================================================
# IMPORT MODULES
# =========================================================
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Groups -ErrorAction Stop
} catch {
    Write-Host "Failed to load Microsoft Graph modules: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run this script in a NEW PowerShell window (another module in this session has loaded a conflicting Azure.Core)." -ForegroundColor Yellow
    exit 1
}

# =========================================================
# AUTHENTICATION
# =========================================================
if (!$ClientSecret) {
    Write-Host "Client secret not provided. Pass -ClientSecret or set `$env:GRAPH_CLIENT_SECRET" -ForegroundColor Red
    exit
}

$SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)

try {
    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential -NoWelcome -ErrorAction Stop
} catch {
    Write-Host "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
Write-Host ""

$Timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$SummaryCsv  = Join-Path $OutputFolder "Entra_Groups_Summary_$Timestamp.csv"
$DetailCsv   = Join-Path $OutputFolder "Entra_Groups_Members_Owners_$Timestamp.csv"

# =========================================================
# GET ALL GROUPS
# =========================================================
$groups = Get-MgGroup -All -Property "id,displayName,mail,groupTypes,securityEnabled,mailEnabled,createdDateTime"

Write-Host "==== TOTAL GROUPS : $($groups.Count) ====" -ForegroundColor Cyan
Write-Host ""

$Summary = [System.Collections.Generic.List[object]]::new()
$Details = [System.Collections.Generic.List[object]]::new()

# Returns the friendly type of a directory object (user, group, device, servicePrincipal...)
function Get-ObjectType($obj) {
    return ($obj.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '')
}

# =========================================================
# MEMBERS & OWNERS PER GROUP
# =========================================================
$i = 0
foreach ($group in $groups) {

    $i++
    Write-Progress -Activity "Processing groups" -Status $group.DisplayName -PercentComplete (($i / $groups.Count) * 100)

    # Group type
    if ($group.GroupTypes -contains "Unified") {
        $GroupType = "Microsoft 365"
    } elseif ($group.SecurityEnabled -and $group.MailEnabled) {
        $GroupType = "Mail-enabled Security"
    } elseif ($group.SecurityEnabled) {
        $GroupType = "Security"
    } else {
        $GroupType = "Distribution"
    }

    $members = Get-MgGroupMember -GroupId $group.Id -All -ErrorAction SilentlyContinue
    $owners  = Get-MgGroupOwner  -GroupId $group.Id -All -ErrorAction SilentlyContinue

    $userMembers = @($members | Where-Object { (Get-ObjectType $_) -eq "user" })
    $userOwners  = @($owners  | Where-Object { (Get-ObjectType $_) -eq "user" })

    $Summary.Add([PSCustomObject]@{
        GroupName         = $group.DisplayName
        GroupId           = $group.Id
        GroupType         = $GroupType
        Mail              = $group.Mail
        Created           = $group.CreatedDateTime
        TotalMembers      = @($members).Count
        UserMembers       = $userMembers.Count
        OtherMembers      = @($members).Count - $userMembers.Count
        TotalOwners       = @($owners).Count
        UserOwners        = $userOwners.Count
    })

    foreach ($m in $members) {
        $Details.Add([PSCustomObject]@{
            GroupName         = $group.DisplayName
            GroupId           = $group.Id
            Role              = "Member"
            ObjectType        = Get-ObjectType $m
            DisplayName       = $m.AdditionalProperties['displayName']
            UserPrincipalName = $m.AdditionalProperties['userPrincipalName']
            Mail              = $m.AdditionalProperties['mail']
            ObjectId          = $m.Id
        })
    }

    foreach ($o in $owners) {
        $Details.Add([PSCustomObject]@{
            GroupName         = $group.DisplayName
            GroupId           = $group.Id
            Role              = "Owner"
            ObjectType        = Get-ObjectType $o
            DisplayName       = $o.AdditionalProperties['displayName']
            UserPrincipalName = $o.AdditionalProperties['userPrincipalName']
            Mail              = $o.AdditionalProperties['mail']
            ObjectId          = $o.Id
        })
    }
}

Write-Progress -Activity "Processing groups" -Completed

# =========================================================
# EXPORT
# =========================================================
$Summary | Export-Csv -Path $SummaryCsv -NoTypeInformation -Encoding UTF8
$Details | Export-Csv -Path $DetailCsv  -NoTypeInformation -Encoding UTF8

# =========================================================
# FINAL STATUS
# =========================================================
$GroupsNoOwner   = @($Summary | Where-Object { $_.TotalOwners -eq 0 }).Count
$GroupsNoMembers = @($Summary | Where-Object { $_.TotalMembers -eq 0 }).Count
$UniqueMembers   = @($Details | Where-Object { $_.Role -eq "Member" -and $_.ObjectType -eq "user" } | Select-Object -Unique ObjectId).Count
$UniqueOwners    = @($Details | Where-Object { $_.Role -eq "Owner"  -and $_.ObjectType -eq "user" } | Select-Object -Unique ObjectId).Count

Write-Host "==== FINAL STATUS ====" -ForegroundColor Cyan
Write-Host "Total Groups              : $($groups.Count)"
Write-Host "Unique Users as Members   : $UniqueMembers"
Write-Host "Unique Users as Owners    : $UniqueOwners"
Write-Host "Groups with NO Owner      : $GroupsNoOwner"   -ForegroundColor Yellow
Write-Host "Groups with NO Members    : $GroupsNoMembers" -ForegroundColor Yellow
Write-Host ""
Write-Host "Summary CSV : $SummaryCsv" -ForegroundColor Green
Write-Host "Detail CSV  : $DetailCsv"  -ForegroundColor Green

Disconnect-MgGraph | Out-Null
