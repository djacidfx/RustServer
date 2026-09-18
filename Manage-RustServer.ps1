<#
.SYNOPSIS
    Centralized Rust Dedicated Server Manager on Windows.

.DESCRIPTION
    Provides automated start, stop, graceful save/shutdown via WebRCON,
    update, backup, wipe, and scheduled maintenance.
    If run with no arguments, opens an interactive, numbered control menu.

.PARAMETER Action
    start, stop, restart, update, backup, wipe, nightly, generate-config, status

.PARAMETER WipeType
    MapOnly (preserves blueprints) or Full (erases all data and blueprints). Default: MapOnly.

.PARAMETER ForceWipe
    Skips user confirmation for wipes (used by automated tasks).

.PARAMETER ConfigPath
    Path to the JSON config file.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'update', 'backup', 'wipe', 'nightly', 'generate-config', 'status', '')]
    [string]$Action = '',

    [ValidateSet('MapOnly', 'Full')]
    [string]$WipeType = 'MapOnly',

    [switch]$ForceWipe,

    [string]$ConfigPath = (Join-Path $PSScriptRoot "RustServer.config.json")
)

$Script:Config = [ordered]@{
    SteamCmdPath          = "C:\RustServer\SteamCMD"
    RustServerRootPath    = "C:\RustServer"
    RustGamePath          = "C:\RustServer\rust_game"
    ServerIdentity        = "RustServer"
    RCONPassword          = "changeme"
    ServerPort            = 28015
    RCONPort              = 28016
    QueryPort             = 28017
    WorldSize             = 4250
    Seed                  = 12345
    MaxPlayers            = 100
    Hostname              = "My Rust Community Server"
    Description           = "A friendly Rust server."
    HeaderImage           = ""
    ServerURL             = ""
    Level                 = "Procedural Map"
    LevelURL              = ""
    SaveInterval          = 300
    TickRate              = 30
    NightlyRestartEnabled = $true
    NightlyRestartTime    = "04:00"
    WipeSchedule          = "None"
    WipeDayOfWeek         = "Thursday"
    WipeWeekOfMonth       = "First"
}

# ============================================================
# Config Helpers
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
            Write-Warning "Failed to parse '$ConfigPath' - using default values: $_"
        }
    } else {
        Write-Warning "Config file not found at '$ConfigPath'. Using defaults."
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

function Get-DerivedPaths {
    $backupDir = Join-Path $Script:Config.RustServerRootPath "backups"
    [PSCustomObject]@{
        Executable         = Join-Path $Script:Config.RustGamePath "RustDedicated.exe"
        ServerIdentityPath = Join-Path $Script:Config.RustGamePath "server\$($Script:Config.ServerIdentity)"
        LogFile            = Join-Path $Script:Config.RustGamePath "server\$($Script:Config.ServerIdentity)\$($Script:Config.ServerIdentity)_log.txt"
        BackupFolder       = $backupDir
    }
}

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
    Get-Process -Name "RustDedicated" -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -eq $paths.Executable -or $_.MainModule.FileName -eq $paths.Executable
        } catch {
            $true
        }
    }
}

# ============================================================
# Graceful WebRCON Client (PowerShell Native)
# ============================================================

function Send-RconCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TimeoutSeconds = 5
    )

    $rconPort = $Script:Config.RCONPort
    $rconPass = $Script:Config.RCONPassword

    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))

        $uri = [System.Uri]"ws://127.0.0.1:$rconPort/$rconPass"
        $connectTask = $ws.ConnectAsync($uri, $cts.Token)
        $connectTask.Wait()

        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $payload = @{
                Identifier = 1001
                Message    = $Command
                Name       = "WebRcon"
            } | ConvertTo-Json -Compress

            $buffer = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $segment = New-Object System.ArraySegment[byte] -ArgumentList @($buffer, 0, $buffer.Length)
            $sendTask = $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
            $sendTask.Wait()

            Start-Sleep -Milliseconds 500
            $closeTask = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", $cts.Token)
            $closeTask.Wait()
            return $true
        }
    } catch {
        # Fallback if WebSocket connection cannot be established
        return $false
    }
    return $false
}

# ============================================================
# Core Server Actions
# ============================================================

function Start-RustServer {
    $paths = Get-DerivedPaths
    Write-Log "Checking Rust server status..."

    if (Get-RustServerProcess) {
        Write-Log "RustDedicated is already running."
        return
    }

    if (-not (Test-Path $paths.Executable)) {
        Write-Log "ERROR: RustDedicated.exe not found at $($paths.Executable). Please update/install first."
        return
    }

    Write-Log "Starting RustDedicated.exe in background..."
    Set-Location $Script:Config.RustGamePath

    # Ensure identity directory exists for logs
    if (-not (Test-Path $paths.ServerIdentityPath)) {
        New-Item -ItemType Directory -Path $paths.ServerIdentityPath -Force | Out-Null
    }

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

    Start-Process -FilePath $paths.Executable -ArgumentList $arguments -NoNewWindow | Out-Null

    Write-Host "Waiting for server process initialization (10 seconds)..." -ForegroundColor Gray
    Start-Sleep -Seconds 10

    if (Get-RustServerProcess) {
        Write-Log "Rust Dedicated Server successfully started."
    } else {
        Write-Log "ERROR: Rust server process exited unexpectedly. Check $($paths.LogFile) for error details."
    }
}

function Stop-RustServer {
    Write-Log "Stopping Rust server..."
    $process = Get-RustServerProcess

    if (-not $process) {
        Write-Log "RustDedicated process is not running."
        return
    }

    # Attempt 1: Graceful save & quit via WebRCON
    Write-Log "Attempting graceful save and shutdown via WebRCON..."
    $saveOk = Send-RconCommand -Command "server.save"
    if ($saveOk) {
        Send-RconCommand -Command "quit"
        Write-Log "Sent 'server.save' and 'quit' commands. Waiting for server to exit cleanly..."
        $process | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
    }

    # Attempt 2: If process is still active, terminate cleanly
    if (Get-RustServerProcess) {
        Write-Log "Process did not exit after WebRCON command. Terminating process directly..."
        Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue
        $process | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    }

    if (-not (Get-RustServerProcess)) {
        Write-Log "RustDedicated process stopped successfully."
    } else {
        Write-Log "WARNING: Process could not be stopped."
    }
}

function Restart-RustServer {
    Write-Log "Restarting Rust server..."
    Stop-RustServer
    Start-Sleep -Seconds 5
    Start-RustServer
    Write-Log "Restart complete."
}

function Update-RustServer {
    Write-Log "Starting server update via SteamCMD..."
    Stop-RustServer

    $steamCmdExe = Join-Path $Script:Config.SteamCmdPath "steamcmd.exe"
    if (-not (Test-Path $steamCmdExe)) {
        Write-Log "ERROR: SteamCMD not found at $steamCmdExe. Aborting update."
        return
    }

    Set-Location $Script:Config.SteamCmdPath
    & $steamCmdExe +force_install_dir "$($Script:Config.RustGamePath)" +login anonymous +app_update 258550 validate +quit

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Rust server updated successfully."
    } else {
        Write-Log "ERROR: SteamCMD update exited with code $LASTEXITCODE."
    }

    Start-RustServer
}

function Backup-RustServerData {
    $paths = Get-DerivedPaths
    if (-not (Test-Path $paths.ServerIdentityPath)) {
        Write-Log "No save data found to back up in $($paths.ServerIdentityPath)."
        return
    }

    if (-not (Test-Path $paths.BackupFolder)) {
        New-Item -ItemType Directory -Path $paths.BackupFolder -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipName = "Backup-$($Script:Config.ServerIdentity)-$timestamp.zip"
    $zipPath = Join-Path $paths.BackupFolder $zipName

    Write-Log "Creating backup: $zipPath..."
    try {
        Compress-Archive -Path "$($paths.ServerIdentityPath)\*" -DestinationPath $zipPath -Force
        Write-Log "Backup completed successfully ($zipName)."
    } catch {
        Write-Log "WARNING: Failed to create zip backup: $_"
    }
}

function Wipe-RustServer {
    param(
        [string]$Type = "MapOnly",
        [switch]$Force
    )

    $paths = Get-DerivedPaths
    Write-Log "Initiating server wipe ($Type)..."

    if (-not $Force) {
        Write-Host ""
        Write-Host "WARNING: A wipe will erase the current map and player structures." -ForegroundColor Red
        if ($Type -eq "Full") {
            Write-Host "FULL WIPE SELECTED: Player blueprints and tech-tree unlocks will ALSO be erased." -ForegroundColor Red
        } else {
            Write-Host "MAP WIPE SELECTED: Player blueprints will be PRESERVED." -ForegroundColor Green
        }
        $confirm = Read-Host "Type 'YES' to proceed with wiping"
        if ($confirm -ne "YES") {
            Write-Log "Server wipe cancelled by user."
            return
        }
    }

    # Always create a backup before wiping for safety!
    Stop-RustServer
    Backup-RustServerData

    Write-Log "Removing map and world save files in $($paths.ServerIdentityPath)..."
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.sav" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.map" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path $paths.ServerIdentityPath -Filter "*.db" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$($paths.ServerIdentityPath)\storage\*" -Recurse -ErrorAction SilentlyContinue -Force

    if ($Type -eq "Full") {
        Write-Log "Erasing player blueprints, data, and stats (Full Wipe)..."
        Remove-Item -Path "$($paths.ServerIdentityPath)\player.blueprints*" -ErrorAction SilentlyContinue -Force
        Remove-Item -Path "$($paths.ServerIdentityPath)\player.data*" -ErrorAction SilentlyContinue -Force
        Remove-Item -Path "$($paths.ServerIdentityPath)\pvp.stats*" -ErrorAction SilentlyContinue -Force
    }

    # Generate a fresh seed for the new map
    $Script:Config.Seed = Get-Random -Minimum 100000 -Maximum 999999999
    Save-RustServerConfig
    Write-Log "Generated new map seed: $($Script:Config.Seed)"

    Write-Log "Wipe finished. Starting server with new map..."
    Start-RustServer
}

function Show-ServerStatus {
    $paths = Get-DerivedPaths
    $proc = Get-RustServerProcess

    Write-Host ""
    Write-Host "=== Rust Server Status ===" -ForegroundColor Cyan
    if ($proc) {
        $workingSetMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        Write-Host "State:         ONLINE" -ForegroundColor Green
        Write-Host "Process ID:    $($proc.Id)"
        Write-Host "Memory Usage:  $workingSetMb MB"
        Write-Host "Start Time:    $($proc.StartTime)"
    } else {
        Write-Host "State:         OFFLINE" -ForegroundColor Red
    }
    Write-Host "Hostname:      $($Script:Config.Hostname)"
    Write-Host "Identity:      $($Script:Config.ServerIdentity)"
    Write-Host "Game Port:     $($Script:Config.ServerPort) (UDP)"
    Write-Host "Query Port:    $($Script:Config.QueryPort) (UDP)"
    Write-Host "RCON Port:     $($Script:Config.RCONPort) (TCP)"
    Write-Host "Map Seed:      $($Script:Config.Seed) | Size: $($Script:Config.WorldSize)"
    Write-Host "Log File:      $($paths.LogFile)"
    Write-Host ""
}

# ============================================================
# Scheduled Maintenance (Restart vs. Wipe)
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
            # Compatible with both Windows PowerShell 5.1 and PS 7+
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $week = $culture.Calendar.GetWeekOfYear($today, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
            return ($week % 2) -eq 0
        }

        'Monthly' {
            if ($today.DayOfWeek.ToString() -ne $Script:Config.WipeDayOfWeek) { return $false }
            $daysInMonth = [DateTime]::DaysInMonth($today.Year, $today.Month)
            $matches = 1..$daysInMonth |
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
        Write-Log "Nightly maintenance is disabled in config."
        return
    }

    if (Test-IsWipeDay) {
        Write-Log "Scheduled maintenance: Today is a WIPE day ($($Script:Config.WipeSchedule))."
        Wipe-RustServer -Type "MapOnly" -Force
    } else {
        Write-Log "Scheduled maintenance: Performing regular nightly restart."
        Restart-RustServer
    }
}

# ============================================================
# Interactive Menu
# ============================================================

function Show-Menu {
    Import-RustServerConfig
    while ($true) {
        $proc = Get-RustServerProcess
        $statusText = if ($proc) { "ONLINE (PID: $($proc.Id))" } else { "OFFLINE" }
        $statusColor = if ($proc) { "Green" } else { "Red" }

        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "             Rust Dedicated Server Manager                " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "Server: $($Script:Config.Hostname)" -ForegroundColor White
        Write-Host "Status: " -NoNewline
        Write-Host $statusText -ForegroundColor $statusColor
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host " [1] Start Server"
        Write-Host " [2] Stop Server (Graceful Save & Quit)"
        Write-Host " [3] Restart Server"
        Write-Host " [4] Update Server (SteamCMD)"
        Write-Host " [5] Backup Server Data"
        Write-Host " [6] Wipe Server (Map Wipe - Keep Blueprints)"
        Write-Host " [7] Wipe Server (Full Wipe - Reset Everything)"
        Write-Host " [8] View Detailed Status & Port Info"
        Write-Host " [9] Open Server Log File"
        Write-Host " [Q] Quit"
        Write-Host "==========================================================" -ForegroundColor Cyan

        $choice = Read-Host "Select an option [1-9, Q]"
        switch ($choice) {
            "1" { Start-RustServer; Pause }
            "2" { Stop-RustServer; Pause }
            "3" { Restart-RustServer; Pause }
            "4" { Update-RustServer; Pause }
            "5" { Backup-RustServerData; Pause }
            "6" { Wipe-RustServer -Type "MapOnly"; Pause }
            "7" { Wipe-RustServer -Type "Full"; Pause }
            "8" { Show-ServerStatus; Pause }
            "9" {
                $paths = Get-DerivedPaths
                if (Test-Path $paths.LogFile) {
                    Start-Process notepad.exe $paths.LogFile
                } else {
                    Write-Host "Log file does not exist yet at $($paths.LogFile)" -ForegroundColor Yellow
                    Pause
                }
            }
            "Q" { exit 0 }
            "q" { exit 0 }
        }
    }
}

# ============================================================
# Main Dispatcher
# ============================================================

Import-RustServerConfig

if ([string]::IsNullOrWhiteSpace($Action)) {
    Show-Menu
} else {
    switch ($Action) {
        "start"           { Start-RustServer }
        "stop"            { Stop-RustServer }
        "restart"         { Restart-RustServer }
        "update"          { Update-RustServer }
        "backup"          { Backup-RustServerData }
        "wipe"            { Wipe-RustServer -Type $WipeType -Force:$ForceWipe }
        "nightly"         { Invoke-NightlyMaintenance }
        "status"          { Show-ServerStatus }
    }
}
