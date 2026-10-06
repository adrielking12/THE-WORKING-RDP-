#Requires -Version 5.1
<#
.SYNOPSIS
    One command that turns this Windows machine into a remote desktop and
    publishes it. Elevates itself, sets everything up, starts the tunnel,
    keeps it alive and copies the connection info to your clipboard.

.DESCRIPTION
    Does all of this, in order:

      1. re-launches itself elevated if it is not already running as admin
         (you get one UAC prompt, nothing else)
      2. enables the Remote Desktop server, sets a password and opens the
         firewall (scripts/Enable-RdpServer.ps1)
      3. opens the public tunnel and prints the address (scripts/Start-RdpTunnel.ps1)
      4. copies "address / username / password" to the clipboard
      5. starts the keep-alive watcher in the background so a dropped free
         tunnel is reopened without you noticing
      6. optionally opens the RDP client for a loopback test

.EXAMPLE
    # the whole thing
    pwsh -File ./scripts/Start-Rdp.ps1

.EXAMPLE
    # fixed password, ngrok, and prove it works locally before you walk away
    pwsh -File ./scripts/Start-Rdp.ps1 -Password 'MyStrongPassword!' -Provider ngrok -TestLocal

.EXAMPLE
    # most stable option: your own private Tailscale address
    $env:TS_AUTHKEY = 'tskey-auth-...'
    pwsh -File ./scripts/Start-Rdp.ps1 -Provider tailscale
#>
[CmdletBinding()]
param(
    # Account to enable for RDP. Defaults to the current account.
    [string]$Username = '',

    # Password for that account. One is generated if you leave this out.
    [string]$Password = '',

    # Tunnel provider: auto, pinggy, bore, serveo, ngrok, tailscale.
    [string]$Provider = 'auto',

    # Minutes the keep-alive watcher should run (0 = do not start it).
    [int]$WatchMinutes = 480,

    # Leave the local RDP port open only to this machine's firewall rules
    # (passed through to Enable-RdpServer.ps1 as -KeepFirewallOn).
    [switch]$KeepFirewallOn,

    # Open the RDP client against 127.0.0.1 to prove the server side works.
    [switch]$TestLocal,

    # Start the tunnel but skip enabling the RDP server (already done before).
    [switch]$SkipEnable,

    # Internal: set when the script has already elevated, do not recurse.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp UTC] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

# ------------------------------------------------------------- elevation -----
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Elevated) {
    Write-Step 'Not running as administrator, re-launching elevated (accept the UAC prompt) ...'
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Elevated',
        '-Provider', $Provider,
        '-WatchMinutes', $WatchMinutes
    )
    if ($Username) { $arguments += @('-Username', $Username) }
    if ($Password) { $arguments += @('-Password', "`"$Password`"") }
    if ($KeepFirewallOn) { $arguments += '-KeepFirewallOn' }
    if ($TestLocal) { $arguments += '-TestLocal' }
    if ($SkipEnable) { $arguments += '-SkipEnable' }

    $process = Start-Process -FilePath $psExe -Verb RunAs -PassThru -ArgumentList ($arguments -join ' ')
    Write-Step "An elevated window is doing the work now (pid $($process.Id)). This window can be closed."
    exit 0
}

if (-not $isAdmin) {
    throw 'Still not running as administrator, so the RDP server cannot be enabled.'
}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  Setting up Remote Desktop on this machine' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------- enable server ----
if (-not $SkipEnable) {
    $enable = Join-Path $PSScriptRoot 'Enable-RdpServer.ps1'
    if (-not (Test-Path $enable)) { throw "Missing $enable" }

    $enableArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $enable, '-Port', '3389')
    if ($Username) { $enableArguments += @('-Username', $Username) }
    if ($Password) { $enableArguments += @('-Password', $Password) }
    if ($KeepFirewallOn) { $enableArguments += '-KeepFirewallOn' }

    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    & $psExe @enableArguments
    if ($LASTEXITCODE -ne 0) { throw "Enable-RdpServer.ps1 exited with $LASTEXITCODE" }

    # Enable-RdpServer.ps1 prints the account and password; pick them up from
    # its own environment export, or re-read what the user account is.
    if (-not $Username) { $Username = $env:USERNAME }
    if (-not $Password -and $env:RDP_PASSWORD) { $Password = $env:RDP_PASSWORD }
}
else {
    if (-not $Username) { $Username = $env:USERNAME }
    Write-Step 'Skipping the RDP server setup (-SkipEnable).'
}

if ($TestLocal) {
    Write-Step 'Testing the local RDP listener on 127.0.0.1:3389 ...'
    Start-Sleep -Seconds 3
    $ok = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect('127.0.0.1', 3389, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(5000, $false)) { $client.EndConnect($async); $ok = $true }
        $client.Close()
    }
    catch { $ok = $false }
    if ($ok) {
        Write-Step 'The local listener answers, so the server side is fine.' 'OK'
        try { Start-Process -FilePath 'mstsc.exe' -ArgumentList '/v:127.0.0.1:3389'; Write-Step 'Opened mstsc against 127.0.0.1.' }
        catch { }
    }
    else {
        Write-Step 'Nothing answered on 127.0.0.1:3389. Check the RDP service and the edition (Home editions cannot host RDP).' 'WARN'
    }
}

# --------------------------------------------------------------- tunnel ------
$tunnel = Join-Path $PSScriptRoot 'Start-RdpTunnel.ps1'
if (-not (Test-Path $tunnel)) { throw "Missing $tunnel" }

$tunnelArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tunnel, '-Provider', $Provider, '-LocalPort', '3389')
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
& $psExe @tunnelArguments
if ($LASTEXITCODE -ne 0) {
    Write-Step 'No tunnel could be established. The RDP server itself is set up, so you only need a working provider.' 'ERROR'
    exit 1
}

# Connection details written by Start-RdpTunnel.ps1
$infoFile = if ($env:RDP_INFO_FILE) { $env:RDP_INFO_FILE } else { Join-Path $env:TEMP 'rdp-tunnel\rdp-info.txt' }
$address = ''
$user = $Username
$password = $Password
if (Test-Path $infoFile) {
    foreach ($line in (Get-Content $infoFile)) {
        if ($line -match '^HOST=(.*)$') { $address = $Matches[1] }
        elseif ($line -match '^PORT=(.*)$') { $address = "$address`:$($Matches[1])" }
        elseif ($line -match '^USERNAME=(.*)$') { $user = $Matches[1] }
        elseif ($line -match '^PASSWORD=(.*)$') { $password = $Matches[1] }
    }
}

if ($address) {
    $text = "Address: $address`r`nUsername: $user`r`nPassword: $password"
    try {
        Set-Clipboard -Value $text
        Write-Step 'Copied the address, username and password to your clipboard.' 'OK'
    }
    catch { Write-Step 'Could not reach the clipboard, copy the values above manually.' 'WARN' }

    Write-Host ''
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host "  Connect from anywhere with:  mstsc /v:$address" -ForegroundColor White
    Write-Host '--------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
}

# ------------------------------------------------------------- watcher -------
if ($WatchMinutes -gt 0) {
    $watch = Join-Path $PSScriptRoot 'Watch-RdpSession.ps1'
    if (Test-Path $watch) {
        $logDir = Split-Path -Parent $infoFile
        $log = Join-Path $logDir 'watch.log'
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch, '-Minutes', $WatchMinutes
        ) -RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null
        Write-Step "Keep-alive watcher started for $WatchMinutes minutes (log: $log)." 'OK'
    }
}

Write-Host ''
Write-Step 'All set. Keep this session running or close the window, the tunnel lives in the background.' 'OK'
Write-Host ''
