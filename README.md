# WireGuard Monitor

A PowerShell script that monitors WireGuard tunnel connectivity on Windows and automatically recovers from connection failures. Includes service management to stop/start dependent services when VPN connectivity is lost or restored.

## Features

- Automatic connectivity monitoring with two-stage ping verification
- Distinguishes between tunnel issues and ISP outages
- Automatic tunnel reconnection on failure
- Round-robin fallback to alternative tunnels
- Service management with dependency awareness (stops services when VPN is down, starts them when restored)
- External JSON configuration file (preserved across script updates)
- Cooldown mechanism to prevent rapid reconnection loops
- Detailed logging for troubleshooting
- Always maintains an active tunnel connection

## Requirements

- Windows 10/11 or Windows Server
- WireGuard for Windows installed
- PowerShell 5.1 or higher
- Administrator privileges

## Installation

1. Download `WireGuard-Monitor.ps1` to a folder of your choice (e.g., `C:\Scripts\WireGuard-Monitor\`)
2. Run the script with `-CreateConfig` to generate the configuration file
3. Edit the configuration file to match your setup
4. Create a scheduled task (see below)

## Configuration

### Creating the Config File

Run the script with the `-CreateConfig` parameter to create or update the configuration file:

```powershell
.\WireGuard-Monitor.ps1 -CreateConfig
```

This creates `WireGuard-Monitor.config.json` in the same folder as the script. Running this command again will add any new configuration options while preserving your existing settings.

### Configuration Options

Edit `WireGuard-Monitor.config.json`:

```json
{
  "AllowedTunnels": ["ams28", "ams29", "ams30", "ams35", "ams36"],
  "PrimaryPingTarget": "8.8.8.8",
  "SecondaryPingTarget": "1.1.1.1",
  "PingRetryDelaySeconds": 10,
  "CooldownMinutes": 5,
  "PingTimeoutSeconds": 5,
  "WireGuardConfigPath": "C:\\Program Files\\WireGuard\\Data\\Configurations",
  "ServicesToManage": ["qBittorrent", "NZBGet", "Prowlarr", "Radarr", "Medusa"]
}
```

| Setting | Description |
|---------|-------------|
| `AllowedTunnels` | Array of tunnel names to use. The script will only manage these tunnels and fall back through them in round-robin order. |
| `PrimaryPingTarget` | First IP to ping for connectivity check. |
| `SecondaryPingTarget` | Second IP to ping if primary fails. |
| `PingRetryDelaySeconds` | Seconds to wait between primary and secondary ping. |
| `CooldownMinutes` | Minutes to wait after a failed recovery before allowing another attempt. Successful recoveries do not trigger cooldown. |
| `PingTimeoutSeconds` | Timeout for each ping attempt. |
| `WireGuardConfigPath` | Path to WireGuard's encrypted config files. |
| `ServicesToManage` | Array of Windows service names to stop when VPN is down and start when restored. Set to empty array `[]` to disable service management. |

### Service Management

The script manages Windows services when VPN connectivity is lost:

- **When VPN goes down**: Services are stopped immediately (before tunnel reconnection attempts)
- **When VPN is restored**: Services are started automatically
- **When VPN cannot be restored**: Services remain stopped for safety

Service dependencies are automatically respected:
- When stopping: Dependent services are stopped first
- When starting: Required services are started first

The script works with any Windows service, including FireDaemon-managed services.

## Usage

### Manual Execution

Run from an elevated PowerShell prompt:

```powershell
.\WireGuard-Monitor.ps1
```

For verbose output:

```powershell
.\WireGuard-Monitor.ps1 -Verbose
```

To create/update the configuration file:

```powershell
.\WireGuard-Monitor.ps1 -CreateConfig
```

### Scheduled Task Setup

Run the following in an elevated PowerShell prompt to create a scheduled task that runs every 15 minutes:

```powershell
$ScriptPath = "C:\Scripts\WireGuard-Monitor\WireGuard-Monitor.ps1"  # Adjust path

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$ScriptPath`""
$Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "WireGuard-Monitor" -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "Monitors WireGuard tunnel connectivity and reconnects if needed"
```

To remove the scheduled task:

```powershell
Unregister-ScheduledTask -TaskName "WireGuard-Monitor" -Confirm:$false
```

## How It Works

```
┌─────────────────────────────────────┐
│         Script Starts               │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Cooldown active? ──── Yes ───────►│ Exit
└─────────────────┬───────────────────┘
                  │ No
                  ▼
┌─────────────────────────────────────┐
│   Ping 8.8.8.8 ──── Success ───────►│ Start any stopped services, Exit
└─────────────────┬───────────────────┘
                  │ Fail
                  ▼
┌─────────────────────────────────────┐
│   Wait 10 seconds                   │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Ping 1.1.1.1 ──── Success ───────►│ Start any stopped services, Exit
└─────────────────┬───────────────────┘
                  │ Fail
                  ▼
┌─────────────────────────────────────┐
│   Get active tunnel                 │
│   None found? ──── Yes ────────────►│ Exit
└─────────────────┬───────────────────┘
                  │ Found
                  ▼
┌─────────────────────────────────────┐
│   *** STOP MANAGED SERVICES ***     │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Disconnect tunnel                 │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Test ISP (ping without tunnel)    │
│   ISP down? ──── Yes ──────────────►│ Reconnect tunnel, Exit
│                                     │ (services remain stopped)
└─────────────────┬───────────────────┘
                  │ ISP OK
                  ▼
┌─────────────────────────────────────┐
│   Reconnect same tunnel             │
│   Working? ──── Yes ───────────────►│ Start services, Exit
└─────────────────┬───────────────────┘
                  │ Still broken
                  ▼
┌─────────────────────────────────────┐
│   Disconnect, try next tunnel       │
│   Working? ──── Yes ───────────────►│ Start services, Exit
└─────────────────┬───────────────────┘
                  │ Still broken
                  ▼
┌─────────────────────────────────────┐
│   Keep last tunnel connected        │
│   Services remain stopped           │
│   Log failure, Exit                 │
└─────────────────────────────────────┘
```

## Files

The script creates several files in the same directory:

| File | Description |
|------|-------------|
| `WireGuard-Monitor.config.json` | Configuration file (user-editable) |
| `WireGuard-Monitor.log` | Detailed log of all actions and connectivity checks |
| `WireGuard-Monitor.cooldown` | Timestamp file to track cooldown period |
| `WireGuard-Monitor.stopped-services.json` | Tracks which services were stopped (for recovery) |

### Sample Log Output

```
[2024-01-15 14:30:00] [INFO] ========== WireGuard Monitor Started ==========
[2024-01-15 14:30:00] [INFO] Testing connectivity to 8.8.8.8...
[2024-01-15 14:30:01] [INFO] Primary ping failed. Waiting 10 seconds before retry...
[2024-01-15 14:30:11] [INFO] Testing connectivity to 1.1.1.1...
[2024-01-15 14:30:12] [WARN] Secondary ping failed. Connection is broken.
[2024-01-15 14:30:12] [INFO] Active tunnel found: ams36
[2024-01-15 14:30:12] [INFO] Stopping managed services...
[2024-01-15 14:30:12] [INFO] Stopping service: qBittorrent
[2024-01-15 14:30:13] [SUCCESS] Service stopped: qBittorrent
[2024-01-15 14:30:13] [INFO] Stopping service: Radarr
[2024-01-15 14:30:14] [SUCCESS] Service stopped: Radarr
[2024-01-15 14:30:14] [INFO] Saved stopped services list to file.
[2024-01-15 14:30:14] [INFO] Disconnecting tunnel: ams36
[2024-01-15 14:30:16] [INFO] Tunnel ams36 disconnected successfully.
[2024-01-15 14:30:18] [INFO] Testing ISP connectivity (no tunnel)...
[2024-01-15 14:30:19] [SUCCESS] ISP connectivity confirmed.
[2024-01-15 14:30:19] [INFO] Connecting tunnel: ams36
[2024-01-15 14:30:22] [INFO] Tunnel ams36 connected successfully.
[2024-01-15 14:30:24] [INFO] Testing connectivity to 8.8.8.8...
[2024-01-15 14:30:25] [INFO] Primary ping successful.
[2024-01-15 14:30:25] [SUCCESS] Original tunnel ams36 reconnected and working.
[2024-01-15 14:30:25] [INFO] Starting managed services...
[2024-01-15 14:30:25] [INFO] Starting service: Radarr
[2024-01-15 14:30:26] [SUCCESS] Service started: Radarr
[2024-01-15 14:30:26] [INFO] Starting service: qBittorrent
[2024-01-15 14:30:27] [SUCCESS] Service started: qBittorrent
[2024-01-15 14:30:27] [INFO] Cleaned up stopped services file.
```

## Troubleshooting

**Script doesn't run / Access denied**
- Ensure you're running as Administrator
- Check that the scheduled task runs as SYSTEM with highest privileges

**Tunnel won't connect**
- Verify the tunnel name matches exactly (case-sensitive)
- Check that the `.conf.dpapi` file exists in the WireGuard config path
- Try connecting manually first: `wireguard /installtunnelservice "C:\Program Files\WireGuard\Data\Configurations\tunnelname.conf.dpapi"`

**Script runs but nothing happens**
- Check the log file for details
- Verify cooldown isn't active
- Ensure at least one allowed tunnel is currently running

**Services won't stop/start**
- Verify the service names are correct (use `Get-Service` to list services)
- Check if services have dependencies that need special handling
- Review the log file for specific error messages

**Config file not created**
- Run the script with `-CreateConfig` parameter
- Check write permissions on the script directory

**Log file not created**
- Check write permissions on the script directory
- Run manually with `-Verbose` to see output