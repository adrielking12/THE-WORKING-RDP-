#Requires -Version 5.1
<#
.SYNOPSIS
    Connects you to your RDP session with zero typing: starts the workflow if
    nothing is running, waits for the desktop, saves the credentials and opens
    Remote Desktop already logged in.

.DESCRIPTION
    Run it, double click connect-rdp.cmd, or pin it to the taskbar. It does
    everything:

      1. looks for a session that is already live (from a local cache, or by
         asking GitHub which run is going)
      2. if there is none, starts the workflow for you
      3. waits until the desktop publishes its address
      4. stores the credentials so Windows logs in without asking
      5. opens Remote Desktop on that address
      6. with -AutoReconnect it keeps watching the endpoint and reconnects when
         a free tunnel rotates its address, so a long session survives the
         hourly pinggy/bore churn without you touching anything

    The last known session is cached at %LOCALAPPDATA%\rdp-auto\session.json (or
    ~/.rdp-auto/session.json) so a second launch is instant.

.EXAMPLE
    # the whole thing, start to desktop, no typing
    pwsh -File ./client/Connect-Rdp.ps1

.EXAMPLE
    # long session that reconnects by itself when the tunnel rotates
    pwsh -File ./client/Connect-Rdp.ps1 -AutoReconnect

.EXAMPLE
    # force a brand new machine, and let it also start a new run when the old
    # job hits GitHub's six hour limit
    pwsh -File ./client/Connect-Rdp.ps1 -NewSession -AutoRestart

.EXAMPLE
    # just show what it found, do not open anything
    pwsh -File ./client/Connect-Rdp.ps1 -NoLaunch
#>
[CmdletBinding()]
param(
    # owner/name. Defaults to the origin remote of the current folder.
    [string]$Repository = '',

    # Workflow file name inside the repository.
    [string]$Workflow = 'main.yml',

    # Branch/ref to run the workflow from. Defaults to the repository default branch.
    [string]$Ref = '',

    # Always start a fresh run, ignoring any live session.
    [switch]$NewSession,

    # Tunnel provider to ask the workflow for: auto, pinggy, bore, serveo, ngrok, tailscale.
    [string]$Tunnel = 'auto',

    # Session length in minutes (GitHub caps a job at 360).
    [int]$DurationMinutes = 330,

    # How long to wait for the desktop to come up before giving up.
    [int]$TunnelTimeoutMinutes = 15,

    # Print the details and do not open a client.
    [switch]$NoLaunch,

    # Keep watching the endpoint and reconnect when it changes.
    [switch]$AutoReconnect,

    # When the run ends, start a new one automatically. Implies -AutoReconnect.
    [switch]$AutoRestart,

    # Seconds between reachability checks while reconnecting.
    [int]$PollSeconds = 20,

    # Write a .rdp shortcut next to this script.
    [switch]$WriteRdpFile = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- helpers ----
function Write-Step { param([string]$m) Write-Host "[rdp] $m" }
function Write-Ok   { param([string]$m) Write-Host "[rdp] $m" -ForegroundColor Green }
function Write-WarnMsg { param([string]$m) Write-Host "[rdp] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "[rdp] $m" -ForegroundColor Red }

function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

$isWindowsHost = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $isWindowsHost = $IsWindows }

# Where the last session is remembered.
if ($env:LOCALAPPDATA) { $stateDir = Join-Path $env:LOCALAPPDATA 'rdp-auto' }
else { $stateDir = Join-Path $HOME '.rdp-auto' }
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$cachePath = Join-Path $stateDir 'session.json'
$rdpFilePath = Join-Path $stateDir 'session.rdp'

# ------------------------------------------------------- dependency check ----
if (-not (Test-Command 'gh')) {
    Write-Bad 'The GitHub CLI (gh) is missing. Install it, then run this again:'
    Write-Host '    winget install --id GitHub.cli' -ForegroundColor White
    exit 1
}

$authOk = $true
try { & gh auth status 2>&1 | Out-Null; $authOk = ($LASTEXITCODE -eq 0) } catch { $authOk = $false }
if (-not $authOk) {
    Write-WarnMsg 'You are not logged in to GitHub yet. Starting the login flow ...'
    & gh auth login --hostname github.com --git-protocol https --web
    try { & gh auth status 2>&1 | Out-Null; $authOk = ($LASTEXITCODE -eq 0) } catch { $authOk = $false }
    if (-not $authOk) { Write-Bad 'Still not authenticated. Run "gh auth login" once, then try again.'; exit 1 }
}

if (-not $Repository) {
    try {
        $remote = (& git remote get-url origin 2>$null)
        if ($remote -match 'github\.com[:/](.+?)(\.git)?$') { $Repository = $Matches[1] }
    }
    catch { }
}
if (-not $Repository) {
    Write-Bad 'Could not work out the repository. Run this from a clone of it, or pass -Repository owner/name.'
    exit 1
}

if (-not $Ref) {
    try { $Ref = (& gh repo view $Repository --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null) } catch { }
    if (-not $Ref) { $Ref = 'main' }
}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  Auto connecting to your RDP session' -ForegroundColor Cyan
Write-Host "  repository: $Repository   ref: $Ref" -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ''

# ------------------------------------------------------------- plumbing ------
function Test-Endpoint {
    param([string]$Address, [int]$TimeoutMs = 5000)
    if (-not $Address) { return $false }
    $parts = $Address.Split(':')
    if ($parts.Count -ne 2) { return $false }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($parts[0], [int]$parts[1], $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { if ($client) { $client.Close() } }
}

function Read-Cache {
    if (-not (Test-Path $cachePath)) { return $null }
    try { return (Get-Content $cachePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Cache {
    param($Session)
    $Session | ConvertTo-Json -Depth 5 | Set-Content -Path $cachePath -Encoding UTF8
}

function Get-DefaultRun {
    $json = & gh run list --repo $Repository --workflow $Workflow --limit 10 `
        --json databaseId,status,conclusion,headBranch,createdAt 2>$null
    if (-not $json) { return $null }
    $runs = $json | ConvertFrom-Json
    if (-not $runs) { return $null }
    $running = $runs | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1
    if ($running) { return $running }
    return $runs | Select-Object -First 1
}

<#
    The workflow uploads the connection details as an artifact, which is much
    more reliable than scraping the log, so try that first and only fall back
    to log parsing when the artifact is not there yet.
#>
function Get-DetailsFromArtifact {
    param([string]$RunId)
    $tmp = Join-Path $stateDir 'artifact'
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    & gh run download $RunId --repo $Repository -n 'rdp-connection-info' -D $tmp 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $file = Get-ChildItem -Path $tmp -Recurse -Filter 'rdp-info.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $file) { return $null }
    $details = @{}
    foreach ($line in (Get-Content $file.FullName)) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $details[$Matches[1].ToLower()] = $Matches[2].Trim() }
    }
    if ($details['host'] -and $details['port'] -and $details['username']) {
        $details['address'] = "{0}:{1}" -f $details['host'], $details['port']
        return $details
    }
    return $null
}

function Get-DetailsFromLog {
    param([string]$RunId)
    $log = & gh run view $RunId --repo $Repository --log 2>$null
    if (-not $log) { return $null }
    $details = @{}
    foreach ($line in ($log -split "`n")) {
        if ($line -match '\[rdp-info\]\s+(\w+)=(.*)$') { $details[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    if ($details['address'] -and $details['username']) { return $details }
    return $null
}

function Get-SessionDetails {
    param([string]$RunId, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $details = Get-DetailsFromArtifact -RunId $RunId
        if (-not $details) { $details = Get-DetailsFromLog -RunId $RunId }
        if ($details -and $details['address'] -and $details['username']) { return $details }
        Start-Sleep -Seconds 10
    }
    return $null
}

function Start-WorkflowRun {
    Write-Step "Starting a fresh workflow run (tunnel=$Tunnel, duration=$DurationMinutes min) ..."
    $output = & gh workflow run $Workflow --repo $Repository --ref $Ref `
        -f "tunnel=$Tunnel" -f "duration_minutes=$DurationMinutes" -f 'save_data=on' 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and "$output" -match 'input|Input') {
        # The version of the workflow on that ref does not know these inputs.
        Write-WarnMsg 'That ref has an older workflow without those inputs, starting it with defaults instead.'
        $output = & gh workflow run $Workflow --repo $Repository --ref $Ref 2>&1
        $code = $LASTEXITCODE
    }
    if ($code -ne 0) {
        Write-Bad "Could not start the workflow: $output"
        if ("$output" -match 'disabled|not accessible|not found') {
            Write-Host ''
            Write-WarnMsg 'If Actions is disabled for the repository, nothing can run. Check:'
            Write-Host "    https://github.com/$Repository/settings/actions" -ForegroundColor White
        }
        return $null
    }
    # Wait for the new run to appear so we can follow it.
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 4
        $run = Get-DefaultRun
        if ($run -and $run.status -ne 'completed') { return $run }
    }
    return $null
}

# --------------------------------------------------------------- session -----
function Set-WindowsCredentials {
    param([string]$Address, [string]$Username, [string]$Password)
    if (-not $isWindowsHost) { return @() }

    $hostName = $Address.Split(':')[0]
    # mstsc looks credentials up as TERMSRV/<server>; include the :port form too
    # because that is what gets stored when you connect to a non standard port.
    $targets = @("TERMSRV/$hostName", "TERMSRV/$($Address)")
    foreach ($target in $targets) {
        & cmdkey.exe /delete:$target 2>&1 | Out-Null
        & cmdkey.exe /generic:$target /user:$Username /pass:$Password 2>&1 | Out-Null
    }
    Write-Step "Stored the credentials for $Username so Remote Desktop does not prompt."
    return $targets
}

function Clear-WindowsCredentials {
    param([string[]]$Targets)
    if (-not $isWindowsHost -or -not $Targets) { return }
    foreach ($target in $Targets) { & cmdkey.exe /delete:$target 2>&1 | Out-Null }
}

function Write-RdpShortcut {
    param([string]$Address, [string]$Username)
    $lines = @(
        "full address:s:$Address",
        "username:s:$Username",
        'prompt for credentials:i:0',
        'authentication level:i:0',
        'enablecredsspsupport:i:1',
        'negotiate security layer:i:1',
        'screen mode id:i:1',
        'use multimon:i:0',
        'desktopwidth:i:1600',
        'desktopheight:i:900',
        'smart sizing:i:1',
        'dynamic resolution:i:1',
        'redirectclipboard:i:1',
        'redirectprinters:i:0',
        'redirectcomports:i:0',
        'redirectsmartcards:i:0',
        'drivestoredirect:s:',
        'audiomode:i:2',
        'bandwidthautodetect:i:1',
        'networkautodetect:i:1',
        'compression:i:1',
        'connection type:i:7',
        'autoreconnection enabled:i:1',
        'keyboardhook:i:2',
        'disable wallpaper:i:0',
        'disable full window drag:i:0',
        'disable menu anims:i:0',
        'disable themes:i:0',
        'allow font smoothing:i:1'
    )
    Set-Content -Path $rdpFilePath -Value $lines -Encoding ASCII
    return $rdpFilePath
}

<#
    Opens the desktop. On Windows that is mstsc with credentials already stored,
    on Linux/macOS freerdp or remmina with the password on the command line.
#>
function Start-RdpClient {
    param([string]$Address, [string]$Username, [string]$Password, [string]$Provider)

    if ($NoLaunch) { return $null }

    if ($isWindowsHost) {
        $shortcut = Write-RdpShortcut -Address $Address -Username $Username
        Write-Step "Opening Remote Desktop on $Address ..."
        return Start-Process -FilePath 'mstsc.exe' -ArgumentList @($shortcut) -PassThru
    }

    if (Test-Command 'xfreerdp') { $exe = 'xfreerdp' }
    elseif (Test-Command 'xfreerdp3') { $exe = 'xfreerdp3' }
    elseif (Test-Command 'remmina') { $exe = 'remmina' }
    else {
        Write-WarnMsg 'No RDP client found. Install one of these and run again:'
        Write-Host '    sudo apt install freerdp2-x11     # or: remmina' -ForegroundColor White
        return $null
    }

    if ($exe -eq 'remmina') {
        Write-Step "Opening Remmina on $Address ..."
        return Start-Process -FilePath 'remmina' -ArgumentList @("-c", "rdp://$Username:$Password@$Address") -PassThru
    }

    Write-Step "Opening $exe on $Address ..."
    return Start-Process -FilePath $exe -PassThru -ArgumentList @(
        "/v:$Address", "/u:$Username", "/p:$Password",
        '/dynamic-resolution', '+clipboard', '/cert:tofu'
    )
}

function New-SessionRecord {
    param([hashtable]$Details, [string]$RunId, [string[]]$Targets)
    return [ordered]@{
        address         = $Details['address']
        username        = $Details['username']
        password        = $Details['password']
        provider        = $Details['provider']
        verified        = $Details['verified']
        run_id          = $RunId
        credentialTargets = $Targets
        saved_at        = (Get-Date).ToUniversalTime().ToString('u')
    }
}

function Show-Session {
    param($Session)
    $bar = '=' * 62
    Write-Host ''
    Write-Ok $bar
    Write-Ok '  CONNECTED'
    Write-Ok $bar
    Write-Host "  Address  : $($Session.address)"
    Write-Host "  Username : $($Session.username)"
    Write-Host "  Password : $($Session.password)"
    Write-Host "  Provider : $($Session.provider)   (run $($Session.run_id))"
    Write-Ok $bar
    Write-Host ''
}

# ------------------------------------------------------- find or start it ----
$cache = Read-Cache
$session = $null

if ($cache -and -not $NewSession) {
    if (Test-Endpoint -Address $cache.address) {
        Write-Ok "Found a live session at $($cache.address) (cached)."
        $session = $cache
    }
    else {
        Write-Step "The cached session at $($cache.address) is gone."
    }
}

if (-not $session -and -not $NewSession) {
    $run = Get-DefaultRun
    if ($run -and $run.status -ne 'completed') {
        Write-Step "Run $($run.databaseId) is going, waiting for its address ..."
        $details = Get-SessionDetails -RunId $run.databaseId -TimeoutMinutes $TunnelTimeoutMinutes
        if ($details -and (Test-Endpoint -Address $details['address'])) {
            $targets = Set-WindowsCredentials -Address $details['address'] -Username $details['username'] -Password $details['password']
            $session = New-SessionRecord -Details $details -RunId $run.databaseId -Targets $targets
        }
        else {
            Write-WarnMsg 'That run never published a reachable address. Starting a fresh one instead.'
            $session = $null
        }
    }
}

if (-not $session) {
    $run = Start-WorkflowRun
    if (-not $run) { Write-Bad 'Could not start a workflow run. See the messages above.'; exit 1 }
    Write-Step "Run $($run.databaseId) started. Waiting for the desktop to come up (this takes about two minutes) ..."

    $waited = 0
    while ($waited -lt ($TunnelTimeoutMinutes * 60)) {
        Start-Sleep -Seconds 15
        $waited += 15
        $status = (& gh run view $run.databaseId --repo $Repository --json status,conclusion 2>$null | ConvertFrom-Json)
        if ($status.conclusion -and $status.conclusion -ne 'success') {
            Write-Bad "The run ended early ($($status.conclusion)). Check the log:"
            Write-Host "    gh run view $($run.databaseId) --repo $Repository --log-failed" -ForegroundColor White
            exit 1
        }
        $details = Get-DetailsFromArtifact -RunId $run.databaseId
        if (-not $details) { $details = Get-DetailsFromLog -RunId $run.databaseId }
        if ($details -and $details['address'] -and $details['username']) {
            $targets = Set-WindowsCredentials -Address $details['address'] -Username $details['username'] -Password $details['password']
            $session = New-SessionRecord -Details $details -RunId $run.databaseId -Targets $targets
            break
        }
        if (($waited % 60) -eq 0) { Write-Step "still waiting ... ($($waited)s)" }
    }

    if (-not $session) {
        Write-Bad "No address after $TunnelTimeoutMinutes minutes. Look at the run log:"
        Write-Host "    gh run view $($run.databaseId) --repo $Repository --log" -ForegroundColor White
        exit 1
    }
}

Save-Cache -Session $session
Show-Session -Session $session

$client = Start-RdpClient -Address $session.address -Username $session.username `
    -Password $session.password -Provider $session.provider

if ($NoLaunch) {
    Write-Host 'Connection details:'
    Write-Host "  Windows : mstsc /v:$($session.address)"
    Write-Host "  Linux   : xfreerdp /v:$($session.address) /u:$($session.username) /p:'$($session.password)' /cert:tofu"
    Write-Host "  RDP file: $rdpFilePath"
    exit 0
}

if ($client) { Write-Ok "Remote Desktop started (pid $($client.Id)). Log in happens automatically." }
Write-Host ''

# ------------------------------------------------------ keep it connected ---
if (-not ($AutoReconnect -or $AutoRestart)) {
    Write-Host "Tip: add -AutoReconnect to follow the tunnel automatically when a free" -ForegroundColor DarkGray
    Write-Host "     relay rotates its address, and -AutoRestart to start a new machine" -ForegroundColor DarkGray
    Write-Host "     when this one hits GitHub's six hour limit." -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

Write-Step "Auto reconnect is on: checking $($session.address) every $PollSeconds s."
Write-Step 'Close this window to stop watching (your session keeps running).'
Write-Host ''

$current = $session
while ($true) {
    Start-Sleep -Seconds $PollSeconds

    # If the client window is gone, the user is done.
    if ($client) {
        $alive = [bool](Get-Process -Id $client.Id -ErrorAction SilentlyContinue)
        if (-not $alive) {
            Write-Step 'You closed the Remote Desktop window, stopping the watch.'
            break
        }
    }

    if (Test-Endpoint -Address $current.address) { continue }

    Write-WarnMsg "The endpoint $($current.address) stopped answering."
    $replacement = $null

    $run = Get-DefaultRun
    if ($run -and $run.status -ne 'completed') {
        $details = Get-DetailsFromArtifact -RunId $run.databaseId
        if (-not $details) { $details = Get-DetailsFromLog -RunId $run.databaseId }
        if ($details -and $details['address'] -and (Test-Endpoint -Address $details['address'])) {
            $replacement = @{ Details = $details; RunId = $run.databaseId; Fresh = $false }
        }
    }

    if (-not $replacement -and $AutoRestart) {
        Write-Step 'This run is over, starting a new machine ...'
        $newRun = Start-WorkflowRun
        if ($newRun) {
            $details = Get-SessionDetails -RunId $newRun.databaseId -TimeoutMinutes $TunnelTimeoutMinutes
            if ($details -and (Test-Endpoint -Address $details['address'])) {
                $replacement = @{ Details = $details; RunId = $newRun.databaseId; Fresh = $true }
            }
        }
    }

    if (-not $replacement) {
        Write-WarnMsg 'No replacement endpoint available yet, will keep trying.'
        continue
    }

    Write-Ok "Reconnecting to $($replacement.Details['address']) ..."
    Clear-WindowsCredentials -Targets $current.credentialTargets
    $targets = Set-WindowsCredentials -Address $replacement.Details['address'] `
        -Username $replacement.Details['username'] -Password $replacement.Details['password']
    $current = New-SessionRecord -Details $replacement.Details -RunId $replacement.RunId -Targets $targets
    Save-Cache -Session $current
    Show-Session -Session $current
    $client = Start-RdpClient -Address $current.address -Username $current.username `
        -Password $current.password -Provider $current.provider
    if ($replacement.Fresh) {
        Write-WarnMsg 'That is a brand new machine, so anything not saved in the rdp-data branch did not come with it.'
    }
}
