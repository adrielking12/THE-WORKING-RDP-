# THE WORKING RDP

A GitHub Actions workflow that gives you a **real Windows desktop over Remote Desktop (RDP)**, free, for up to about six hours per run. Plus the same thing as standalone scripts you can run on any Windows machine you own.

Start a run, and about two minutes later you have an address, a username and a password:

```text
==============================================================
  YOUR RDP SESSION IS READY
==============================================================
  Address  : free.pinggy.io:48720
  Username : runneradmin
  Password : k7Qm2Xr9Tp-Vn4Hs
  Provider : pinggy
==============================================================
  Windows : mstsc /v:free.pinggy.io:48720
  Linux   : xfreerdp /v:free.pinggy.io:48720 /u:runneradmin
  macOS   : Microsoft Remote Desktop, PC name free.pinggy.io:48720
==============================================================
```

**In a hurry? [RUN.md](RUN.md) has the exact commands for both ways to run this.**

**Want no typing at all?** Once Actions is enabled, double click `client\connect-rdp.cmd`: it starts the workflow if nothing is running, waits for the desktop, saves the credentials so Remote Desktop does not prompt, opens it on the right address, and reconnects by itself when a free tunnel rotates its address. Linux/macOS: `./client/rdp-auto.sh --watch`.

---

## Your work is saved between sessions

A GitHub runner is destroyed when the job ends, so nothing on its disk can survive on its own. This repository fixes that by snapshotting your user profile to a **`rdp-data` branch** while you work, and restoring it automatically at the start of the next session.

* **Saved automatically** every 10 minutes (configurable), plus one final snapshot when the session ends - so a dropped connection, a closed window, or the 6 hour limit does not lose your work.
* **Restored automatically** before you log in, so the next session starts where the last one stopped.
* **Default save set:** Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites, Links, Contacts, Saved Games, VS Code settings and snippets, Edge/Chrome bookmarks, PowerShell history, Start Menu shortcuts, `.gitconfig`. Add your own folders with the `save_paths` input.
* **Encrypted** with AES-256 + HMAC on public repositories, using a password you control.
* **Browse or download your files any time** at `https://github.com/<owner>/<repo>/tree/rdp-data`.
* On the desktop there is an **`RDP Data`** folder with a **`Save now.cmd`** you can double click to snapshot immediately.

What is *not* saved: installed programs, because the machine is rebuilt every run. To reinstall your tooling automatically put the commands in `Documents\rdp-startup.ps1` - it is restored with your files and run at the start of every session.

| what | where |
| --- | --- |
| your files | `rdp-data` branch, `profile.zip` (or `profile.enc` when encrypted) |
| snapshot metadata | `last-save.json` in the same branch |
| restore manifest | `_layout.json` in the same branch |
| autosave log | `rdp-sync-watch.log` in the runner, tail of it is printed in the job log |

The password that encrypts the snapshot is generated per session and printed in the run summary **and** as a warning annotation. Set it as the `RDP_BACKUP_PASSWORD` secret and the next session restores your files with no typing at all.

---

## READ THIS FIRST: Actions is disabled for this account

As of when this was written, GitHub has **turned Actions off** for this repository and for the account's other RDP repository:

> GitHub Actions is currently disabled for this repository. Please reach out to GitHub Support for assistance.

That is not something a workflow file can fix. Until it is resolved, **no workflow in this repository can run at all**, and the runner never starts. Two ways forward:

1. **Get it turned back on.** Open <https://github.com/adrielking12/THE-WORKING-RDP-/settings/actions> and check for an enable option. If it only tells you to contact Support, open a ticket at <https://support.github.com/contact?tags=dotcom-actions>. Be aware that using hosted runners as a free remote desktop, instead of for building and testing software, is against GitHub's Acceptable Use Policies - so an appeal can be refused, and re-using the same pattern can get an account flagged again.
2. **Do not use Actions at all.** The exact same scripts run on any Windows machine you control (your PC, a laptop, a free-tier VM). See [Run it without GitHub Actions](#run-it-without-github-actions). This works today, with no GitHub involvement, and is still useful if Actions never comes back.

Everything below describes the workflow, which is ready to go the moment Actions is available again.

---

## Quick start

1. **Start a run:** **Actions -> RDP (Windows) -> Run workflow**. Pick a tunnel provider (or leave `auto`) and a duration, then press the green button.
   * There is deliberately **no `push` trigger**: starting a six hour desktop on every commit is what gets accounts flagged. If you want that behaviour, add the commented out `push:` block at the top of `.github/workflows/main.yml`.
2. **Get the connection details:** open the running job and read the `YOUR RDP SESSION IS READY` block in the log. The same values are in the **run summary** (top of the run page) and in the **notice annotation** at the top of the log.
   * Shortcut: run `client/get-rdp-info.ps1` (or `client/get-rdp-info.sh`) locally and it finds them for you, and can start the RDP client for you.
3. **Connect.**
   * Windows: `mstsc /v:HOST:PORT`, log in as the printed username, accept the certificate warning.
   * macOS: Microsoft Remote Desktop -> Add PC -> `HOST:PORT`.
   * Linux: `xfreerdp /v:HOST:PORT /u:USER /p:'PASSWORD' /dynamic-resolution +clipboard /cert:tofu`
   * iOS / Android: Microsoft Remote Desktop app, same three values.

The session lives for the duration of the job (default **330 minutes**, GitHub's hard limit is 6 hours). The workflow's keep-alive step health-checks the tunnel every 2.5 minutes, automatically replaces it if a relay drops it (without kicking you out if you are connected), and restarts the autosave process if it ever dies.

Your files come back with you: they are snapshotted every 10 minutes and restored at the start of the next session. See [Your work is saved between sessions](#your-work-is-saved-between-sessions).

---

## Getting the connection details automatically

```powershell
# Windows, and macOS/Linux with pwsh
pwsh -File ./client/get-rdp-info.ps1 -Wait -Launch
```

```bash
# Linux / macOS
./client/get-rdp-info.sh --wait --connect
```

```text
# Windows: just double click
client\connect-rdp.cmd
```

These need the [GitHub CLI](https://cli.github.com) authenticated once with `gh auth login`. `get-rdp-info.ps1` also writes a `.rdp` shortcut file you can double click.

---

## Which tunnel is used

RDP needs a raw TCP pipe, not a web URL. Free TCP tunnels are the hard part of this repository, so there are several providers with automatic failover. With `auto` the workflow tries, in order:

| order | provider | account needed | notes |
| --- | --- | --- | --- |
| 1 | **ngrok** | free token | only tried when `NGROK_AUTH_TOKEN` exists. ngrok now requires a **payment method on file** before TCP endpoints work, even on the free plan, and free accounts allow one agent session at a time. If it fails, the workflow keeps going. |
| 2 | **pinggy** | **no** | `ssh -R0:localhost:3389 tcp@free.pinggy.io`. No signup, no token. Free sessions last about an hour, the keep-alive step reopens them. |
| 3 | **bore** | **no** | `bore local 3389 --to bore.pub`, open source relay, no signup. Random public port, retries when busy. |
| 4 | **serveo** | **no** | `ssh -R 0:localhost:3389 serveo.net`. Last resort, occasionally overloaded. |
| 5 | **tailscale** | free key | only tried when `TS_AUTHKEY` exists. Stable private IP, but your client must be on your tailnet too. The most reliable option overall. |

So **with zero configuration** the workflow uses an account-less tunnel and just works. Pick a specific one with the `tunnel` input.

After a tunnel is up, the workflow proves it end to end: it speaks the first bytes of the RDP protocol (an X.224 connection request) through the public address and checks that the RDP server answers. That result is printed as `verified=true/false`.

---

## Run it without GitHub Actions

(Step by step version: [RUN.md](RUN.md#b-on-a-windows-pc-you-own-works-today). Needs Windows Pro, Enterprise or Education - Home editions cannot be RDP servers.)

The scripts are standalone. On any Windows machine where you are an administrator:

```powershell
# 1. turn this machine into an RDP server (sets a password, opens the firewall)
pwsh -File ./scripts/Enable-RdpServer.ps1 -Username $env:USERNAME -Password 'YourStrongPassword!'

# 2. publish port 3389 through an account-less tunnel (keep it running)
pwsh -File ./scripts/Start-RdpTunnel.ps1 -Provider pinggy

# 3. read the address it prints, then connect from anywhere:
#    mstsc /v:free.pinggy.io:48720
```

Outside a runner there is no backup branch to push to, so `Sync-RdpData.ps1` keeps the snapshot on local disk instead (`-Mode Save` then prints the path). Everything else behaves the same.

Use `-Provider auto` to let it pick, or `-Provider tailscale` with a `TS_AUTHKEY` in the environment for the most stable option. This is the same code path the workflow runs, minus the GitHub-specific environment variables - which means it also works on a VM, a home server, or a Windows Sandbox, and it is not going to make GitHub angry.

---

## Optional secrets

All of them are optional. Add these under **Settings -> Secrets and variables -> Actions -> New repository secret**.

| secret | what it does |
| --- | --- |
| `NGROK_AUTH_TOKEN` | Your ngrok token, <https://dashboard.ngrok.com/get-started/your-authtoken>. Mind the payment method requirement above. |
| `TS_AUTHKEY` | Tailscale auth key, <https://login.tailscale.com/admin/settings/keys>. Client must be on the same tailnet. |
| `RDP_PASSWORD` | Fixed password instead of a random one per run. |
| `RDP_USERNAME` | Enable a different local account (defaults to the account the runner runs as). |
| `ALLOWED_CIDRS` | ngrok only: restrict the tunnel to your own addresses, for example `203.0.113.7/32`. Recommended if the repository is public. |
| `RDP_BACKUP_PASSWORD` | Password that encrypts your data snapshot. Set it once and your files are restored automatically every session. Without it a fresh password is generated per session and printed in the run summary. |

The data snapshot uses the workflow's own `GITHUB_TOKEN` (`GH_PUSH_TOKEN` in the workflow), not a personal access token, so there is no long-lived credential to leak. It needs **Settings -> Actions -> General -> Workflow permissions -> Read and write permissions**, which the workflow requests with `permissions: contents: write`.

---

## How the repository is put together

```text
.github/workflows/main.yml     workflow: enable RDP -> tunnel -> publish -> keep alive
scripts/Enable-RdpServer.ps1   turns any Windows machine into an RDP server
scripts/Start-RdpTunnel.ps1    tunnel engine (ngrok/pinggy/bore/serveo/tailscale) + RDP self test
scripts/Watch-RdpSession.ps1   keep-alive, health checks, automatic tunnel + autosave restarts
scripts/Sync-RdpData.ps1        saves your profile to the rdp-data branch and restores it next session
client/Connect-Rdp.ps1         auto connector: starts a run if needed, waits, stores credentials, launches
client/connect-rdp.cmd         double click wrapper for Connect-Rdp.ps1
client/rdp-auto.sh             the same auto connector for Linux/macOS
scripts/Start-Rdp.ps1          one command for your own Windows PC (enable + tunnel + keep alive)
client/get-rdp-info.ps1        lighter helper: just print the host/user/password, or launch mstsc
client/get-rdp-info.sh         same for Linux/macOS, can launch xfreerdp
client/connect-rdp.cmd         double click wrapper for Windows
docs/TROUBLESHOOTING.md        what to do when something does not work
```

---

## Security, honestly

* A public repository has **public logs**, and the password is printed there so you can log in. Anyone reading the log while a run is active could connect.
* Mitigations, best first: keep the repository **private**; set `ALLOWED_CIDRS` so only your IP can reach the tunnel (ngrok); use an `NGROK_AUTH_TOKEN` so the endpoint belongs to your account; or set `RDP_PASSWORD` yourself.
* Every run is a fresh, ephemeral runner: nothing survives, and the machine is destroyed at the end.
* You get a desktop **with administrator rights**. Treat it like a borrowed public computer.

## Limits worth knowing

* GitHub kills a job at **6 hours**. The workflow defaults to 330 minutes and stops the keep-alive loop cleanly before that.
* Windows runners are only available for public repositories on free plans, and on paid plans for private ones. If the job refuses to start, that is usually why.
* On a private repository this burns roughly 4 minutes of metered time per wall-clock hour of `windows-latest` (GitHub bills Windows runners at 2x the Linux rate).
* Up to 20 sessions can exist at once, so two people can connect to the same runner.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The three most common ones:

* **"GitHub Actions is currently disabled for this repository."** See the section at the top.
* **"The workflow says no tunnel could be established."** ngrok failed (payment method / single session limit) and the account-less relays were unreachable from that runner. Re-run, or set `TS_AUTHKEY`.
* **"Credentials did not work."** The password changes every run unless you set the `RDP_PASSWORD` secret - read the newest one.
