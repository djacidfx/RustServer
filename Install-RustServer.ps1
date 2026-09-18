<#
.SYNOPSIS
    Interactive installer/setup wizard for a Rust Dedicated Server on Windows.

.DESCRIPTION
    - Asks where you want everything installed.
    - Downloads and installs SteamCMD if it isn't already present.
    - Installs (or updates) the Rust Dedicated Server via SteamCMD.
    - Walks you through server settings (hostname, ports, RCON password,
      map/seed, etc.) and saves them to RustServer.config.json.
    - Optionally opens the required firewall ports.
    - Optionally creates a Windows scheduled task for a nightly restart,
      with an optional wipe schedule (daily / weekly / biweekly / monthly).
    - Copies Manage-RustServer.ps1 (the day-to-day start/stop/update/wipe
      script) next to the install, wired up to the config it just created.

.NOTES
    Run this from an elevated (Administrator) PowerShell window so it can
    create firewall rules and the scheduled task. It will still work
    without elevation, just skipping those two steps.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host ">> $msg" -ForegroundColor Cyan
}

function Read-Default {
    param([string]$Prompt, $Default)
    $val = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "   Rust Dedicated Server - Installer / Setup Wizard" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

$isAdmin = Test-IsAdmin
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. Firewall rules and the scheduled task will be skipped. Re-run elevated to enable those."
}

# ------------------------------------------------------------
# 1. Paths
# ------------------------------------------------------------
Write-Step "Where should everything be installed?"

Write-Host "The install root folder is the top-level folder for this server"
Write-Host "instance - it holds SteamCMD, the Rust game files, your config file,"
Write-Host "and the log. Most people only need to set this one and can accept"
Write-Host "the defaults for the two sub-folders below it."
Write-Host ""

$RootPath = Read-Default "Install root folder (everything else lives under here)" "C:\RustServer"

Write-Host ""
Write-Host "SteamCMD is Valve's tool used to download/update the Rust server files."
$SteamCmdPath = Read-Default "SteamCMD folder" (Join-Path $RootPath "SteamCMD")

Write-Host ""
Write-Host "This is where the actual Rust Dedicated Server (RustDedicated.exe,"
Write-Host "the map, and player/save data) gets installed - a sub-folder of the"
Write-Host "install root above, not a separate location."
$RustGamePath = Read-Default "Rust game folder" (Join-Path $RootPath "rust_game")

$ServerIdentity = Read-Default "Server identity name (save-data folder under rust_game\server\)" "RustServer"

foreach ($p in @($RootPath, $SteamCmdPath, $RustGamePath)) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Write-Host "Created $p"
    }
}

# ------------------------------------------------------------
# 2. SteamCMD
# ------------------------------------------------------------
Write-Step "SteamCMD"

$steamCmdExe = Join-Path $SteamCmdPath "steamcmd.exe"
if (Test-Path $steamCmdExe) {
    Write-Host "SteamCMD already present at $steamCmdExe - skipping download."
} else {
    $zipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
    $zipPath = Join-Path $env:TEMP "steamcmd.zip"

    Write-Host "Downloading SteamCMD from $zipUrl ..."
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Error "Failed to download SteamCMD: $_`nYou can download it manually from https://developer.valvesoftware.com/wiki/SteamCMD and extract it to $SteamCmdPath, then re-run this script."
        exit 1
    }

    Write-Host "Extracting to $SteamCmdPath ..."
    Expand-Archive -Path $zipPath -DestinationPath $SteamCmdPath -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # First run bootstraps SteamCMD itself (updates its own files)
    Write-Host "Running SteamCMD once to let it self-update ..."
    Set-Location $SteamCmdPath
    & $steamCmdExe +quit
}

# ------------------------------------------------------------
# 3. Install / update Rust Dedicated Server
# ------------------------------------------------------------
Write-Step "Installing the Rust Dedicated Server (app 258550) - this can take a while"

Set-Location $SteamCmdPath
& $steamCmdExe +force_install_dir "$RustGamePath" +login anonymous +app_update 258550 validate +quit

if ($LASTEXITCODE -ne 0) {
    Write-Warning "SteamCMD exited with code $LASTEXITCODE. The install may be incomplete - you can re-run this script, or run Manage-RustServer.ps1 -Action update later."
} else {
    Write-Host "Rust Dedicated Server installed/updated successfully." -ForegroundColor Green
}

# ------------------------------------------------------------
# 4. Server settings
# ------------------------------------------------------------
Write-Step "Server settings"

$Hostname    = Read-Default "Server hostname" "My Awesome Rust Server"
$Description = Read-Default "Server description" "A friendly Rust server."
$ServerPort  = [int](Read-Default "Server port" 28015)
$QueryPort   = [int](Read-Default "Query port" 28017)
$RCONPort    = [int](Read-Default "RCON port" 28016)

$rconPass = Read-Host "RCON password [leave blank to auto-generate a random one]"
if ([string]::IsNullOrWhiteSpace($rconPass)) {
    $rconPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    Write-Host "Generated RCON password: $rconPass" -ForegroundColor Yellow
}

$MaxPlayers = [int](Read-Default "Max players" 150)
$WorldSize  = [int](Read-Default "World size" 4500)

$seedInput = Read-Host "Map seed [leave blank for random]"
if ([string]::IsNullOrWhiteSpace($seedInput)) {
    $Seed = Get-Random -Minimum 1 -Maximum 999999999
    Write-Host "Generated seed: $Seed" -ForegroundColor Yellow
} else {
    $Seed = [int]$seedInput
}

Write-Host ""
Write-Host "Map type: 'Procedural Map', 'Barren', 'CraggyIsland', 'HapisIsland' - or leave blank to use a custom map URL"
$Level = Read-Default "Map type" "Procedural Map"
$LevelURL = ""
if ([string]::IsNullOrWhiteSpace($Level)) {
    $LevelURL = Read-Host "Custom map download URL"
}

$SaveInterval = [int](Read-Default "Save interval (seconds)" 300)
$TickRate     = [int](Read-Default "Tick rate" 30)

# ------------------------------------------------------------
# 5. Nightly restart / wipe schedule
# ------------------------------------------------------------
Write-Step "Nightly restart & wipe schedule"

$nightlyAns = Read-Default "Enable a nightly restart? (y/n)" "y"
$NightlyRestartEnabled = ($nightlyAns -match '^(y|yes)$')
$NightlyRestartTime = "04:00"
$WipeSchedule = "None"
$WipeDayOfWeek = "Thursday"
$WipeWeekOfMonth = "First"

if ($NightlyRestartEnabled) {
    $NightlyRestartTime = Read-Default "What time should the nightly restart run? (24h HH:mm)" "04:00"

    Write-Host ""
    Write-Host "Wipe schedule options:"
    Write-Host "  None      - never auto-wipe, just restart nightly"
    Write-Host "  Daily     - wipe every night"
    Write-Host "  Weekly    - wipe on a chosen day every week"
    Write-Host "  BiWeekly  - wipe on a chosen day every other week"
    Write-Host "  Monthly   - wipe on a chosen occurrence each month (e.g. 'First Thursday', the classic Rust forced-wipe schedule)"
    $WipeSchedule = Read-Default "Wipe schedule" "Monthly"

    if ($WipeSchedule -in @('Weekly', 'BiWeekly', 'Monthly')) {
        $WipeDayOfWeek = Read-Default "Wipe day of week" "Thursday"
    }
    if ($WipeSchedule -eq 'Monthly') {
        $WipeWeekOfMonth = Read-Default "Which occurrence in the month (First/Second/Third/Fourth/Last)" "First"
    }
}

# ------------------------------------------------------------
# 6. Write config.json
# ------------------------------------------------------------
Write-Step "Saving configuration"

$Config = [ordered]@{
    SteamCmdPath          = $SteamCmdPath
    RustServerRootPath    = $RootPath
    RustGamePath          = $RustGamePath
    ServerIdentity        = $ServerIdentity
    RCONPassword          = $rconPass
    ServerPort            = $ServerPort
    RCONPort              = $RCONPort
    QueryPort             = $QueryPort
    WorldSize             = $WorldSize
    Seed                  = $Seed
    MaxPlayers            = $MaxPlayers
    Hostname              = $Hostname
    Description           = $Description
    HeaderImage           = ""
    ServerURL             = ""
    Level                 = $Level
    LevelURL              = $LevelURL
    SaveInterval          = $SaveInterval
    TickRate              = $TickRate
    NightlyRestartEnabled = $NightlyRestartEnabled
    NightlyRestartTime    = $NightlyRestartTime
    WipeSchedule          = $WipeSchedule
    WipeDayOfWeek         = $WipeDayOfWeek
    WipeWeekOfMonth       = $WipeWeekOfMonth
}

$ConfigPath = Join-Path $RootPath "RustServer.config.json"
$Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
Write-Host "Saved $ConfigPath" -ForegroundColor Green

# ------------------------------------------------------------
# 7. Copy Manage-RustServer.ps1 next to the install
# ------------------------------------------------------------
Write-Step "Deploying the management script"

$manageSource = Join-Path $PSScriptRoot "Manage-RustServer.ps1"
$manageDest   = Join-Path $RootPath "Manage-RustServer.ps1"

if (Test-Path $manageSource) {
    Copy-Item -Path $manageSource -Destination $manageDest -Force
    Write-Host "Copied Manage-RustServer.ps1 to $manageDest"
} else {
    Write-Warning "Manage-RustServer.ps1 was not found next to this installer. Place it in $RootPath manually - the config file it needs ($ConfigPath) is already set up."
}

# ------------------------------------------------------------
# 8. Firewall rules (requires admin)
# ------------------------------------------------------------
if ($isAdmin) {
    Write-Step "Firewall rules"
    $fwAns = Read-Default "Open the server/query/RCON ports in Windows Firewall now? (y/n)" "y"
    if ($fwAns -match '^(y|yes)$') {
        $rules = @(
            @{ Name = "Rust Server - Game Port ($ServerIdentity)"; Port = $ServerPort; Protocol = "UDP" },
            @{ Name = "Rust Server - Query Port ($ServerIdentity)"; Port = $QueryPort; Protocol = "UDP" },
            @{ Name = "Rust Server - RCON Port ($ServerIdentity)"; Port = $RCONPort; Protocol = "TCP" }
        )
        foreach ($r in $rules) {
            if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Protocol -LocalPort $r.Port -Action Allow | Out-Null
                Write-Host "Opened $($r.Protocol) port $($r.Port) ($($r.Name))"
            } else {
                Write-Host "Rule '$($r.Name)' already exists - skipping."
            }
        }
    }
}

# ------------------------------------------------------------
# 9. Scheduled task for nightly restart/wipe (requires admin)
# ------------------------------------------------------------
if ($isAdmin -and $NightlyRestartEnabled) {
    Write-Step "Scheduled task"
    $taskName = "RustServer - Nightly Maintenance ($ServerIdentity)"

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "A scheduled task named '$taskName' already exists - removing it first."
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$manageDest`" -Action nightly"
    $trigger = New-ScheduledTaskTrigger -Daily -At $NightlyRestartTime
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Write-Host "Created scheduled task '$taskName' - runs daily at $NightlyRestartTime." -ForegroundColor Green
    if ($WipeSchedule -ne 'None') {
        $occurrenceNote = if ($WipeSchedule -eq 'Monthly') { ", occurrence: $WipeWeekOfMonth" } else { "" }
        Write-Host "It will wipe instead of restart according to the '$WipeSchedule' schedule (day: $WipeDayOfWeek$occurrenceNote)."
    }
} elseif ($NightlyRestartEnabled -and -not $isAdmin) {
    Write-Warning "Skipped creating the scheduled task because this script isn't running as Administrator. Re-run this installer elevated, or create the task yourself:`n  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$manageDest`" -Action nightly`n  (trigger: daily at $NightlyRestartTime)"
}

# ------------------------------------------------------------
# 10. Done - optionally start now
# ------------------------------------------------------------
Write-Step "Setup complete"

Write-Host "Install root:      $RootPath  (top-level folder for this server)"
Write-Host "Rust game folder:  $RustGamePath  (RustDedicated.exe + save data, inside the root)"
Write-Host "Config file:       $ConfigPath"
Write-Host "Management script: $manageDest"
Write-Host "RCON password:     $rconPass"
Write-Host ""

$startAns = Read-Default "Start the Rust server now? (y/n)" "y"
if ($startAns -match '^(y|yes)$') {
    & $manageDest -Action start
} else {
    Write-Host "You can start it any time with:"
    Write-Host "  powershell.exe -File `"$manageDest`" -Action start"
}
