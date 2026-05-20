# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single-file PowerShell script (`WireGuard-Monitor.ps1`) that monitors WireGuard VPN tunnel connectivity on Windows and auto-recovers from failures. Designed to run as a scheduled task every 15 minutes under SYSTEM. Requires administrator privileges (`#Requires -RunAsAdministrator`).

## Development

There is no build step, test suite, or linter. The script runs directly via PowerShell 5.1+:

```powershell
.\WireGuard-Monitor.ps1           # Normal execution (requires admin + active WireGuard tunnel)
.\WireGuard-Monitor.ps1 -Verbose  # With verbose output
.\WireGuard-Monitor.ps1 -CreateConfig  # Create/update config file
```

PowerShell 7 (`pwsh`) is available locally for syntax validation:

```bash
pwsh -NoProfile -Command '$tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "WireGuard-Monitor.ps1"), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors) { $errors } else { Write-Host "No syntax errors" }'
```

Full functional testing requires a Windows machine with WireGuard installed and administrator privileges.

## Architecture

The script follows a linear recovery flow orchestrated by `Invoke-Main` (line 724):

1. **Cooldown check** - skip if a recent failed recovery set a cooldown timestamp file
2. **Two-stage ping** - primary target, wait, secondary target (avoids false positives)
3. **Service stop** - halt dependent Windows services before touching the tunnel
4. **ISP diagnosis** - disconnect tunnel and ping bare to distinguish tunnel failure from ISP outage
5. **Reconnect** - try same tunnel first, then round-robin to the next allowed tunnel
6. **Service restore** - restart services only on confirmed connectivity

Key design decisions:
- Uses `ping.exe` (not `Test-Connection`) and parses output for cross-version PowerShell reliability. Success requires both "Reply from" and "TTL=" to filter ICMP error responses.
- WireGuard tunnels are managed via `wireguard.exe /installtunnelservice` and `/uninstalltunnelservice`, not the WireGuard Windows GUI.
- Service stop/start order is computed by walking Windows service dependency graphs (`Get-ServiceStopOrder`, `Get-ServiceStartOrder`).
- Cooldown only triggers on failed recoveries; successful reconnections do not set cooldown.
- Configuration merges user JSON with built-in defaults so new config keys are added automatically on `-CreateConfig`.
- Pushover notifications are sent via `Invoke-RestMethod` POST to `https://api.pushover.net/1/messages.json`. Disabled when config keys are empty. Failed-recovery notifications are sent in a bare-ISP window (tunnel disconnected) for reliable delivery. An outage state file (`WireGuard-Monitor.outage.json`) tracks failure timestamps across runs so recovery notifications include downtime duration.

## File Conventions

All runtime files live alongside the script and share the `WireGuard-Monitor.*` prefix:
- `.config.json` - user configuration (gitignored)
- `.log` / `.log.1` / `.log.2` - rotating log files (gitignored)
- `.cooldown` - timestamp for cooldown tracking (gitignored)
- `.stopped-services.json` - tracks which services the script stopped, for recovery (gitignored)
- `.outage.json` - tracks outage start time for downtime reporting in notifications (gitignored)
