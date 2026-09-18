<#
.SYNOPSIS
    Centralized PowerShell script for Rust Dedicated Server management.

.DESCRIPTION
    Handles starting, stopping, restarting, updating, and wiping a Rust
    Dedicated Server. Settings are loaded from RustServer.config.json,
    which is normally created by Install-RustServer.ps1 (or by running
    this script once with -Action generate-config).

.PARAMETER Action
    One of: start, stop, restart, update, wipe, nightly, generate-config

.PARAMETER ForceWipe
    Skip the confirmation prompt for the 'wipe' action.

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to RustServer.config.json next
    to this script.

.EXAMPLE
    .\Manage-RustServer.ps1 -Action start

.EXAMPLE
    .\Manage-RustServer.ps1 -Action wipe -ForceWipe

.EXAMPLE
    .\Manage-RustServer.ps1 -Action nightly
    # Used by the scheduled task created by Install-RustServer.ps1.
    # Decides whether tonight is a restart night or a wipe night based on
    # the WipeSchedule settings in the config file.
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'update', 'wipe', 'nightly', 'generate-config')]
    [string]$Action,

    [switch]$ForceWipe,

    [string]$ConfigPath = (Join-Path $PSScriptRoot "RustServer.config.json")
)

# --- Default configuration (used until a config file is loaded/created) ---
$Script:Config = [ordered]@{
    SteamCmdPath          = "C:\RustServer\SteamCMD"
    RustServerRootPath    = "C:\RustServer"
    RustGamePath          = "C:\RustServer\rust_game"
    ServerIdentity        = "RustServer"
    RCONPassword          = "changeme"
    ServerPort            = 28015
    RCONPort              = 28016
    QueryPort             = 28017
    WorldSize             = 4500
    Seed                  = 12345
    MaxPlayers            = 150
    Hostname              = "My Awesome Rust Server"
    Description           = "A friendly Rust server."
    HeaderImage           = ""
    ServerURL             = ""
    Level                 = "Procedural Map"
    LevelURL              = ""
    SaveInterval          = 300
    TickRate              = 30

    # Nightly maintenance schedule (used by the 'nightly' action)
    NightlyRestartEnabled = $true
    NightlyRestartTime    = "04:00"
    WipeSchedule          = "None"       # None | Daily | Weekly | BiWeekly | Monthly
    WipeDayOfWeek         = "Thursday"
    WipeWeekOfMonth       = "First"      # First | Second | Third | Fourth | Last
}

# ============================================================
# Config load / save / wizard
# ============================================================

function Import-RustServerConfig {
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in @($Script:Config.Keys)) {
                if ($null -ne $loaded.$key -and $loaded.$key -ne "") {
                    $Script:Config[$key] = $loaded.$key
                }
            }
        } catch {
            Write-Warning "Failed to parse '$ConfigPath' - falling back to defaults. $_"
        }
    } else {
        Write-Warning "No config file found at '$ConfigPath'. Using built-in defaults. Run with -Action generate-config to create one, or use Install-RustServer.ps1."
    }
}

function Save-RustServerConfig {
    $dir = Split-Path -Parent $ConfigPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Script:Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "Configuration saved to $ConfigPath" -ForegroundColor Green
}

function Read-Default {
    param([string]$Prompt, $Default)
    $val = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function New-RustServerConfigInteractive {
    Write-Host ""
    Write-Host "=== Rust Server Configuration Wizard ===" -ForegroundColor Cyan
    Write-Host "Press Enter to accept the default shown in [brackets]." -ForegroundColor DarkGray
    Write-Host ""

    $Script:Config.RustServerRootPath = Read-Default "Install root folder" $Script:Config.RustServerRootPath
    $Script:Config.SteamCmdPath       = Read-Default "SteamCMD folder" (Join-Path $Script:Config.RustServerRootPath "SteamCMD")
    $Script:Config.RustGamePath       = Read-Default "Rust game folder" (Join-Path $Script:Config.RustServerRootPath "rust_game")
    $Script:Config.ServerIdentity     = Read-Default "Server identity name" $Script:Config.ServerIdentity
    $Script:Config.Hostname           = Read-Default "Server hostname" $Script:Config.Hostname
    $Script:Config.Description        = Read-Default "Server description" $Script:Config.Description
    $Script:Config.ServerPort         = [int](Read-Default "Server port" $Script:Config.ServerPort)
    $Script:Config.QueryPort          = [int](Read-Default "Query port" $Script:Config.QueryPort)
    $Script:Config.RCONPort           = [int](Read-Default "RCON port" $Script:Config.RCONPort)

    $rconPass = Read-Host "RCON password [leave blank to auto-generate]"
    if ([string]::IsNullOrWhiteSpace($rconPass)) {
        $rconPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        Write-Host "Generated RCON password: $rconPass" -ForegroundColor Yellow
    }
    $Script:Config.RCONPassword = $rconPass

    $Script:Config.MaxPlayers = [int](Read-Default "Max players" $Script:Config.MaxPlayers)
    $Script:Config.WorldSize  = [int](Read-Default "World size" $Script:Config.WorldSize)

    $seedInput = Read-Host "Map seed [leave blank for random]"
    if ([string]::IsNullOrWhiteSpace($seedInput)) {
        $Script:Config.Seed = Get-Random -Minimum 1 -Maximum 999999999
        Write-Host "Generated seed: $($Script:Config.Seed)" -ForegroundColor Yellow
    } else {
        $Script:Config.Seed = [int]$seedInput
    }

    Write-Host ""
    Write-Host "Map type: 'Procedural Map', 'Barren', 'CraggyIsland', 'HapisIsland' - or leave blank to use a custom map URL"
    $Script:Config.Level = Read-Default "Map type" $Script:Config.Level
    if ([string]::IsNullOrWhiteSpace($Script:Config.Level)) {
        $Script:Config.LevelURL = Read-Host "Custom map download URL"
    }

    $Script:Config.SaveInterval = [int](Read-Default "Save interval (seconds)" $Script:Config.SaveInterval)
    $Script:Config.TickRate     = [int](Read-Default "Tick rate" $Script:Config.TickRate)

    Write-Host ""
    Write-Host "=== Nightly Maintenance Schedule ===" -ForegroundColor Cyan
    $nightlyAns = Read-Default "Enable nightly restart? (y/n)" $(if ($Script:Config.NightlyRestartEnabled) { "y" } else { "n" })
    $Script:Config.NightlyRestartEnabled = ($nightlyAns -match '^(y|yes)$')

    if ($Script:Config.NightlyRestartEnabled) {
        $Script:Config.NightlyRestartTime = Read-Default "Nightly restart time (24h HH:mm)" $Script:Config.NightlyRestartTime

        Write-Host "Wipe schedule options: None, Daily, Weekly, BiWeekly, Monthly"
        $Script:Config.WipeSchedule = Read-Default "Wipe schedule" $Script:Config.WipeSchedule

        if ($Script:Config.WipeSchedule -in @('Weekly', 'BiWeekly', 'Monthly')) {
            $Script:Config.WipeDayOfWeek = Read-Default "Wipe day of week" $Script:Config.WipeDayOfWeek
        }
        if ($Script:Config.WipeSchedule -eq 'Monthly') {
            Write-Host "Week-of-month options: First, Second, Third, Fourth, Last"
            $Script:Config.WipeWeekOfMonth = Read-Default "Which occurrence in the month" $Script:Config.WipeWeekOfMonth
        }
    }

    Save-RustServerConfig
}

# ============================================================
# Derived paths
# ============================================================

function Get-DerivedPaths {
    [PSCustomObject]@{
        Executable         = Join-Path $Script:Config.RustGamePath "RustDedicated.exe"
        ServerIdentityPath = Join-Path $Script:Config.RustGamePath "server\$($Script:Config.ServerIdentity)"
        LogFile            = Join-Path $Script:Config.RustGamePath "server\$($Script:Config.ServerIdentity)\$($Script:Config.ServerIdentity)_logs.txt"
    }
}

# ============================================================
# Helpers
# ============================================================

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] $Message"
    $logDir = $Script:Config.RustServerRootPath
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path (Join-Path $logDir "Manage-RustServer.log") -Value $LogEntry
    Write-Host $LogEntry
}

function Get-RustServerProcess {
    $paths = Get-DerivedPaths
    Get-Process -Name "RustDedicated" -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $paths.Executable }
}

# ============================================================
# Core server management
# ============================================================

function Start-RustServer {
    $paths = Get-DerivedPaths
    Write-Log "Attempting to start Rust server."

    if (Get-RustServerProcess) {
        Write-Log "RustDedicated process already running."
        return
    }

    if (-not (Test-Path $paths.Executable)) {
        Write-Log "ERROR: RustDedicated.exe not found at $($paths.Executable). Aborting start."
        return
    }

    Write-Log "Starting RustDedicated.exe..."
    Set-Location $Script:Config.RustGamePath

    $arguments = @(
        "-batchmode",
        "-nographics",
        "-logfile `"$($paths.LogFile)`"",
        "+server.port $($Script:Config.ServerPort)",
        "+server.queryport $($Script:Config.QueryPort)",
        "+rcon.port $($Script:Config.RCONPort)",
        "+rcon.password `"$($Script:Config.RCONPassword)`"",
        "+rcon.web 1",
        "+server.hostname `"$($Script:Config.Hostname)`"",
        "+server.identity `"$($Script:Config.ServerIdentity)`"",
        "+server.maxplayers $($Script:Config.MaxPlayers)",
        "+server.saveinterval $($Script:Config.SaveInterval)",
        "+server.tickrate $($Script:Config.TickRate)"
    )

    if (-not [string]::IsNullOrWhiteSpace($Script:Config.LevelURL)) {
        $arguments += "-levelurl `"$($Script:Config.LevelURL)`""
    } else {
        $arguments += "+server.level `"$($Script:Config.Level)`""
        $arguments += "+server.seed $($Script:Config.Seed)"
        $arguments += "+server.worldsize $($Script:Config.WorldSize)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:Config.Description)) {
        $arguments += "+server.description `"$($Script:Config.Description)`""
    }
    if (-not [string]::IsNullOrWhiteSpace($Script:Config.HeaderImage)) {
        $arguments += "+server.headerimage `"$($Script:Config.HeaderImage)`""
    }
    if (-not [string]::IsNullOrWhiteSpace($Script:Config.ServerURL)) {
        $arguments += "+server.url `"$($Script:Config.ServerURL)`""
    }

    Start-Process -FilePath $paths.Executable -ArgumentList $arguments -NoNewWindow -PassThru | Out-Null

    Start-Sleep -Seconds 10
    if (Get-RustServerProcess) {
        Write-Log "Rust server started successfully."
    } else {
        Write-Log "ERROR: Rust server failed to start."
    }
}

function Stop-RustServer {
    Write-Log "Attempting to stop Rust server."
    $process = Get-RustServerProcess

    if (-not $process) {
        Write-Log "RustDedicated process not found or already stopped."
        return
    }

    # Note: this force-terminates the process. For a graceful shutdown, send
    # the 'quit' or 'server.save' RCON command via an RCON client before
    # calling this, then give the server a few seconds to exit on its own.
    Write-Log "Terminating RustDedicated process."
    Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue

    $process | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue

    if (-not (Get-RustServerProcess)) {
        Write-Log "RustDedicated process stopped successfully."
    } else {
        Write-Log "WARNING: RustDedicated process might still be running after force termination."
    }
}

function Restart-RustServer {
    Write-Log "Initiating Rust server restart."
    Stop-RustServer
    Start-Sleep -Seconds 15
    Start-RustServer
    Write-Log "Rust server restart completed."
}

function Update-RustServer {
    Write-Log "Initiating Rust server update."
    Stop-RustServer

    $steamCmdExe = Join-Path $Script:Config.SteamCmdPath "steamcmd.exe"
    if (-not (Test-Path $steamCmdExe)) {
        Write-Log "ERROR: SteamCMD not found at $steamCmdExe. Aborting update."
        return
    }

    Write-Log "Running SteamCMD update..."
    Set-Location $Script:Config.SteamCmdPath
    & $steamCmdExe +force_install_dir "$($Script:Config.RustGamePath)" +login anonymous +app_update 258550 validate +quit

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Rust server files updated successfully."
    } else {
        Write-Log "ERROR: SteamCMD update failed with exit code $LASTEXITCODE."
    }

    Start-RustServer
    Write-Log "Rust server update completed."
}

function Wipe-RustServer {
    param([switch]$Force)

    $paths = Get-DerivedPaths
    Write-Log "Initiating Rust server wipe process."

    if (-not $Force) {
        $response = Read-Host "Are you sure you want to wipe the server? This will delete all player data and map files! (Type 'YES' to confirm)"
        if ($response -ne "YES") {
            Write-Log "Server wipe cancelled by user."
            return
        }
    }

    Stop-RustServer

    Write-Log "Deleting server data in $($paths.ServerIdentityPath)..."
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.sav" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.map" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.db" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue

    Remove-Item -Path "$($paths.ServerIdentityPath)\player.blueprints*" -ErrorAction SilentlyContinue -Force
    Remove-Item -Path "$($paths.ServerIdentityPath)\player.data*" -ErrorAction SilentlyContinue -Force
    Remove-Item -Path "$($paths.ServerIdentityPath)\pvp.stats*" -ErrorAction SilentlyContinue -Force
    Remove-Item -Path "$($paths.ServerIdentityPath)\storage\*" -Recurse -ErrorAction SilentlyContinue -Force

    # Change the seed so the new map isn't identical to the old one
    $Script:Config.Seed = Get-Random -Minimum 1 -Maximum 999999999
    Save-RustServerConfig
    Write-Log "Server seed changed to $($Script:Config.Seed) for the new map."

    Write-Log "Server data wiped. Starting server again."
    Start-RustServer
}

# ============================================================
# Nightly maintenance - decides restart vs. wipe
# ============================================================

function Test-IsWipeDay {
    if ($Script:Config.WipeSchedule -eq 'None') { return $false }

    $today = Get-Date

    switch ($Script:Config.WipeSchedule) {
        'Daily' { return $true }

        'Weekly' {
            return $today.DayOfWeek.ToString() -eq $Script:Config.WipeDayOfWeek
        }

        'BiWeekly' {
            if ($today.DayOfWeek.ToString() -ne $Script:Config.WipeDayOfWeek) { return $false }
            $week = [System.Globalization.ISOWeek]::GetWeekOfYear($today)
            return ($week % 2) -eq 0
        }

        'Monthly' {
            if ($today.DayOfWeek.ToString() -ne $Script:Config.WipeDayOfWeek) { return $false }
            # Find every date in this month matching the target day of week
            $matches = 1..([DateTime]::DaysInMonth($today.Year, $today.Month)) |
                ForEach-Object { Get-Date -Year $today.Year -Month $today.Month -Day $_ } |
                Where-Object { $_.DayOfWeek.ToString() -eq $Script:Config.WipeDayOfWeek }

            switch ($Script:Config.WipeWeekOfMonth) {
                'First'  { return $today.Day -eq $matches[0].Day }
                'Second' { return $matches.Count -ge 2 -and $today.Day -eq $matches[1].Day }
                'Third'  { return $matches.Count -ge 3 -and $today.Day -eq $matches[2].Day }
                'Fourth' { return $matches.Count -ge 4 -and $today.Day -eq $matches[3].Day }
                'Last'   { return $today.Day -eq $matches[-1].Day }
                default  { return $false }
            }
        }

        default { return $false }
    }
}

function Invoke-NightlyMaintenance {
    if (-not $Script:Config.NightlyRestartEnabled) {
        Write-Log "Nightly maintenance is disabled in config - skipping."
        return
    }

    if (Test-IsWipeDay) {
        Write-Log "Tonight is a scheduled wipe night ($($Script:Config.WipeSchedule))."
        Wipe-RustServer -Force
    } else {
        Write-Log "Tonight is a normal restart night."
        Restart-RustServer
    }
}

# ============================================================
# Entry point
# ============================================================

if ($Action -ne 'generate-config') {
    Import-RustServerConfig
}

switch ($Action) {
    "start"           { Start-RustServer }
    "stop"            { Stop-RustServer }
    "restart"         { Restart-RustServer }
    "update"          { Update-RustServer }
    "wipe"            { Wipe-RustServer -Force:$ForceWipe }
    "nightly"         { Invoke-NightlyMaintenance }
    "generate-config" { Import-RustServerConfig; New-RustServerConfigInteractive }
}
