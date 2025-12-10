<#
.SYNOPSIS
    Monitors WireGuard tunnel connectivity and automatically reconnects if broken.

.DESCRIPTION
    This script checks internet connectivity through the active WireGuard tunnel.
    If connectivity is lost, it will:
    1. Stop configured services (respecting dependencies)
    2. Disconnect the current tunnel
    3. Verify ISP connectivity
    4. Reconnect the same tunnel (or cycle through alternatives)
    5. Restart services if VPN is working
    
    Designed to run as a scheduled task every 15 minutes.

.PARAMETER CreateConfig
    Creates or updates the config file with default values, preserving existing settings.

.NOTES
    Author: Rouzax
    Version: 1.0
    Requires: Administrator privileges (for WireGuard and service management)
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$CreateConfig
)

# ============================================================================
# Initialize paths relative to script location
# ============================================================================

$ScriptFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ConfigFile = Join-Path $ScriptFolder 'WireGuard-Monitor.config.json'
$LogFile = Join-Path $ScriptFolder 'WireGuard-Monitor.log'
$CooldownFile = Join-Path $ScriptFolder 'WireGuard-Monitor.cooldown'
$StoppedServicesFile = Join-Path $ScriptFolder 'WireGuard-Monitor.stopped-services.json'

# ============================================================================
# Default Configuration
# ============================================================================

$DefaultConfig = @{
    # Allowed tunnels (round-robin order)
    AllowedTunnels = @('ams28', 'ams29', 'ams30', 'ams35', 'ams36')
    
    # Ping targets (IP addresses to avoid DNS issues)
    PrimaryPingTarget   = '8.8.8.8'
    SecondaryPingTarget = '1.1.1.1'
    
    # Timing (in seconds/minutes as noted)
    PingRetryDelaySeconds = 10
    CooldownMinutes       = 5
    PingTimeoutSeconds    = 5
    
    # WireGuard configuration path
    WireGuardConfigPath = 'C:\Program Files\WireGuard\Data\Configurations'
    
    # Services to stop when VPN is down (will respect Windows service dependencies)
    ServicesToManage = @('qBittorrent', 'NZBGet', 'Prowlarr', 'Radarr', 'Medusa')
}

# ============================================================================
# Configuration Management Functions
# ============================================================================

function Get-MergedConfig {
    <#
    .SYNOPSIS
        Loads config from file and merges with defaults (defaults fill in missing keys).
    #>
    [CmdletBinding()]
    param()
    
    $config = @{}
    
    # Start with defaults
    foreach ($key in $DefaultConfig.Keys) {
        $config[$key] = $DefaultConfig[$key]
    }
    
    # Overlay existing config if present
    if (Test-Path $ConfigFile) {
        try {
            $existingConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            
            foreach ($property in $existingConfig.PSObject.Properties) {
                $config[$property.Name] = $property.Value
            }
        }
        catch {
            Write-Warning "Failed to parse config file: $_. Using defaults."
        }
    }
    
    return $config
}

function Save-Config {
    <#
    .SYNOPSIS
        Saves configuration to JSON file, preserving existing user values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )
    
    $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile -Encoding UTF8
}

function Initialize-Config {
    <#
    .SYNOPSIS
        Creates or updates config file, preserving existing values.
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-MergedConfig
    Save-Config -Config $config
    
    Write-Host "Configuration file created/updated: $ConfigFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "Current configuration:" -ForegroundColor Cyan
    $config | ConvertTo-Json -Depth 10 | Write-Host
}

# ============================================================================
# Handle -CreateConfig parameter
# ============================================================================

if ($CreateConfig) {
    Initialize-Config
    exit 0
}

# ============================================================================
# Load Configuration
# ============================================================================

# Auto-create config if it doesn't exist
if (-not (Test-Path $ConfigFile)) {
    $Config = Get-MergedConfig
    Save-Config -Config $Config
}
else {
    $Config = Get-MergedConfig
}

# ============================================================================
# Logging Functions
# ============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the log file and verbose output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    
    switch ($Level) {
        'ERROR'   { Write-Verbose $logEntry -Verbose }
        'WARN'    { Write-Verbose $logEntry -Verbose }
        'SUCCESS' { Write-Verbose $logEntry -Verbose }
        default   { Write-Verbose $logEntry }
    }
}

# ============================================================================
# Cooldown Functions
# ============================================================================

function Test-CooldownActive {
    <#
    .SYNOPSIS
        Checks if the cooldown period is still active from a previous action.
    #>
    [CmdletBinding()]
    param()
    
    if (-not (Test-Path $CooldownFile)) {
        return $false
    }
    
    try {
        $lastAction = Get-Content $CooldownFile -Raw | ForEach-Object { [datetime]::Parse($_) }
        $cooldownExpires = $lastAction.AddMinutes($Config.CooldownMinutes)
        
        if ((Get-Date) -lt $cooldownExpires) {
            $remainingMinutes = [math]::Round(($cooldownExpires - (Get-Date)).TotalMinutes, 1)
            Write-Log "Cooldown active. $remainingMinutes minutes remaining until next allowed action." -Level INFO
            return $true
        }
    }
    catch {
        Write-Log "Failed to read cooldown file: $_" -Level WARN
        Remove-Item $CooldownFile -Force -ErrorAction SilentlyContinue
    }
    
    return $false
}

function Set-Cooldown {
    <#
    .SYNOPSIS
        Sets the cooldown timestamp after taking an action.
    #>
    [CmdletBinding()]
    param()
    
    try {
        (Get-Date).ToString('o') | Set-Content $CooldownFile -Encoding UTF8
        Write-Log "Cooldown set for $($Config.CooldownMinutes) minutes."
    }
    catch {
        Write-Log "Failed to set cooldown: $_" -Level WARN
    }
}

# ============================================================================
# Network Functions
# ============================================================================

function Test-Ping {
    <#
    .SYNOPSIS
        Tests connectivity by pinging a target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )
    
    try {
        # Using ping.exe and parsing output for reliability across PowerShell versions
        $result = ping -n 1 -w ($Config.PingTimeoutSeconds * 1000) $Target 2>&1 | Out-String
        
        # Extract the relevant response line for logging
        $responseLine = ($result -split "`r?`n" | Where-Object { 
            $_ -match 'Reply from|Request timed out|Destination|General failure|transmit failed' 
        } | Select-Object -First 1)
        
        if ($responseLine) {
            Write-Log "Ping $Target`: $($responseLine.Trim())" -Level INFO
        }
        
        # Check for ICMP errors first (these contain "Reply from" but are failures)
        if ($result -match 'Destination host unreachable|Destination net unreachable|Request timed out|General failure|transmit failed') {
            return $false
        }
        
        # Check for successful reply (must have Reply from AND TTL which indicates actual success)
        $success = $result -match 'Reply from' -and $result -match 'TTL='
        
        return $success
    }
    catch {
        Write-Log "Ping to $Target threw exception: $_" -Level WARN
        return $false
    }
}

function Test-InternetConnectivity {
    <#
    .SYNOPSIS
        Tests internet connectivity with retry logic.
    .OUTPUTS
        Returns $true if connected, $false if broken.
    #>
    [CmdletBinding()]
    param()
    
    Write-Log "Testing connectivity to $($Config.PrimaryPingTarget)..."
    
    if (Test-Ping -Target $Config.PrimaryPingTarget) {
        Write-Log "Primary ping successful."
        return $true
    }
    
    Write-Log "Primary ping failed. Waiting $($Config.PingRetryDelaySeconds) seconds before retry..."
    Start-Sleep -Seconds $Config.PingRetryDelaySeconds
    
    Write-Log "Testing connectivity to $($Config.SecondaryPingTarget)..."
    
    if (Test-Ping -Target $Config.SecondaryPingTarget) {
        Write-Log "Secondary ping successful."
        return $true
    }
    
    Write-Log "Secondary ping failed. Connection is broken." -Level WARN
    return $false
}

# ============================================================================
# WireGuard Functions
# ============================================================================

function Get-ActiveWireGuardTunnel {
    <#
    .SYNOPSIS
        Gets the currently active WireGuard tunnel from the allowed list.
    .OUTPUTS
        Returns the tunnel name or $null if none active.
    #>
    [CmdletBinding()]
    param()
    
    foreach ($tunnel in $Config.AllowedTunnels) {
        $serviceName = "WireGuardTunnel`$$tunnel"
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        
        if ($service -and $service.Status -eq 'Running') {
            Write-Log "Active tunnel found: $tunnel"
            return $tunnel
        }
    }
    
    Write-Log "No active WireGuard tunnel found from allowed list." -Level WARN
    return $null
}

function Disconnect-WireGuardTunnel {
    <#
    .SYNOPSIS
        Disconnects a WireGuard tunnel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TunnelName
    )
    
    Write-Log "Disconnecting tunnel: $TunnelName"
    
    try {
        $process = Start-Process -FilePath 'wireguard.exe' -ArgumentList "/uninstalltunnelservice $TunnelName" -Wait -PassThru -NoNewWindow
        
        # Wait for service to fully stop
        $serviceName = "WireGuardTunnel`$$TunnelName"
        $timeout = 30
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service -or $service.Status -ne 'Running') {
                Write-Log "Tunnel $TunnelName disconnected successfully."
                return $true
            }
            Start-Sleep -Seconds 1
            $elapsed++
        }
        
        Write-Log "Timeout waiting for tunnel $TunnelName to disconnect." -Level ERROR
        return $false
    }
    catch {
        Write-Log "Failed to disconnect tunnel $TunnelName`: $_" -Level ERROR
        return $false
    }
}

function Connect-WireGuardTunnel {
    <#
    .SYNOPSIS
        Connects a WireGuard tunnel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TunnelName
    )
    
    $configFile = Join-Path $Config.WireGuardConfigPath "$TunnelName.conf.dpapi"
    
    if (-not (Test-Path $configFile)) {
        Write-Log "Config file not found: $configFile" -Level ERROR
        return $false
    }
    
    Write-Log "Connecting tunnel: $TunnelName"
    
    try {
        $process = Start-Process -FilePath 'wireguard.exe' -ArgumentList "/installtunnelservice `"$configFile`"" -Wait -PassThru -NoNewWindow
        
        # Wait for service to start
        $serviceName = "WireGuardTunnel`$$TunnelName"
        $timeout = 30
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Write-Log "Tunnel $TunnelName connected successfully."
                Start-Sleep -Seconds 2  # Give it a moment to establish
                return $true
            }
            Start-Sleep -Seconds 1
            $elapsed++
        }
        
        Write-Log "Timeout waiting for tunnel $TunnelName to connect." -Level ERROR
        return $false
    }
    catch {
        Write-Log "Failed to connect tunnel $TunnelName`: $_" -Level ERROR
        return $false
    }
}

function Get-NextTunnel {
    <#
    .SYNOPSIS
        Gets the next tunnel in round-robin order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentTunnel
    )
    
    $tunnels = @($Config.AllowedTunnels)
    $currentIndex = [array]::IndexOf($tunnels, $CurrentTunnel)
    
    if ($currentIndex -eq -1) {
        return $tunnels[0]
    }
    
    $nextIndex = ($currentIndex + 1) % $tunnels.Count
    return $tunnels[$nextIndex]
}

# ============================================================================
# Service Management Functions
# ============================================================================

function Get-ServiceStopOrder {
    <#
    .SYNOPSIS
        Gets services in the correct order for stopping (dependents first).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ServiceNames
    )
    
    $stopOrder = [System.Collections.ArrayList]::new()
    $processed = @{}
    
    function Add-ServiceWithDependents {
        param([string]$ServiceName)
        
        if ($processed.ContainsKey($ServiceName)) { return }
        
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $service) { return }
        
        # First, add any dependents that need to be stopped
        $dependents = Get-Service -Name $ServiceName -DependentServices -ErrorAction SilentlyContinue
        foreach ($dependent in $dependents) {
            if ($dependent.Status -eq 'Running') {
                Add-ServiceWithDependents -ServiceName $dependent.Name
            }
        }
        
        # Then add this service
        if (-not $processed.ContainsKey($ServiceName)) {
            $processed[$ServiceName] = $true
            [void]$stopOrder.Add($ServiceName)
        }
    }
    
    foreach ($serviceName in $ServiceNames) {
        Add-ServiceWithDependents -ServiceName $serviceName
    }
    
    return $stopOrder.ToArray()
}

function Get-ServiceStartOrder {
    <#
    .SYNOPSIS
        Gets services in the correct order for starting (dependencies first).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ServiceNames
    )
    
    $startOrder = [System.Collections.ArrayList]::new()
    $processed = @{}
    
    function Add-ServiceWithDependencies {
        param([string]$ServiceName)
        
        if ($processed.ContainsKey($ServiceName)) { return }
        
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $service) { return }
        
        # First, add any dependencies that need to be started
        $dependencies = Get-Service -Name $ServiceName -RequiredServices -ErrorAction SilentlyContinue
        foreach ($dependency in $dependencies) {
            Add-ServiceWithDependencies -ServiceName $dependency.Name
        }
        
        # Then add this service (only if it's in our managed list)
        if (-not $processed.ContainsKey($ServiceName) -and $ServiceNames -contains $ServiceName) {
            $processed[$ServiceName] = $true
            [void]$startOrder.Add($ServiceName)
        }
    }
    
    foreach ($serviceName in $ServiceNames) {
        Add-ServiceWithDependencies -ServiceName $serviceName
    }
    
    return $startOrder.ToArray()
}

function Stop-ManagedServices {
    <#
    .SYNOPSIS
        Stops configured services respecting dependencies.
    .OUTPUTS
        Returns array of services that were actually stopped.
    #>
    [CmdletBinding()]
    param()
    
    $servicesToManage = @($Config.ServicesToManage)
    
    if ($servicesToManage.Count -eq 0) {
        Write-Log "No services configured to manage."
        return @()
    }
    
    Write-Log "Stopping managed services..."
    
    $stopOrder = Get-ServiceStopOrder -ServiceNames $servicesToManage
    $stoppedServices = [System.Collections.ArrayList]::new()
    
    foreach ($serviceName in $stopOrder) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        
        if (-not $service) {
            Write-Log "Service not found: $serviceName" -Level WARN
            continue
        }
        
        if ($service.Status -ne 'Running') {
            Write-Log "Service already stopped: $serviceName"
            continue
        }
        
        try {
            Write-Log "Stopping service: $serviceName"
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            [void]$stoppedServices.Add($serviceName)
            Write-Log "Service stopped: $serviceName" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to stop service $serviceName`: $_" -Level ERROR
        }
    }
    
    # Save stopped services to file for recovery
    if ($stoppedServices.Count -gt 0) {
        $stoppedServices.ToArray() | ConvertTo-Json | Set-Content $StoppedServicesFile -Encoding UTF8
        Write-Log "Saved stopped services list to file."
    }
    
    return $stoppedServices.ToArray()
}

function Start-ManagedServices {
    <#
    .SYNOPSIS
        Starts services that were stopped by this script, respecting dependencies.
    #>
    [CmdletBinding()]
    param()
    
    # Get list of services we stopped
    $servicesToStart = @()
    
    if (Test-Path $StoppedServicesFile) {
        try {
            $servicesToStart = Get-Content $StoppedServicesFile -Raw | ConvertFrom-Json
            if ($null -eq $servicesToStart) { $servicesToStart = @() }
            $servicesToStart = @($servicesToStart)  # Ensure array
        }
        catch {
            Write-Log "Failed to read stopped services file: $_" -Level WARN
            $servicesToStart = @()
        }
    }
    
    # Also check configured services that might be stopped
    foreach ($serviceName in $Config.ServicesToManage) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running' -and $servicesToStart -notcontains $serviceName) {
            $servicesToStart += $serviceName
        }
    }
    
    if ($servicesToStart.Count -eq 0) {
        Write-Log "No services to start."
        return
    }
    
    Write-Log "Starting managed services..."
    
    $startOrder = Get-ServiceStartOrder -ServiceNames $servicesToStart
    
    foreach ($serviceName in $startOrder) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        
        if (-not $service) {
            Write-Log "Service not found: $serviceName" -Level WARN
            continue
        }
        
        if ($service.Status -eq 'Running') {
            Write-Log "Service already running: $serviceName"
            continue
        }
        
        try {
            Write-Log "Starting service: $serviceName"
            Start-Service -Name $serviceName -ErrorAction Stop
            Write-Log "Service started: $serviceName" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to start service $serviceName`: $_" -Level ERROR
        }
    }
    
    # Clean up stopped services file
    if (Test-Path $StoppedServicesFile) {
        Remove-Item $StoppedServicesFile -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up stopped services file."
    }
}

# ============================================================================
# Main Script Logic
# ============================================================================

function Invoke-Main {
    Write-Log "========== WireGuard Monitor Started =========="
    
    # Step 1: Check cooldown
    if (Test-CooldownActive) {
        Write-Log "Exiting due to active cooldown."
        return
    }
    
    # Step 2: Initial connectivity check
    if (Test-InternetConnectivity) {
        Write-Log "Internet connectivity OK. No action needed."
        
        # Start any services that might still be stopped from previous failure
        Start-ManagedServices
        return
    }
    
    # Step 3: Connection is broken - detect active tunnel
    $activeTunnel = Get-ActiveWireGuardTunnel
    
    if (-not $activeTunnel) {
        Write-Log "No active tunnel found. Nothing to do." -Level WARN
        return
    }
    
    $originalTunnel = $activeTunnel
    
    # Step 4: Stop services immediately (VPN is broken)
    $stoppedServices = Stop-ManagedServices
    
    # Step 5: Disconnect to test ISP
    if (-not (Disconnect-WireGuardTunnel -TunnelName $activeTunnel)) {
        Write-Log "Failed to disconnect tunnel. Aborting." -Level ERROR
        Set-Cooldown
        return
    }
    
    Start-Sleep -Seconds 2
    
    # Step 6: Test ISP connectivity
    Write-Log "Testing ISP connectivity (no tunnel)..."
    $ispConnected = Test-Ping -Target $Config.PrimaryPingTarget
    
    if (-not $ispConnected) {
        Start-Sleep -Seconds $Config.PingRetryDelaySeconds
        $ispConnected = Test-Ping -Target $Config.SecondaryPingTarget
    }
    
    if (-not $ispConnected) {
        Write-Log "ISP is down. Reconnecting original tunnel and exiting. Services remain stopped." -Level WARN
        Connect-WireGuardTunnel -TunnelName $originalTunnel | Out-Null
        Set-Cooldown
        return
    }
    
    Write-Log "ISP connectivity confirmed." -Level SUCCESS
    
    # Step 7: Reconnect same tunnel
    if (Connect-WireGuardTunnel -TunnelName $originalTunnel) {
        Start-Sleep -Seconds 2
        
        if (Test-InternetConnectivity) {
            Write-Log "Original tunnel $originalTunnel reconnected and working." -Level SUCCESS
            Start-ManagedServices
            return
        }
        
        Write-Log "Original tunnel $originalTunnel still not working." -Level WARN
        Disconnect-WireGuardTunnel -TunnelName $originalTunnel | Out-Null
    }
    
    # Step 8: Try next tunnel (round-robin)
    $nextTunnel = Get-NextTunnel -CurrentTunnel $originalTunnel
    Write-Log "Trying fallback tunnel: $nextTunnel"
    
    if (Connect-WireGuardTunnel -TunnelName $nextTunnel) {
        Start-Sleep -Seconds 2
        
        if (Test-InternetConnectivity) {
            Write-Log "Fallback tunnel $nextTunnel connected and working." -Level SUCCESS
            Start-ManagedServices
            return
        }
        
        Write-Log "Fallback tunnel $nextTunnel also not working. Keeping it connected. Services remain stopped." -Level ERROR
    }
    else {
        # Last resort: try to connect something
        Write-Log "Failed to connect fallback tunnel. Reconnecting original. Services remain stopped." -Level ERROR
        Connect-WireGuardTunnel -TunnelName $originalTunnel | Out-Null
    }
    
    # Only set cooldown on failure - prevents rapid retries when things are broken
    Set-Cooldown
    Write-Log "========== WireGuard Monitor Finished (with issues) ==========" -Level WARN
}

# Run main
try {
    Invoke-Main
}
catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    throw
}