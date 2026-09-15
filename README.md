
#Device Monitoring System
# Device Monitoring Script


Pings a list of network devices during business hours and sends an alert
through Power Automate (which emails the team) when a device goes offline.

## What it does

- Checks a fixed list of devices (IP + friendly name) once per run.
- Only runs its checks between **8 AM and 8 PM** (configurable).
- Pings each device, with a confirmation re-check to avoid false alarms
  from a single dropped packet.
- On PowerShell 7+, checks all devices **in parallel**; on Windows
  PowerShell 5.1 it falls back to a fast sequential loop.
- When a device is offline, calls a Power Automate flow with the device
  details, which sends an email alert.
- Uses **flag files** to stop repeat emails while a device stays offline
  (flood prevention) — see below.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+.
- Network access from the machine running the script to each device's IP
  and to the Power Automate endpoint.
- Write access to the flag directory (default: `C:\ProgramData\DeviceMonitoring\Flags`).
- Typically run on a **schedule** (e.g. Windows Task Scheduler, every
  5–15 minutes).

## How to run it

```powershell
# Basic run with defaults
.\Device-Monitoring.ps1

# With a log file and a custom flag folder
.\Device-Monitoring.ps1 -LogPath "C:\Logs\device-monitor.log" -FlagDirectory "C:\Scripts\Flags"

# Resend a reminder email every 4 hours if a device is still offline
.\Device-Monitoring.ps1 -ReAlertHours 4
```

## Key settings (parameters)

| Parameter               | Default                              | Purpose |
|--------------------------|---------------------------------------|---------|
| `BusinessHourStart/End`  | 8 / 20                               | Hours during which checks run |
| `PingCount`              | 2                                    | Ping probes per attempt |
| `OfflineConfirmRetries`  | 1                                    | Extra re-check before declaring offline |
| `ThrottleLimit`          | 8                                    | Max concurrent pings (PS7+ only) |
| `FlowTimeoutSeconds`     | 15                                   | Timeout for the Power Automate call |
| `FlowRetryCount`         | 1                                    | Retries if the flow call fails |
| `LogPath`                | (none)                               | Optional file to log output to |
| `FlagDirectory`          | `C:\ProgramData\DeviceMonitoring\Flags` | Where flag files are stored |
| `ReAlertHours`           | 0 (never resend)                     | Hours between reminder emails for a still-offline device |

To change the monitored devices, edit the `$Devices` array near the top
of the script. To change where alerts are sent, update `$FlowURL`.

## Flood prevention (flag files)

Without this, every run would re-email for a device that's still down.
Instead:

1. First time a device is seen offline → email sent → a flag file is
   created (`<sanitized-ip>.flag` in `FlagDirectory`).
2. While the flag exists → further offline detections are **suppressed**
   (no email), unless `-ReAlertHours` has elapsed.
3. When the device is seen online again → its flag is deleted
   automatically, so the next outage starts a fresh alert.

## Output

Each run prints a per-device status line and a summary count of
online/offline devices. It also returns a result object per device
(`Name`, `IP`, `Status`, `FlowCalled`, `FlowError`, `FlagAction`) that
can be piped into other tooling if needed.

## Troubleshooting

- **"Parameter cannot be found: 'TimeoutSeconds'"** → you're on Windows
  PowerShell 5.1; the script already avoids this for `Test-Connection`.
- **No email but device is offline** → check if a flag file already
  exists for that device in `FlagDirectory`; that's expected suppression.
- **Emails never stop** → confirm the flag directory is writable by the
  account running the script; if it can't write flags, it can't suppress repeats.
