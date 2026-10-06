# THE WORKING RDP

A GitHub Actions workflow that gives you a **real Windows desktop over Remote Desktop (RDP)**, for free, for up to about six hours per run.

Push a commit (or press **Run workflow**) and about two minutes later you have an address, a username and a password. Connect with `mstsc` on Windows, Microsoft Remote Desktop on macOS, `xfreerdp` on Linux, or any RDP app on a phone or tablet.

```text
==============================================================
  YOUR RDP SESSION IS READY
==============================================================
  Address  : 4.tcp.ngrok.io:19342
  Username : runneradmin
  Password : k7Qm2Xr9Tp-Vn4Hs
  Provider : pinggy
==============================================================
  Windows : mstsc /v:4.tcp.ngrok.io:19342
==============================================================
```

---

## Quick start

1. **Fork or use this repo.** Actions are already enabled, and nothing needs to be configured.
2. **Start a run.** Either push any commit, or open **Actions -> RDP (Windows) -> Run workflow**.
3. **Get the connection details.** Open the running job and look for the `YOUR RDP SESSION IS READY` block in the log. The same values are in the run summary (top of the run page) and in the notice annotation at the top of the log.
   * Shortcut: run `client/get-rdp-info.ps1` (or `client/get-rdp-info.sh`) locally and it will read them for you and can even start the RDP client.
4. **Connect.**
   * Windows: `mstsc /v:HOST:PORT`, log in as the printed username, accept the certificate warning.
   * macOS: Microsoft Remote Desktop -> Add PC -> `HOST:PORT`.
   * Linux: `xfreerdp /v:HOST:PORT /u:USER /p:'PASSWORD' /dynamic-resolution +clipboard /cert:tofu`
   * iOS / Android: Microsoft Remote Desktop app, same three values.

The session stays up for the duration of the job (**about 5.5 hours**, GitHub's hard limit for a single job is 6 hours). The workflow itself keeps the tunnel alive and reconnects it automatically, and it never restarts the tunnel while you are connected.

---

## Getting the connection details automatically

```powershell
# Windows / macOS / Linux with pwsh
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

These scripts need the [GitHub CLI](https://cli.github.com) authenticated once with `gh auth login`. `get-rdp-info.ps1` also writes a `.rdp` shortcut file that you can double click.

---

## Which tunnel is used

RDP needs a raw TCP pipe, not a web URL. Free TCP tunnels are the hard part of this repository, which is why there are several providers and automatic failover between them. With `-Provider auto` the workflow tries, in order:

| order | provider | account needed | notes |
| --- | --- | --- | --- |
| 1 | **ngrok** | yes, free token | only tried when `NGROK_AUTH_TOKEN` exists. ngrok now requires a **payment method on file** before TCP endpoints work, even on the free plan, and free accounts allow a single agent session at a time. If it fails the workflow keeps going. |
| 2 | **pinggy** | **no** | `ssh -R0:localhost:3389 tcp@free.pinggy.io`. No signup, no token, works out of the box. Free sessions last about an hour, the keep-alive step reopens them. |
| 3 | **bore** | **no** | `bore local 3389 --to bore.pub`. Open source relay, no signup. The public port is random and can be busy, so it retries. |
| 4 | **serveo** | **no** | `ssh -R 0:localhost:3389 serveo.net`. Public relay, occasionally overloaded. |
| 5 | **tailscale** | yes, free key | only tried when `TS_AUTHKEY` exists. Gives a stable private IP, but your client must also be on your tailnet. Most reliable option overall. |

So with **zero configuration** the workflow uses an account-less tunnel and just works. Pick a specific one with the `tunnel` input when you start a run.

After a tunnel is up, the workflow proves it end to end: it speaks the first bytes of the RDP protocol (an X.224 connection request) through the public address and checks for the RDP server's answer. That result is printed as `verified=true/false`.

---

## Optional secrets

Everything is optional. Add them in **Settings -> Secrets and variables -> Actions -> New repository secret**.

| secret | what it does |
| --- | --- |
| `NGROK_AUTH_TOKEN` | Your ngrok token. Get one at <https://dashboard.ngrok.com/get-started/your-authtoken>. Note the payment method requirement above. |
| `TS_AUTHKEY` | Tailscale auth key (<https://login.tailscale.com/admin/settings/keys>). Client must be on the same tailnet. |
| `RDP_PASSWORD` | Use a fixed password instead of a random one per run. |
| `RDP_USERNAME` | Enable a different local account (defaults to the account the runner runs as). |
| `ALLOWED_CIDRS` | ngrok only: restrict the tunnel to your own IPs, for example `203.0.113.7/32`. Strongly recommended on public repos. |

---

## How the repository is put together

```text
.github/workflows/main.yml     the workflow: enable RDP -> tunnel -> publish -> keep alive
scripts/Enable-RdpServer.ps1   turns any Windows machine into an RDP server
scripts/Start-RdpTunnel.ps1    the tunnel engine (ngrok/pinggy/bore/serveo/tailscale + self test)
scripts/Watch-RdpSession.ps1   keep-alive, health checks, automatic tunnel restarts
client/get-rdp-info.ps1        local helper: read host/user/password from the run log, launch mstsc
client/get-rdp-info.sh         same for Linux/macOS, can launch xfreerdp
client/connect-rdp.cmd         double click wrapper for Windows
docs/TROUBLESHOOTING.md        what to do when something does not work
```

The three `scripts/*.ps1` files are standalone: you can run them on your own Windows PC or VM to expose it over RDP the same way.

---

## Security, honestly

* A public repository has **public logs**, and the password is printed there so you can log in. Anyone who reads the log while a run is active could connect, exactly like the author of this repository intended for their own machine.
* Mitigations, in order of effectiveness: keep the repository **private**; set `ALLOWED_CIDRS` so only your IP can reach the tunnel (ngrok); use `NGROK_AUTH_TOKEN` so the endpoint belongs to your account; or set `RDP_PASSWORD` yourself and rotate it.
* Every run is a fresh, ephemeral GitHub runner. Nothing survives the run, and the machine is destroyed at the end.
* Because you get a full desktop with administrator rights, do not use this for anything sensitive while somebody else could read the log.

## Limits worth knowing

* GitHub kills a job at **6 hours**. The workflow defaults to 330 minutes and the keep-alive loop ends cleanly before the limit.
* Free minutes: this repo is public, so Actions minutes for standard runners are free. On a private repo this burns roughly 4 minutes of metered time per wall-clock hour for `windows-latest`.
* Windows runners only exist for public repos (or with a paid plan) - if the workflow refuses to start, that is why.
* Multiple sessions are supported (up to 20), so you can connect from two machines at once.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The three most common ones:

* **"The workflow says no tunnel could be established."** ngrok failed (payment method / single session limit) and the account-less relays were unreachable from that runner. Re-run, or set `TS_AUTHKEY`.
* **"mstsc says the remote computer is not found."** The address is only valid while the run is going; grab the newest one with `client/get-rdp-info.ps1`.
* **"Credentials did not work."** The password changes every run, unless you set the `RDP_PASSWORD` secret. Read the newest one.
