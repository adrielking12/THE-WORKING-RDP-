# How to run it

There are two ways. **B** works right now. **A** is the GitHub Actions way and is currently blocked for this account (see the note at the end).

---

## C. Fully automated: double click and you are in

Once Actions is enabled (section A, step 0) there is exactly one thing to do: **double click `client\connect-rdp.cmd`**.

That single click:

1. checks whether you already have a live session (a second click connects in a second)
2. starts the workflow for you if you do not
3. waits for the Windows desktop to come up, about two minutes
4. stores the credentials, so Remote Desktop logs in without asking
5. opens the desktop on the right address
6. keeps watching, and reconnects by itself when a free tunnel rotates its address

Prerequisites, both one time only:

```powershell
winget install --id GitHub.cli     # the GitHub CLI
gh auth login                      # log in through the browser
```

Then just double click. If you prefer the terminal:

```powershell
pwsh -File .\client\Connect-Rdp.ps1 -AutoReconnect
```

```bash
# Linux / macOS equivalent
./client/rdp-auto.sh --watch
```

Useful switches:

| switch | what it does |
| --- | --- |
| `-NewSession` | throw away the live machine and start a fresh one |
| `-NoLaunch` | find the session and print the details, open nothing |
| `-AutoReconnect` | (on by default in `connect-rdp.cmd`) follow tunnel address changes |
| `-AutoRestart` | also start a brand new machine when the run hits the six hour limit |
| `-Tunnel tailscale` | pick the tunnel provider |
| `-DurationMinutes 330` | session length |

**Auto restart is off by default on purpose.** A machine that silently re-creates itself every six hours, forever, is exactly the pattern that gets accounts flagged. Turn it on with `-AutoRestart` if you accept that, and stop it by closing the window.

---

## B. On a Windows PC you own (works today)

Needs Windows **Pro, Enterprise or Education** - Home cannot be an RDP server at all.

**0. The one command version.** Open PowerShell (normal, not admin - it elevates itself), then:

```powershell
git clone https://github.com/adrielking12/THE-WORKING-RDP-.git
cd THE-WORKING-RDP-
pwsh -File .\scripts\Start-Rdp.ps1
```

That enables RDP (one UAC prompt), opens the tunnel, copies the address, username and password to your clipboard, and starts the keep-alive watcher. Everything below is the same thing done step by step.

**1. Get the files**

```powershell
git clone https://github.com/adrielking12/THE-WORKING-RDP-.git
cd THE-WORKING-RDP-
```

**2. Open PowerShell as Administrator** (right click the Start button -> *Terminal (Admin)*)

**3. Turn this machine into an RDP server**

```powershell
pwsh -File .\scripts\Enable-RdpServer.ps1 -Username $env:USERNAME -Password 'PickAStrongPassword!'
```

(Use `powershell -File ...` instead of `pwsh -File ...` if you do not have PowerShell 7. If you leave off `-Password`, a random one is generated and printed.)

**4. Publish port 3389 to the internet**

```powershell
pwsh -File .\scripts\Start-RdpTunnel.ps1 -Provider pinggy
```

Leave that window open. It prints a banner like:

```
==============================================================
  YOUR RDP SESSION IS READY
==============================================================
  Address  : free.pinggy.io:48720
  Username : yourname
  Password : PickAStrongPassword!
  Provider : pinggy
==============================================================
```

**5. Connect from anywhere** - your phone, another PC, a laptop:

```
Windows : mstsc /v:free.pinggy.io:48720
Linux   : xfreerdp /v:free.pinggy.io:48720 /u:yourname /p:'PickAStrongPassword!' /cert:tofu
macOS   : Microsoft Remote Desktop -> Add PC -> free.pinggy.io:48720
```

Log in with the username and password from step 3 or 4. Accept the certificate warning.

**6. Optional: keep it alive**

Free pinggy sessions drop after about an hour. To reconnect automatically:

```powershell
pwsh -File .\scripts\Watch-RdpSession.ps1 -Minutes 480
```

### Other providers for step 4

```powershell
# let it pick (ngrok if NGROK_AUTH_TOKEN is set, otherwise pinggy -> bore -> serveo)
pwsh -File .\scripts\Start-RdpTunnel.ps1 -Provider auto

# the most stable option: your own private Tailscale IP
$env:TS_AUTHKEY = 'tskey-auth-...'
pwsh -File .\scripts\Start-RdpTunnel.ps1 -Provider tailscale
```

Everything it prints is also written to `%TEMP%\rdp-tunnel\rdp-info.txt`.

---

## A. With GitHub Actions

**Step 0 - Actions has to be switched back on first.** Right now it is disabled for this account: open <https://github.com/adrielking12/THE-WORKING-RDP-/settings/actions> and check for an enable option, otherwise open a ticket at <https://support.github.com/contact?tags=dotcom-actions>. Nothing below can run until that is done.

**1. Permissions** (needed so your files can be saved to the `rdp-data` branch)
Settings -> Actions -> General -> Workflow permissions -> **Read and write permissions** -> Save.

**2. Optional secrets** - Settings -> Secrets and variables -> Actions -> New repository secret

| secret | why |
| --- | --- |
| `RDP_BACKUP_PASSWORD` | your files get encrypted and restored automatically between sessions. **Set this one.** |
| `TS_AUTHKEY` | most reliable tunnel (Tailscale) |
| `NGROK_AUTH_TOKEN` | use ngrok as the tunnel |
| `RDP_PASSWORD` | fixed RDP password instead of a random one each run |

**3. Start it** - **Actions** -> **RDP (Windows)** -> **Run workflow**

* `tunnel`: leave `auto`
* `duration_minutes`: `330` (6 hours is GitHub's hard limit)
* `save_data`: `on`
* `save_interval_minutes`: `10`
* press **Run workflow**

**4. Get the address** - open the running job:

* the **summary** at the top of the run page has address, username and password
* the same block is in the log: search for `YOUR RDP SESSION IS READY`
* or run the helper locally and it fetches everything for you:

```powershell
pwsh -File .\client\get-rdp-info.ps1 -Wait -Launch     # -Launch starts mstsc
```

```bash
./client/get-rdp-info.sh --wait --connect              # Linux/macOS, starts xfreerdp
```

**5. Connect** with the address, username and password. Do your work. Close the window whenever you like.

**6. Come back** - start another run, and your Desktop, Documents, Downloads, Pictures and the rest are restored before you log in. Your files also live at <https://github.com/adrielking12/THE-WORKING-RDP-/tree/rdp-data>.

---

## Which one should I use?

| | own PC / VM | GitHub Actions |
| --- | --- | --- |
| works today | **yes** | no, Actions is disabled |
| how you start it | `scripts\Start-Rdp.ps1` (one command) | `client\Connect-Rdp.ps1` (one click) |
| needs | Windows Pro+ | the repo, Actions enabled |
| hardware | your own | free GitHub runner |
| session length | as long as you keep the tunnel process running | max ~5.5 hours per run |
| your files | already on your disk | restored from the `rdp-data` branch |
| recommended for | getting work done now | when Actions comes back |

---

## Quick answers

**"Nothing listens on port 3389."** Run the enable script as Administrator, and check the edition - Home cannot do it.

**"mstsc says the remote computer is not found."** The public address changes every time you start a tunnel. Use the newest printed address (or `rdp-info.txt`).

**"Credentials did not work."** Username and password are printed in the banner; the password is regenerated each session unless you pass `-Password` or set the `RDP_PASSWORD` secret.

**"It disconnected after about an hour."** That is pinggy's free session limit. Use `Watch-RdpSession.ps1 -Minutes 480`, or switch to Tailscale.

**"connect-rdp.cmd just flashes and closes."** Run it from a terminal (`pwsh -File .\client\Connect-Rdp.ps1`) to read the message - it is almost always `gh` missing or not logged in.

**"It says the workflow could not be started."** Actions is disabled for the account, or the token has no access. Open `https://github.com/adrielking12/THE-WORKING-RDP-/settings/actions`.

**"Connect-Rdp.ps1 says the ref has an older workflow."** The branch you are dispatching (`Ref`) does not have the workflow inputs yet. Merge the pull request into `main`, or pass `-Ref` with the branch that does.

**"It connects but the desktop is the old one / my files are missing."** You got a different machine. Files live in the `rdp-data` branch, and `-AutoRestart` machines start from that snapshot, so anything done after the last 10 minute snapshot can be missing.

**"Is this safe?"** You are exposing a desktop. Use a strong password, prefer Tailscale (private) or `ALLOWED_CIDRS` (ngrok, restrict to your IP), and remember a public repo's logs are public.
