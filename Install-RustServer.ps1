<#
.SYNOPSIS
    Beginner-friendly interactive setup wizard for a Rust Dedicated Server on Windows.

.DESCRIPTION
    - Verifies system requirements (admin privileges, disk space, prerequisites).
    - Downloads and bootstraps SteamCMD automatically if not found.
    - Downloads/updates the Rust Dedicated Server (Steam App ID 258550).
    - Guides users through configuration prompts with sensible defaults.
    - Saves settings to RustServer.config.json.
    - Optionally opens required Windows Firewall ports (28015 UDP, 28016 TCP, 28017 UDP).
    - Optionally creates a Windows Scheduled Task for nightly restart and automated wipes.
    - Creates desktop shortcuts for easy access.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Banner {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       Rust Dedicated Server - Installation Wizard        " -ForegroundColor Cyan
    Write-Host "         https://github.com/djacidfx/RustServer           " -ForegroundColor DarkCyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host ">> $msg" -ForegroundColor Green
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

Write-Banner

# ------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------
$isAdmin = Test-IsAdmin
if (-not $isAdmin) {
    Write-Warning "This installer is NOT running as Administrator."
    Write-Host "Without Administrator privileges, the installer cannot automatically open"
    Write-Host "firewall ports or set up the nightly auto-wipe scheduled task."
    $elevate = Read-Default "Would you like to restart the installer as Administrator? (y/n)" "y"
    if ($elevate -match '^(y|yes)$') {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    }
}

# ------------------------------------------------------------
# 1. Install Locations & Disk Space Check
# ------------------------------------------------------------
Write-Step "Step 1: Choose Installation Folder"
Write-Host "Pick where your Rust server will live. A fast SSD drive is recommended." -ForegroundColor Gray

$RootPath       = Read-Default "Install root folder" "C:\RustServer"
$SteamCmdPath   = Read-Default "SteamCMD folder" (Join-Path $RootPath "SteamCMD")
$RustGamePath   = Read-Default "Rust game folder" (Join-Path $RootPath "rust_game")
$ServerIdentity = Read-Default "Server identity name (unique folder for map and saves)" "RustServer"

# Check available disk space on the target drive
$driveLetter = [System.IO.Path]::GetPathRoot($RootPath).Substring(0, 1)
$drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
if ($drive) {
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 20) {
        Write-Warning "Drive $driveLetter`: only has $freeGb GB free space. Rust Dedicated Server requires ~15-20 GB."
    } else {
        Write-Host "Target drive has $freeGb GB available." -ForegroundColor Gray
    }
}

foreach ($p in @($RootPath, $SteamCmdPath, $RustGamePath)) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Write-Host "Created directory: $p" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------
# 2. SteamCMD Setup
# ------------------------------------------------------------
Write-Step "Step 2: SteamCMD Setup"

$steamCmdExe = Join-Path $SteamCmdPath "steamcmd.exe"
if (Test-Path $steamCmdExe) {
    Write-Host "SteamCMD already detected at $steamCmdExe - skipping download." -ForegroundColor Green
} else {
    $zipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
    $zipPath = Join-Path $env:TEMP "steamcmd.zip"

    Write-Host "Downloading SteamCMD from Valve..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Error "Failed to download SteamCMD: $_`nPlease download manually from Valve and place steamcmd.exe in $SteamCmdPath."
        exit 1
    }

    Write-Host "Extracting SteamCMD..." -ForegroundColor Yellow
    Expand-Archive -Path $zipPath -DestinationPath $SteamCmdPath -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    Write-Host "Bootstrapping SteamCMD (first-run update)..." -ForegroundColor Yellow
    Set-Location $SteamCmdPath
    & $steamCmdExe +quit
}

# ------------------------------------------------------------
# 3. Download / Update Rust Dedicated Server
# ------------------------------------------------------------
Write-Step "Step 3: Downloading Rust Dedicated Server (Steam App 258550)"
Write-Host "This will download ~12-15 GB of files. Please be patient depending on your connection." -ForegroundColor Yellow

Set-Location $SteamCmdPath
& $steamCmdExe +force_install_dir "$RustGamePath" +login anonymous +app_update 258550 validate +quit

if ($LASTEXITCODE -ne 0) {
    Write-Warning "SteamCMD exited with status code $LASTEXITCODE. You can retry anytime via Manage-RustServer.ps1 -Action update."
} else {
    Write-Host "Rust Dedicated Server files installed successfully." -ForegroundColor Green
}

# ------------------------------------------------------------
# 4. Server Customization
# ------------------------------------------------------------
Write-Step "Step 4: Configure Your Server"

$Hostname    = Read-Default "Server Display Name" "My Rust Community Server"
$Description = Read-Default "Server Description" "Welcome! A friendly Rust server. Wipe schedule: Monthly."
$MaxPlayers  = [int](Read-Default "Max Players" 100)
$ServerPort  = [int](Read-Default "Game Port (UDP)" 28015)
$QueryPort   = [int](Read-Default "Query Port (UDP)" 28017)
$RCONPort    = [int](Read-Default "RCON Port (TCP)" 28016)

$rconPass = Read-Host "RCON Password [Press ENTER to auto-generate a secure password]"
if ([string]::IsNullOrWhiteSpace($rconPass)) {
    $rconPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    Write-Host "Generated RCON Password: $rconPass" -ForegroundColor Yellow
}

$WorldSize  = [int](Read-Default "World Map Size (3000 = Small, 4000-4500 = Standard)" 4250)

$seedInput = Read-Host "Map Seed [Press ENTER for random seed]"
if ([string]::IsNullOrWhiteSpace($seedInput)) {
    $Seed = Get-Random -Minimum 100000 -Maximum 999999999
    Write-Host "Generated Seed: $Seed" -ForegroundColor Yellow
} else {
    $Seed = [int]$seedInput
}

$Level = Read-Default "Map Type (Procedural Map, Barren, HapisIsland)" "Procedural Map"
$LevelURL = ""
if ([string]::IsNullOrWhiteSpace($Level) -or $Level -eq "Custom") {
    $LevelURL = Read-Host "Custom Map URL (.map file link)"
}

$SaveInterval = [int](Read-Default "Auto-Save Interval in Seconds" 300)
$TickRate     = [int](Read-Default "Server Tick Rate" 30)

# ------------------------------------------------------------
# 5. Nightly Maintenance & Wipe Schedule
# ------------------------------------------------------------
Write-Step "Step 5: Automated Restarts & Wipe Schedule"

$nightlyAns = Read-Default "Enable automated nightly restarts/wipes? (y/n)" "y"
$NightlyRestartEnabled = ($nightlyAns -match '^(y|yes)$')
$NightlyRestartTime = "04:00"
$WipeSchedule = "None"
$WipeDayOfWeek = "Thursday"
$WipeWeekOfMonth = "First"

if ($NightlyRestartEnabled) {
    $NightlyRestartTime = Read-Default "Scheduled maintenance time (24h format HH:mm)" "04:00"

    Write-Host ""
    Write-Host "Select a Wipe Schedule:" -ForegroundColor Cyan
    Write-Host "  None     - Restart nightly without wiping"
    Write-Host "  Weekly   - Wipe once a week on a selected day"
    Write-Host "  BiWeekly - Wipe every other week"
    Write-Host "  Monthly  - Wipe once a month (e.g. First Thursday - official Facepunch schedule)"
    $WipeSchedule = Read-Default "Schedule choice (None/Weekly/BiWeekly/Monthly)" "Monthly"

    if ($WipeSchedule -in @('Weekly', 'BiWeekly', 'Monthly')) {
        $WipeDayOfWeek = Read-Default "Day of the week for wipe (e.g., Thursday)" "Thursday"
    }
    if ($WipeSchedule -eq 'Monthly') {
        $WipeWeekOfMonth = Read-Default "Which occurrence in month? (First/Second/Third/Fourth/Last)" "First"
    }
}

# ------------------------------------------------------------
# 6. Save Configuration
# ------------------------------------------------------------
Write-Step "Step 6: Saving Configuration"

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
Write-Host "Saved configuration to: $ConfigPath" -ForegroundColor Green

# ------------------------------------------------------------
# 7. Copy Management Scripts & Batch Launchers
# ------------------------------------------------------------
Write-Step "Step 7: Deploying Management Scripts"

$filesToDeploy = @("Manage-RustServer.ps1", "Manage.bat", "RustServer.config.example.json")
foreach ($fileName in $filesToDeploy) {
    $src = Join-Path $PSScriptRoot $fileName
    $dst = Join-Path $RootPath $fileName
    if (Test-Path $src) {
        $resolvedSrc = (Resolve-Path $src).Path
        $resolvedDst = if (Test-Path $dst) { (Resolve-Path $dst).Path } else { $dst }
        if ($resolvedSrc -ne $resolvedDst) {
            Copy-Item -Path $src -Destination $dst -Force
            Write-Host "Copied $fileName to $RootPath" -ForegroundColor DarkGray
        } else {
            Write-Host "$fileName is already located in $RootPath." -ForegroundColor DarkGray
        }
    }
}

# ------------------------------------------------------------
# 8. Firewall Configuration
# ------------------------------------------------------------
if ($isAdmin) {
    Write-Step "Step 8: Windows Firewall Rules"
    $fwAns = Read-Default "Automatically allow Rust server ports through Windows Firewall? (y/n)" "y"
    if ($fwAns -match '^(y|yes)$') {
        $rules = @(
            @{ Name = "Rust Game Port ($ServerIdentity)"; Port = $ServerPort; Protocol = "UDP" },
            @{ Name = "Rust Query Port ($ServerIdentity)"; Port = $QueryPort; Protocol = "UDP" },
            @{ Name = "Rust RCON Port ($ServerIdentity)"; Port = $RCONPort; Protocol = "TCP" }
        )
        foreach ($r in $rules) {
            $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
            if (-not $existing) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Protocol -LocalPort $r.Port -Action Allow | Out-Null
                Write-Host "Created Inbound Rule: $($r.Name) ($($r.Protocol) $($r.Port))" -ForegroundColor Green
            } else {
                Write-Host "Firewall rule already exists: $($r.Name)" -ForegroundColor DarkGray
            }
        }
    }
} else {
    Write-Warning "Skipped Windows Firewall rules (not running as Administrator)."
}

# ------------------------------------------------------------
# 9. Scheduled Task
# ------------------------------------------------------------
$managePsScript = Join-Path $RootPath "Manage-RustServer.ps1"

if ($isAdmin -and $NightlyRestartEnabled) {
    Write-Step "Step 9: Registering Windows Scheduled Task"
    $taskName = "RustServer - Nightly Maintenance ($ServerIdentity)"

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$managePsScript`" -Action nightly"
    $trigger = New-ScheduledTaskTrigger -Daily -At $NightlyRestartTime
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    Write-Host "Registered scheduled task '$taskName' running daily at $NightlyRestartTime." -ForegroundColor Green
}

# ------------------------------------------------------------
# 10. Summary & Launch
# ------------------------------------------------------------
Write-Step "Installation Complete!"

Write-Host "Root Directory:       $RootPath"
Write-Host "Game Directory:       $RustGamePath"
Write-Host "Config File:          $ConfigPath"
Write-Host "Saved RCON Password:  $rconPass"
Write-Host ""
Write-Host "NOTE: To let external players connect, forward UDP ports $ServerPort, $QueryPort and TCP port $RCONPort in your home router settings." -ForegroundColor Yellow
Write-Host ""

$startAns = Read-Default "Would you like to start your Rust server right now? (y/n)" "y"
if ($startAns -match '^(y|yes)$') {
    & (Join-Path $RootPath "Manage-RustServer.ps1") -Action start
} else {
    Write-Host "You can start or manage your server anytime by double-clicking 'Manage.bat' in $RootPath." -ForegroundColor Green
}
