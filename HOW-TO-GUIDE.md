# 📖 Rust Dedicated Server - Complete Beginner's How-To Guide

A comprehensive, step-by-step guide to installing, configuring, port-forwarding, and managing your own dedicated [Rust](https://rust.facepunch.com/) server on Windows.

---

## 📑 Table of Contents
1. [Prerequisites & System Requirements](#1-prerequisites--system-requirements)
2. [Step-by-Step Installation](#2-step-by-step-installation)
3. [Router Port Forwarding (Let Friends Join)](#3-router-port-forwarding-let-friends-join)
4. [How Players Connect](#4-how-players-connect)
5. [Server Management & Maintenance](#5-server-management--maintenance)
6. [Automated Wipes & Restarts](#6-automated-wipes--restarts)
7. [Troubleshooting & FAQs](#7-troubleshooting--faqs)

---

## 1. Prerequisites & System Requirements

Before running the server, ensure your PC meets the recommended specs:
* **Operating System:** Windows 10, Windows 11, or Windows Server (64-bit).
* **RAM:** 16 GB+ recommended (Rust procedural worlds are memory-intensive).
* **Storage:** 25 GB+ free space on an SSD.
* **Prerequisite Software:** Install the [Visual C++ 2015–2022 Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).

---

## 2. Step-by-Step Installation

1. **Extract Files:** Download and extract the Rust Server Manager zip archive into a folder on your computer (e.g., `C:\RustServer` or your desktop).
2. **Launch Installer:** Right-click **`Install.bat`** and select **Run as Administrator**.
   * *Note:* The installer will automatically prompt for elevation if needed.
3. **Configure Settings:** Follow the interactive prompts:
   * **Root Path:** Choose where your server files live (Default: `C:\RustServer`).
   * **Server Name & Description:** Set your public server display name and description.
   * **Player Limit & Map Size:** Set max concurrent players and map size (standard size: `4000`–`4500`).
   * **RCON Password:** Press `[Enter]` to automatically generate a secure password, or type your own.
   * **Firewall Rules:** Allow the installer to automatically configure your Windows Firewall.
   * **Scheduled Maintenance:** Optionally enable automated nightly restarts and wipe cycles (Monthly, Weekly, Bi-Weekly).
4. **First Boot:** Once the installer finishes downloading files via SteamCMD, choose whether to launch the server immediately!

---

## 3. Router Port Forwarding (Let Friends Join)

While Windows Firewall rules are opened automatically by `Install.bat`, you must forward ports on your home router so players outside your home network can reach your server.

Log into your home router's admin panel (typically `192.168.1.1` or `192.168.0.1`) and forward the following ports to your PC's local IP address:

| Port | Protocol | Purpose |
|---|---|---|
| **28015** | **UDP** | Primary Game Port |
| **28017** | **UDP** | Steam Server Query Port (Server Browser) |
| **28016** | **TCP** | WebRCON Administration Port |

---

## 4. How Players Connect

### Connecting Locally (You on the same PC or local home network)
1. Launch Rust on Steam.
2. Press **F1** to open the in-game console.
3. Type:
   ```text
   client.connect 127.0.0.1:28015
   ```

### Connecting Remotely (Your Friends over the Internet)
1. Find your public IP address (search "what is my ip" on Google).
2. Share this command with your friends to paste into their Rust console (**F1**):
   ```text
   client.connect YOUR_PUBLIC_IP:28015
   ```
3. Your server will also appear in the in-game **Community** server browser list once the query port is reachable.

---

## 5. Server Management & Maintenance

Launch **`Manage.bat`** anytime to access the interactive control menu:

```text
==========================================================
             Rust Dedicated Server Manager
==========================================================
 [1] Start Server
 [2] Stop Server (Graceful Save & Quit)
 [3] Restart Server
 [4] Update Server (SteamCMD)
 [5] Backup Server Data
 [6] Wipe Server (Map Wipe - Keep Blueprints)
 [7] Wipe Server (Full Wipe - Reset Everything)
 [8] View Detailed Status & Port Info
 [9] Open Server Log File
 [Q] Quit
==========================================================
```

### Safety Features
* **Graceful WebRCON Shutdown:** Option `[2]` and `[3]` send `server.save` and `quit` via WebRCON before stopping the process, preventing rollbacks and world file corruption.
* **Automatic Safety Backups:** Before any wipe occurs, the manager compresses all current world files and databases into a timestamped `.zip` inside the `backups/` folder.

---

## 6. Automated Wipes & Restarts

If enabled during setup, Windows Task Scheduler runs nightly maintenance at your configured time:
* **Standard Nights:** Cleanly saves and restarts the server to free system memory and prevent lag.
* **Wipe Nights:** Creates a safety zip backup, wipes world files, selects a fresh random map seed, updates `RustServer.config.json`, and starts the new world.

---

## 7. Troubleshooting & FAQs

* **Server crashes on boot:** Check `rust_game/server/RustServer/RustServer_log.txt`. Ensure Visual C++ 2015–2022 Redistributable is installed and your PC has at least 12–16 GB of free RAM.
* **Friends can't see or join the server:** Double-check your router's port forwarding for UDP `28015` and UDP `28017`.
* **Where are my settings saved?** In `RustServer.config.json` inside your root server folder. You can edit server hostname, description, seed, or player limits anytime while the server is stopped.
