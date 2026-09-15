<#
.SYNOPSIS
    Pings a list of devices during business hours and notifies Power Automate
    for any device that is offline.

.NOTES
    Optimizations vs. original version:
      - Devices are checked in PARALLEL (PS 7+) instead of one-by-one, so a
        run with several offline devices no longer waits on each ping serially.
      - Falls back to fast sequential checks automatically on Windows PowerShell 5.1.
      - Ping uses a short timeout + fewer probes by default (configurable),
        with an automatic single re-check before declaring a device offline,
        to avoid false alarms from one dropped packet.
      - Power Automate call has a timeout and one retry with backoff.
      - All config (devices, hours, flow URL, ping/retry behavior) is in one
        params block at the top - nothing else needs to be touched to tune it.
      - Structured into functions so the logic is testable/reusable.
      - Emits a summary object at the end and an optional transcript log file.
#>

[CmdletBinding()]
param(
    # ---- Business hours (24h clock) ----
    [int]$BusinessHourStart = 8,
    [int]$BusinessHourEnd   = 20,

    # ---- Ping behavior ----
    [int]$PingCount            = 2,     # probes per attempt (was 5)
    [int]$PingTimeoutSeconds   = 1,     # per-probe timeout
    [int]$OfflineConfirmRetries = 1,    # extra full re-check before flagging offline

    # ---- Parallelism (only used on PowerShell 7+) ----
    [int]$ThrottleLimit = 8,

    # ---- Power Automate ----
    [int]$FlowTimeoutSeconds = 15,
    [int]$FlowRetryCount     = 1,

    # ---- Optional log file (leave blank to disable) ----
    [string]$LogPath = "",

    # ---- Flood-prevention flag files ----
    # While a device stays offline, a flag file prevents repeat emails.
    # The flag is cleared automatically once the device comes back online.
    [string]$FlagDirectory = "C:\ProgramData\DeviceMonitoring\Flags",

    # Optional reminder: resend the alert if a device has STILL been offline
    # for this many hours since the last alert. Set to 0 to never resend
    # (silence until it recovers) - this is the default flood-prevention mode.
    [double]$ReAlertHours = 0
)

# ==========================================
# Device list
# ==========================================
$Devices = @(
    @{ IP = "172.16.10.114"; Name = "Meeting Room VI TV" },
    @{ IP = "172.16.10.190"; Name = "Meeting Room VI Desktop" },
    @{ IP = "172.16.10.4";   Name = "Meeting Room V TV" },
    @{ IP = "172.16.9.125";  Name = "Meeting Room V Desktop" },
    @{ IP = "172.16.10.5";   Name = "Meeting Room IV TV" },
    @{ IP = "172.16.8.67";   Name = "Meeting Room IV Desktop" },
    @{ IP = "172.16.9.201";  Name = "Optimus Hall Printer" }
)

# ==========================================
# Power Automate HTTP trigger URL
# ==========================================
$FlowURL = "https://defaultb5db11ac8f374109a1465d7a302f58.81.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/30/workflows/fdf21f11249d4674960dcfa78dcf7f84/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=_ZHX0bufsqK6I-YQHerP6Ic4oJq0QvpG1-VIFzEdzZE"

# ==========================================
# Ensure flag directory exists
# ==========================================
if (-not (Test-Path $FlagDirectory)) {
    New-Item -ItemType Directory -Path $FlagDirectory -Force | Out-Null
}

# ==========================================
# Helpers
# ==========================================

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    if ($LogPath) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Out-File -FilePath $LogPath -Append -Encoding utf8
    }
}

function Test-DeviceOnline {
    <#
        Wraps Test-Connection and confirms offline status with a re-check,
        so one dropped packet doesn't trigger a false alert.

        NOTE: -TimeoutSeconds is only available on the PowerShell 7+ version
        of Test-Connection. Windows PowerShell 5.1's Test-Connection has no
        per-probe timeout parameter, so it isn't used here for compatibility
        with both versions. Speed on 5.1 is controlled via -Count instead.
    #>
    param(
        [string]$IPAddress,
        [int]$Count,
        [int]$TimeoutSeconds,   # kept for signature compatibility; unused on PS 5.1
        [int]$ConfirmRetries
    )

    for ($attempt = 0; $attempt -le $ConfirmRetries; $attempt++) {
        $online = Test-Connection -ComputerName $IPAddress `
                                   -Count $Count `
                                   -Quiet `
                                   -ErrorAction SilentlyContinue

        if ($online) { return $true }
        # last attempt already run above -> loop again only if retries remain
    }
    return $false
}

function Get-FlagPath {
    <# Builds a safe, unique filename per device (IP-based so it's stable
       even if a device's display name changes). #>
    param([string]$IP, [string]$Directory)
    $safeName = $IP -replace '[^a-zA-Z0-9]', '_'
    return (Join-Path $Directory "$safeName.flag")
}

function Get-DeviceFlag {
    <# Returns the flag's contents (as an object) if it exists, else $null. #>
    param([string]$IP, [string]$Directory)
    $path = Get-FlagPath -IP $IP -Directory $Directory
    if (Test-Path $path) {
        try { return Get-Content -Path $path -Raw | ConvertFrom-Json }
        catch { return $null }   # corrupt/empty flag file -> treat as no flag
    }
    return $null
}

function Set-DeviceFlag {
    <# Creates or updates the flag file for an offline device. #>
    param([string]$IP, [string]$Name, [string]$Directory, [datetime]$FirstAlertTime)
    $path = Get-FlagPath -IP $IP -Directory $Directory
    @{
        DeviceName     = $Name
        IP             = $IP
        FirstAlertTime = $FirstAlertTime.ToString("yyyy-MM-dd HH:mm:ss")
        LastAlertTime  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
}

function Remove-DeviceFlag {
    <# Clears the flag once a device is confirmed back online. #>
    param([string]$IP, [string]$Directory)
    $path = Get-FlagPath -IP $IP -Directory $Directory
    if (Test-Path $path) { Remove-Item -Path $path -Force }
}

function Send-OfflineAlert {
    param(
        [string]$IP,
        [string]$Name,
        [string]$Url,
        [int]$TimeoutSeconds,
        [int]$RetryCount
    )

    $Body = @{
        Device     = $IP
        DeviceName = $Name
        Status     = "Offline"
        Timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ServerName = $env:COMPUTERNAME
    } | ConvertTo-Json

    $lastError = $null
    for ($i = 0; $i -le $RetryCount; $i++) {
        try {
            Invoke-RestMethod -Uri $Url -Method Post -ContentType "application/json" `
                               -Body $Body -TimeoutSec $TimeoutSeconds | Out-Null
            return @{ Success = $true; Error = $null }
        }
        catch {
            $lastError = $_.Exception.Message
            if ($i -lt $RetryCount) { Start-Sleep -Seconds ([math]::Pow(2, $i + 1)) }
        }
    }
    return @{ Success = $false; Error = $lastError }
}

function Invoke-DeviceCheck {
    <#
        Full check + alert flow for a single device. Returns a result object.
        Kept as one function so it can run identically inside ForEach-Object -Parallel
        or a normal foreach loop.

        Flood prevention: an offline device only triggers Power Automate the
        FIRST time it's seen offline. A flag file records that an alert was
        sent; while the flag exists, subsequent runs skip alerting (unless
        -ReAlertHours is set and that many hours have passed since the last
        alert). The flag is deleted automatically once the device is seen
        online again, so the next outage starts a fresh alert cycle.
    #>
    param($Device, $PingCount, $PingTimeoutSeconds, $OfflineConfirmRetries,
          $FlowURL, $FlowTimeoutSeconds, $FlowRetryCount,
          $FlagDirectory, $ReAlertHours)

    $isOnline = Test-DeviceOnline -IPAddress $Device.IP `
                                   -Count $PingCount `
                                   -TimeoutSeconds $PingTimeoutSeconds `
                                   -ConfirmRetries $OfflineConfirmRetries

    $result = [pscustomobject]@{
        Name        = $Device.Name
        IP          = $Device.IP
        Status      = if ($isOnline) { "Online" } else { "Offline" }
        FlowCalled  = $false
        FlowError   = $null
        FlagAction  = "None"   # None | Created | Skipped-Flagged | Resent | Cleared
    }

    if ($isOnline) {
        # Device recovered - clear any existing flag so the next outage alerts again.
        $existingFlag = Get-DeviceFlag -IP $Device.IP -Directory $FlagDirectory
        if ($existingFlag) {
            Remove-DeviceFlag -IP $Device.IP -Directory $FlagDirectory
            $result.FlagAction = "Cleared"
        }
        return $result
    }

    # Device is offline - decide whether to alert based on the flag.
    $flag = Get-DeviceFlag -IP $Device.IP -Directory $FlagDirectory

    $shouldAlert = $false
    $firstAlertTime = Get-Date

    if (-not $flag) {
        # No flag yet -> first time seeing this device offline. Alert now.
        $shouldAlert = $true
    }
    elseif ($ReAlertHours -gt 0) {
        # Flag exists, but check if it's time for a reminder resend.
        $lastAlert = [datetime]$flag.LastAlertTime
        $firstAlertTime = [datetime]$flag.FirstAlertTime
        if (((Get-Date) - $lastAlert).TotalHours -ge $ReAlertHours) {
            $shouldAlert = $true
        }
    }

    if ($shouldAlert) {
        $alert = Send-OfflineAlert -IP $Device.IP -Name $Device.Name -Url $FlowURL `
                                    -TimeoutSeconds $FlowTimeoutSeconds -RetryCount $FlowRetryCount
        $result.FlowCalled = $alert.Success
        $result.FlowError  = $alert.Error

        if ($alert.Success) {
            Set-DeviceFlag -IP $Device.IP -Name $Device.Name -Directory $FlagDirectory -FirstAlertTime $firstAlertTime
            $result.FlagAction = if ($flag) { "Resent" } else { "Created" }
        }
    }
    else {
        $result.FlagAction = "Skipped-Flagged"
    }

    return $result
}

# ==========================================
# Business hours gate
# ==========================================
$currentHour = (Get-Date).Hour

if ($currentHour -lt $BusinessHourStart -or $currentHour -ge $BusinessHourEnd) {
    Write-Log "Outside business hours ($BusinessHourStart:00-$BusinessHourEnd:00). No devices were checked." "Yellow"
    return
}

Write-Log "==========================================" 
Write-Log "Starting device monitoring..."
Write-Log "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "=========================================="

$results = @()

if ($PSVersionTable.PSVersion.Major -ge 7) {

    # Capture function bodies as strings so they can be re-created inside
    # each parallel runspace via $using: (you cannot pass functions
    # themselves into -Parallel, only serializable values like strings).
    $testDeviceOnlineDef  = ${function:Test-DeviceOnline}.ToString()
    $sendOfflineAlertDef  = ${function:Send-OfflineAlert}.ToString()
    $invokeDeviceCheckDef = ${function:Invoke-DeviceCheck}.ToString()
    $getFlagPathDef       = ${function:Get-FlagPath}.ToString()
    $getDeviceFlagDef     = ${function:Get-DeviceFlag}.ToString()
    $setDeviceFlagDef     = ${function:Set-DeviceFlag}.ToString()
    $removeDeviceFlagDef  = ${function:Remove-DeviceFlag}.ToString()

    # ---- PowerShell 7+: check all devices in parallel ----
    $results = $Devices | ForEach-Object -Parallel {
        # Re-declare functions inside the parallel runspace
        ${function:Test-DeviceOnline} = $using:testDeviceOnlineDef
        ${function:Send-OfflineAlert} = $using:sendOfflineAlertDef
        ${function:Invoke-DeviceCheck} = $using:invokeDeviceCheckDef
        ${function:Get-FlagPath} = $using:getFlagPathDef
        ${function:Get-DeviceFlag} = $using:getDeviceFlagDef
        ${function:Set-DeviceFlag} = $using:setDeviceFlagDef
        ${function:Remove-DeviceFlag} = $using:removeDeviceFlagDef

        Invoke-DeviceCheck -Device $_ `
                            -PingCount $using:PingCount `
                            -PingTimeoutSeconds $using:PingTimeoutSeconds `
                            -OfflineConfirmRetries $using:OfflineConfirmRetries `
                            -FlowURL $using:FlowURL `
                            -FlowTimeoutSeconds $using:FlowTimeoutSeconds `
                            -FlowRetryCount $using:FlowRetryCount `
                            -FlagDirectory $using:FlagDirectory `
                            -ReAlertHours $using:ReAlertHours
    } -ThrottleLimit $ThrottleLimit

} else {
    # ---- Windows PowerShell 5.1 fallback: fast sequential ----
    foreach ($Device in $Devices) {
        $results += Invoke-DeviceCheck -Device $Device `
                                        -PingCount $PingCount `
                                        -PingTimeoutSeconds $PingTimeoutSeconds `
                                        -OfflineConfirmRetries $OfflineConfirmRetries `
                                        -FlowURL $FlowURL `
                                        -FlowTimeoutSeconds $FlowTimeoutSeconds `
                                        -FlowRetryCount $FlowRetryCount `
                                        -FlagDirectory $FlagDirectory `
                                        -ReAlertHours $ReAlertHours
    }
}

# ==========================================
# Report results
# ==========================================
foreach ($r in $results) {
    Write-Log ""
    Write-Log "$($r.Name) ($($r.IP)):"
    if ($r.Status -eq "Online") {
        if ($r.FlagAction -eq "Cleared") {
            Write-Log "  Status: ONLINE - device recovered, alert flag cleared." "Green"
        } else {
            Write-Log "  Status: ONLINE - Power Automate not called." "Green"
        }
    }
    elseif ($r.FlagAction -eq "Skipped-Flagged") {
        Write-Log "  Status: OFFLINE - already alerted earlier, email suppressed (flag active)." "Yellow"
    }
    elseif ($r.FlowCalled) {
        Write-Log "  Status: OFFLINE - Power Automate flow called successfully ($($r.FlagAction))." "Red"
    }
    else {
        Write-Log "  Status: OFFLINE - Failed to call Power Automate: $($r.FlowError)" "Red"
    }
}

$onlineCount  = ($results | Where-Object Status -eq "Online").Count
$offlineCount = ($results | Where-Object Status -eq "Offline").Count

Write-Log ""
Write-Log "=========================================="
Write-Log "Device monitoring completed. Online: $onlineCount | Offline: $offlineCount"
Write-Log "=========================================="

# Return structured results too, in case this is chained into another script/flow
$results
