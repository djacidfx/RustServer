# How to Set Up Your Own Rust Server (Beginner's Guide)

This guide walks you through setting up a Rust Dedicated Server on Windows
using the scripts in this repository — no coding experience required. Just
follow the steps in order.

**What you'll end up with:** a working Rust server that other people can
join, that restarts itself automatically every night, and that can wipe
itself on a schedule you choose (so you don't have to remember to do it
manually).

**Time needed:** 20–40 minutes, most of which is just waiting for files to
download.

---

## Before you start

You'll need:

- **A Windows computer or Windows Server** that can stay on and connected
  to the internet while your server is running (a home PC works, but it
  needs to be on whenever you want the server to be up).
- **At least 10 GB of free disk space.**
- **A stable internet connection.**

> 💡 If you're renting a "Windows VPS" or dedicated server from a hosting
> company specifically to run a game server, everything below still
> applies — just do these steps on that machine (usually via Remote
> Desktop) instead of your home PC.

---

## Step 1: Download this repository

1. On this GitHub page, click the green **Code** button.
2. Click **Download ZIP**.
3. Find the downloaded ZIP file (usually in your **Downloads** folder),
   right-click it, and choose **Extract All...**
4. Choose a location you'll remember — for example, your Desktop — and
   extract it there.

You should now have a folder containing `Install-RustServer.ps1`,
`Manage-RustServer.ps1`, and a few other files.

---

## Step 2: Open PowerShell as an Administrator

This step matters — skipping it means your server's firewall ports and
automatic nightly restarts won't get set up.

1. Click the **Start** menu and type `PowerShell`.
2. Right-click **Windows PowerShell** in the results.
3. Choose **Run as administrator**.
4. Click **Yes** if Windows asks for permission.

You should see a blue (or black) window with a blinking cursor — this is
PowerShell.

---

## Step 3: Allow the script to run

Windows blocks scripts downloaded from the internet by default, as a
security precaution. Run this command in the PowerShell window you just
opened to allow scripts for this session only (it won't weaken security
on the rest of your computer, and resets the next time you open
PowerShell):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Press Enter. If it asks for confirmation, type `Y` and press Enter.

---

## Step 4: Go to the folder you extracted

Type `cd ` (with a space after it), then drag the extracted folder from
File Explorer into the PowerShell window — this fills in the path for
you — then press Enter. It should look something like:

```powershell
cd C:\Users\YourName\Desktop\RustServer
```

---

## Step 5: Run the installer

```powershell
.\Install-RustServer.ps1
```

Press Enter. The script will now ask you a series of questions. **For
almost every question, you can just press Enter to accept the sensible
default shown in brackets** — you don't need to understand every setting
to get a working server.

Here's what you'll be asked, and what it means in plain terms:

| It asks... | In plain terms |
|---|---|
| Install root folder | Where all the server files will live. `C:\RustServer` is fine. |
| Server hostname | The name players see in the server list. Make it something recognizable. |
| Server description | A short blurb shown in the server browser. |
| Ports (Server/Query/RCON) | Technical connection numbers — the defaults work unless you already have another server using them. |
| RCON password | A password used by admin tools to control the server remotely. Leave it blank and the script will generate a secure one for you — **write down what it prints.** |
| Max players | How many people can be on at once. |
| World size / Map seed | How big the map is and what shape it generates in. Leave the seed blank for a random map. |
| Map type | `Procedural Map` (randomly generated) is the normal choice. |
| Nightly restart | Whether the server should automatically restart itself every night — recommended, since Rust servers get slower the longer they run without a restart. |
| Wipe schedule | Whether/when the map and player progress should reset automatically. Many public servers do this monthly. If you're not sure, choose `Monthly`. |

Then the script will:

1. Download and set up SteamCMD (Valve's server-download tool) — this can
   take a few minutes.
2. Download the actual Rust server files — **this is the slow part**, it
   can take 15–30 minutes depending on your internet speed.
3. Save all your answers so you don't have to re-enter them later.
4. Ask if you want to open the necessary firewall ports — say yes.
5. Ask if you want to start the server right now — say yes.

When it's done, you'll see log messages saying the server started. That's
it — your server is running!

---

## Step 6: Let other people connect

This part happens **outside** the script, and depends on where your
server is running:

- **Hosted VPS / dedicated server:** Usually nothing extra to do — ask
  your hosting provider if any additional firewall step is needed on
  their end.
- **Home PC:** You'll likely need to **forward ports** on your home
  router so the outside internet can reach your PC. This means logging
  into your router's admin page (commonly `192.168.1.1` in a web browser)
  and forwarding the Server Port and Query Port (both UDP) to your PC's
  local IP address. Every router's interface looks different — search
  "[your router brand] port forwarding" for exact steps.

To find out what your server's public address is, search "what is my IP"
in a web browser. Players connect using that address plus your server
port, e.g. `123.45.67.89:28015`, via Rust's in-game F1 console command:
`client.connect 123.45.67.89:28015`.

---

## Day-to-day: starting, stopping, and checking on your server

Open PowerShell (doesn't need to be Administrator for these), `cd` into
your install folder, then use:

```powershell
.\Manage-RustServer.ps1 -Action start     # turn the server on
.\Manage-RustServer.ps1 -Action stop      # turn the server off
.\Manage-RustServer.ps1 -Action restart   # restart it
.\Manage-RustServer.ps1 -Action update    # get the latest Rust update
.\Manage-RustServer.ps1 -Action wipe      # wipe the map/progress (asks for confirmation)
```

If you enabled the nightly restart during setup, you don't need to run
any of these manually day-to-day — it happens on its own.

---

## Changing your settings later

Didn't like a setting you picked? Run this any time to redo the question
wizard without reinstalling anything:

```powershell
.\Manage-RustServer.ps1 -Action generate-config
```

---

## If something goes wrong

| Problem | What to try |
|---|---|
| PowerShell says scripts are disabled | Repeat Step 3 in that PowerShell window. |
| "Access denied" errors during setup | Make sure you opened PowerShell **as Administrator** (Step 2). |
| Players can't connect | Check Step 6 — most often this is a router port-forwarding issue, not the script. |
| Download of SteamCMD or Rust fails | Check your internet connection and try running `.\Install-RustServer.ps1` again — it picks up where it left off. |
| You forgot your RCON password | Run `.\Manage-RustServer.ps1 -Action generate-config` and set a new one. |

If you're stuck beyond this, open an
[Issue](../../issues) on this repository describing what step you're on
and what message you're seeing, and include a screenshot if you can.

---

## A note on staying safe

- Never share your RCON password publicly.
- The file `RustServer.config.json` (created after you run the installer)
  contains that password in plain text — don't upload or share this file.
- Keep your server updated (`-Action update`) — game server software with
  known vulnerabilities is a common target for attackers.

That's it — enjoy your server! 🦀
