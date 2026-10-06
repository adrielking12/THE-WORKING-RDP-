# Troubleshooting

Everything below is ordered by how often it happens.

---

## 1. "No tunnel could be established"

The workflow tried every provider and none of them gave out a public endpoint. Read the lines above that message in the log, each provider prints why it was skipped or failed.

| symptom in the log | cause | fix |
| --- | --- | --- |
| `ngrok: ERR_NGROK_108` | a previous ngrok agent session from the same account is still connected (free accounts allow one) | wait for the old run to end, cancel it, or use another provider |
| `ngrok: ... payment` / `ERR_NGROK_3004` | ngrok now requires a payment method on file before TCP endpoints work, even on the free plan | add a card to ngrok, or just use the account-less providers (pinggy/bore/serveo), which are the default |
| `pinggy: ssh exited early` | the relay closed the connection, or your runner cannot reach `free.pinggy.io:443` | re-run; if it keeps happening use `tunnel: tailscale` |
| `bore: attempt N failed` | the random public port was taken or `bore.pub` is down | re-run, or pin another provider |
| `serveo: ssh exited early` | serveo is heavily loaded | not much to do, it is the last fallback for a reason |
| `tailscale: install failed` | the MSI download was blocked | use a different provider |

If all of them fail, set the `TS_AUTHKEY` secret and start the run with `tunnel: tailscale`. Tailscale is the most reliable option because you connect to a private IP instead of a public relay.

---

## 2. The client cannot connect

**"The remote computer could not be found" / connection times out.**
The public address only exists while the run is going. Every provider hands out a fresh port per run, so an address from an earlier run is dead. Use `client/get-rdp-info.ps1` to fetch the current one.

**"The credentials that were used to connect are incorrect".**
The password is regenerated on every run unless you set the `RDP_PASSWORD` secret. Copy the newest one from the run summary or the `[rdp-info]` block in the log.

**"An authentication error has occurred / CredSSP".**
Run `mstsc /v:HOST:PORT /cert-ignore` (or delete the stored credential in Windows Credential Manager) and reconnect. On Linux use `/cert:tofu`, on FreeRDP `/cert:ignore`.

**Certificate warning about the remote computer's identity.**
Expected - the runner uses a self-signed certificate. Accept it.

**Session connects and then dies after about an hour.**
That is pinggy's free session limit. The workflow reopens the tunnel automatically, but your client will drop with it. For long uninterrupted work, use ngrok or tailscale, or reconnect after the restart (the new address is in the run summary).

---

## 3. The workflow does not even start

* **"GitHub Actions is currently disabled for this repository. Please reach out to GitHub Support for assistance."** - GitHub turned Actions off for the repository (this is an account level enforcement, not a setting in the workflow file). Check <https://github.com/adrielking12/THE-WORKING-RDP-/settings/actions> for an enable option, and otherwise open a ticket at <https://support.github.com/contact?tags=dotcom-actions>. None of the files in this repository can work around it. The scripts still run fine on your own Windows machine, see "Run it without GitHub Actions" in the README.
* **"The job was not started because recent account payments have failed" / no runner available** - Windows runners are only available for public repositories with standard runners, or on paid plans. Make the repository public or use a paid plan.
* **"Workflows aren't being run on this forked repository"** - in a *fork*, Actions are disabled by default. Open the fork's **Actions** tab and press the green **I understand my workflows, go ahead and enable them** button.
* **The run is cancelled immediately** - a newer run on the same branch cancels the older one (`concurrency`). That is intended, one RDP machine per branch is enough.
* **The job disappeared after about 6 hours** - GitHub's hard limit for a single job. Start a new run.

---

## 4. I am connected but something inside the session misbehaves

* **The desktop looks tiny or blurry.** Set the resolution in your client (`mstsc` display tab, or `xfreerdp /dynamic-resolution`). The workflow already sets `use multimon:i:1` and `dynamic resolution:i:1` in the generated `.rdp` file.
* **My session was logged off while I was away.** The workflow removes the idle and disconnect timeouts (`MaxIdleTime`, `MaxDisconnectionTime`), but the job still ends at the 6 hour limit.
* **Clipboard or file copy does not work.** Enable clipboard/drive redirection in your client. `xfreerdp ... +clipboard /drive:shared,/tmp` works well.
* **I need to install software.** You are an administrator on the runner, so `winget`, `choco` and `msiexec` all work - but the machine is destroyed when the run ends.

---

## 5. Reading the log without the helper scripts

Search the run log for:

```text
[rdp-info] BEGIN
[rdp-info] provider=pinggy
[rdp-info] address=free.pinggy.io:45678
[rdp-info] username=runneradmin
[rdp-info] password=XXXXXXXXXXXX
[rdp-info] verified=True
[rdp-info] END
```

The same values appear in the run summary (top of the run page) and in the notice annotation, so you do not have to scroll.

---

## 7. Saving and restoring your data

| symptom | cause | fix |
| --- | --- | --- |
| "No previous snapshot found, this looks like the first session." | nothing was saved yet, or the `rdp-data` branch was deleted | that is normal for the first run; do some work and it will be there next time |
| "The stored snapshot is encrypted and there is no backup password for this run" | you did not set `RDP_BACKUP_PASSWORD`, so the previous session used a generated password | copy the password that was printed in the previous run's summary/warning annotation into the `RDP_BACKUP_PASSWORD` secret |
| "Could not decrypt the snapshot: the backup password is wrong (or the file is damaged)" | wrong secret value | fix the secret; your data is still in the branch, encrypted with the old password |
| "Could not push the snapshot" | the workflow token has read-only permission | Settings -> Actions -> General -> Workflow permissions -> **Read and write permissions** |
| Snapshot is much bigger than expected | a folder you added with `save_paths` has big files | narrow the path, or lower the value; the workflow refuses to push over `MaxTotalMB` |
| My files are older than the last few minutes of the session | you were still working when the job ended | the end-of-session save runs with `if: always()`, but a hard cancellation (concurrency, or the 6 hour kill) can lose the last few minutes; press `Save now.cmd` on the desktop before you stop working |
| I want to restore files into a different machine | - | download the branch as a zip and unpack it; `profile.zip` mirrors your user profile, so `Desktop\` etc. drop straight into place |

### Seeing the snapshot branch

```bash
gh browse --repo <owner>/<repo> --branch rdp-data      # or just open the URL
```

Files that are not encrypted can be downloaded straight from GitHub. If the snapshot is encrypted, the `.enc` file is only useful with the password; the workflow is the thing that decrypts it.

### Turning persistence off

Start the run with `save_data: off`, or delete the `rdp-data` branch to start over from an empty profile.

### How the snapshot is protected

`profile.enc` is `RDPBK1 | salt(16) | iv(16) | length(8) | ciphertext | hmac-sha256(32)`, where the AES-256 key and the HMAC key come from PBKDF2-SHA1 with 100,000 iterations over your password. A wrong password fails the HMAC check *before* anything is written to disk. Large snapshots are split into `profile.enc.part000`, `part001`, ... because GitHub refuses files over 100 MB.

---

## 8. Running it on your own Windows PC instead of a runner

The scripts are standalone:

```powershell
# as Administrator
pwsh -File ./scripts/Enable-RdpServer.ps1 -Password 'YourStrongPassword!'
pwsh -File ./scripts/Start-RdpTunnel.ps1 -Provider pinggy
```

That is the exact same code path the workflow uses, minus the runner specific environment variables. To get an RDP session that survives on your own machine, keep the second command running.
