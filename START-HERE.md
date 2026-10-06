# START HERE — the whole thing, from zero

This is the complete walkthrough. Follow it top to bottom and you will end up with a Windows desktop you can reach from your phone or laptop, with your files saved between sessions.

No prior knowledge assumed. Every command is copy-pasteable.

---

## What you will have when you finish

```
Your laptop / phone  ---- internet ---->  a Windows desktop
                                          your files are there
                                          saves itself every 10 minutes
```

You reach it with the normal Remote Desktop app. You do not need a server, a VPN, or a port forward.

---

## Step 0 — the one thing that is broken right now

GitHub has **disabled Actions for this account**. Until that is fixed, the GitHub way (Path B) cannot run, and nothing in the repository can change that.

Two things to do, in this order:

1. Open <https://github.com/adrielking12/THE-WORKING-RDP-/settings/actions> and look for an enable option. If there is one, use it and skip to Step 2.
2. If there is no option, open a ticket at <https://support.github.com/contact?tags=dotcom-actions> and paste something like this:

```text
Subject: Request to re-enable GitHub Actions for my account

My account (adrielking12) and my repositories THE-WORKING-RDP- and myrdpart
have GitHub Actions disabled: the Actions tab shows "GitHub Actions is currently
disabled for this repository. Please reach out to GitHub Support for assistance."

I understand the previous workflows ran long-lived jobs to provide remote desktop
access, which is not an appropriate use of hosted runners. I have stopped that:
the workflow in THE-WORKING-RDP- is now started manually, is documented as a
personal development environment rather than free compute, and has a hard time
limit. I will not use hosted runners for anything other than building, testing
and personal development work.

Please re-enable GitHub Actions for my account so my normal repositories work
again. I am happy to answer any questions.
```

**Do not wait for that to be resolved.** Path A works today and needs nothing from GitHub.

---

## Step 1 — get the files on your computer

Pick whichever line works for you. Both end up with the same folder.

**If you have git:**

```powershell
git clone https://github.com/adrielking12/THE-WORKING-RDP-.git
cd THE-WORKING-RDP-
```

**If you do not have git** (plain PowerShell, no extra software):

```powershell
irm https://github.com/adrielking12/THE-WORKING-RDP-/archive/refs/heads/main.zip -OutFile "$env:TEMP\rdp.zip"
Expand-Archive "$env:TEMP\rdp.zip" "$env:TEMP\rdp" -Force
cd "$env:TEMP\rdp\THE-WORKING-RDP--main"
```

Keep this folder. Everything lives in it.

---

## Step 2 — choose your path

|  | **Path A** — your own Windows PC | **Path B** — GitHub Actions |
| --- | --- | --- |
| works today | **yes** | no, needs Step 0 fixed |
| you need | a Windows **Pro / Enterprise / Education** machine | a GitHub account, Actions enabled |
| the machine | yours, always on if you want | GitHub's, for max ~5.5 hours per run |
| your files | already on your disk | restored from the `rdp-data` branch |
| cost | free | free (public repo) |
| tunnels | pinggy / bore / serveo / ngrok / tailscale | same, automatic failover |

Not sure which edition you have? Run this in PowerShell:

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
```

`Professional`, `Enterprise`, `Education` or `Pro` → Path A works.
`Core`, `Home` or `Starter` → **Home cannot be an RDP server at all**, it is a Pro feature. Use Path B, or any free cloud VM with Windows Server.

---

## Path A — your own Windows PC (works right now)

### A1. Run one command

Open PowerShell **normally** (not as administrator - it asks for that itself):

```powershell
pwsh -File .\scripts\Start-Rdp.ps1
```

No PowerShell 7? Use `powershell -File .\scripts\Start-Rdp.ps1` instead.

### A2. What happens

1. Windows asks for permission once (UAC). Click **Yes**.
2. RDP is switched on, a password is set for your account, and the firewall is opened.
3. A tunnel opens and the window prints a banner, and the address, username and password go to your **clipboard**.
4. A keep-alive watcher starts in the background so the tunnel is re-opened automatically if it drops.

```
==============================================================
  YOUR RDP SESSION IS READY
==============================================================
  Address  : free.pinggy.io:48720
  Username : yourname
  Password : k7Qm2Xr9Tp-Vn4Hs
  Provider : pinggy
==============================================================
```

### A3. Connect from anywhere

```text
Windows : mstsc /v:free.pinggy.io:48720
macOS   : Microsoft Remote Desktop app -> Add PC -> free.pinggy.io:48720
Linux   : xfreerdp /v:free.pinggy.io:48720 /u:yourname /p:'password' /cert:tofu
Phone   : Microsoft Remote Desktop app, same three values
```

Accept the certificate warning, log in with the printed username and password.

### A4. Things you can change

```powershell
# a password you choose, instead of a random one
pwsh -File .\scripts\Start-Rdp.ps1 -Password 'MyStrongPassword!'

# most stable option: reach it on your own private Tailscale IP
$env:TS_AUTHKEY = 'tskey-auth-...'
pwsh -File .\scripts\Start-Rdp.ps1 -Provider tailscale

# test the listener locally, in a window on the machine itself
pwsh -File .\scripts\Start-Rdp.ps1 -TestLocal

# do not start the keep-alive watcher
pwsh -File .\scripts\Start-Rdp.ps1 -WatchMinutes 0
```

### A5. Stopping it

Close the tunnel window, or `Stop-Process -Name bore,ssh -ErrorAction SilentlyContinue`. To switch RDP off again:

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 1
```

---

## Path B — GitHub Actions (do Step 0 first)

### B1. Let the workflow save your files

**Settings → Actions → General → Workflow permissions → Read and write permissions → Save.**

Without this the machine still works, but "your files come back next session" does not.

### B2. Add one secret (strongly recommended)

**Settings → Secrets and variables → Actions → New repository secret**

| name | value | why |
| --- | --- | --- |
| `RDP_BACKUP_PASSWORD` | any password you make up | encrypts your file snapshot and lets the next session restore it with no typing |

Optional extras: `TS_AUTHKEY` (Tailscale, the most reliable tunnel), `NGROK_AUTH_TOKEN` (ngrok), `RDP_PASSWORD` (fixed login password).

### B3. Start it: double click `client\connect-rdp.cmd`

That is the whole step. It will:

1. install the GitHub CLI if you do not have it (accept the prompt)
2. ask you to log in to GitHub the first time (a browser window opens)
3. start the Windows machine on GitHub's runners
4. wait about two minutes for it to come up
5. save the password so Remote Desktop does not ask for it
6. open Remote Desktop on the right address, already logged in
7. keep watching, and reconnect by itself when the free tunnel rotates its address

### B4. Prefer the terminal?

```powershell
pwsh -File .\client\Connect-Rdp.ps1                 # normal
pwsh -File .\client\Connect-Rdp.ps1 -NoLaunch        # just print the address
pwsh -File .\client\Connect-Rdp.ps1 -NewSession      # fresh machine
pwsh -File .\client\Connect-Rdp.ps1 -AutoRestart     # new machine at the 6h limit
```

```bash
./client/rdp-auto.sh --watch                         # Linux / macOS
```

---

## Step 3 — the daily loop

```text
double click connect-rdp.cmd   ->   work   ->   close the window
```

That is it. Next time:

* **Path A** - the machine is yours, so your files are simply there. Reconnect with the last address, or re-run `Start-Rdp.ps1` if it changed.
* **Path B** - double click again, and the last snapshot of your files is restored before you log in.

---

## Step 4 — what is saved, and what is not

**Saved (Path B, every 10 minutes, and once more when the session ends):**

Desktop · Documents · Downloads · Pictures · Videos · Music · Favorites · Links · Contacts · Saved Games · VS Code settings and snippets · Edge and Chrome bookmarks · PowerShell history · Start Menu shortcuts · `.gitconfig`

Add your own folders with the `save_paths` run input, separated by semicolons.

**Saved (Path A):** everything, because it is your own disk.

**Not saved:** installed programs. On Path B the machine is rebuilt every session, so reinstall your tooling automatically by putting the commands in `Documents\rdp-startup.ps1` - it is restored with your files and runs at the start of every session.

Your snapshot is also always downloadable at
<https://github.com/adrielking12/THE-WORKING-RDP-/tree/rdp-data>

---

## Step 5 — when something goes wrong

| what you see | what it means | fix |
| --- | --- | --- |
| "GitHub Actions is currently disabled" | Step 0 not done | do Step 0, or use Path A |
| `Start-Rdp.ps1` says this is a Home edition | Home cannot host RDP | Path B, or a cloud VM |
| "no tunnel could be established" | ngrok failed (it needs a payment method even on the free plan) and the account-less relays were unreachable | re-run, or set `TS_AUTHKEY` and use `-Provider tailscale` |
| mstsc says the remote computer is not found | the free address changes every session | use the newest address; `connect-rdp.cmd` always fetches it |
| the password does not work | a new password is generated each session unless you pin one | Path B: set `RDP_PASSWORD`. Path A: pass `-Password` |
| disconnected after about an hour | pinggy's free session limit | `Watch-RdpSession.ps1` reconnects it; for uninterrupted work use Tailscale or ngrok |
| connected, but my files are missing | you got a different machine and the snapshot did not restore | check `RDP_BACKUP_PASSWORD` is set and B1 is done |
| `connect-rdp.cmd` flashes and closes | a message scrolled past | run `pwsh -File .\client\Connect-Rdp.ps1` to read it |
| the run dies at ~6 hours | GitHub's hard job limit | start a new run; use `-AutoRestart` if you accept machines re-creating themselves |

Full list with more detail: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

---

## Step 6 — limits, cost and safety

* **Time:** one GitHub job can run at most 6 hours. The workflow asks for 5.5 and stops cleanly.
* **Cost:** free for public repositories. On a private repo, a Windows runner bills at roughly 4 minutes of metered time per wall-clock hour.
* **Accounts:** using GitHub's free runners as a personal remote desktop is against their Acceptable Use Policies, and that is why this account is currently blocked. Keep it to your own development work, keep it manual, and avoid anything that looks like recycling free compute - that is also why auto-restart is opt-in.
* **Security:** you are exposing a desktop. Use a strong password, prefer `-Provider tailscale` (private) or set `ALLOWED_CIDRS` for ngrok, and remember a public repo's logs are public - the password is printed there so you can log in.

---

## Appendix — every command in one place

```powershell
# ---- Path A: your own PC ----
pwsh -File .\scripts\Start-Rdp.ps1                          # enable + tunnel + clipboard + keep-alive
pwsh -File .\scripts\Start-Rdp.ps1 -Password 'Xyz123!@#'    # fixed password
pwsh -File .\scripts\Start-Rdp.ps1 -Provider tailscale      # needs $env:TS_AUTHKEY
pwsh -File .\scripts\Enable-RdpServer.ps1                   # only enable the server
pwsh -File .\scripts\Start-RdpTunnel.ps1 -Provider pinggy   # only the tunnel
pwsh -File .\scripts\Watch-RdpSession.ps1 -Minutes 480      # only the keep-alive

# ---- Path B: GitHub Actions ----
.\client\connect-rdp.cmd                                    # one click, everything
pwsh -File .\client\Connect-Rdp.ps1 -AutoReconnect          # same, from a terminal
pwsh -File .\client\get-rdp-info.ps1                        # just print the details
gh workflow run main.yml -f tunnel=auto -f duration_minutes=330   # start it manually
gh run list --limit 3                                       # what is running
gh run view <id> --log                                      # read a run
```

```bash
# ---- Linux / macOS client ----
./client/rdp-auto.sh --watch          # connect, stay connected
./client/rdp-auto.sh --restart        # also start a new machine at the 6h limit
./client/get-rdp-info.sh              # just print the details
```

DNS of the free tunnels: `free.pinggy.io`, `bore.pub`, `serveo.net`. If you pin a provider, use the same name every time.
