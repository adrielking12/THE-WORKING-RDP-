#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps an RDP session usable for as long as the workflow is allowed to run.

.DESCRIPTION
    Every few minutes this script:
      * speaks the RDP handshake through the public endpoint to make sure the
        tunnel still works end to end
      * restarts the tunnel if it died (ngrok agent restarts, ssh reverse
        tunnels such as pinggy drop after about an hour, ...)
      * restarts the local Remote Desktop service if it stopped listening
      * prints a status line so you can follow what is happening in the log

    A proactive restart only happens when nobody is connected, so it never
    kicks you out of a session you are using.

.EXAMPLE
    pwsh -File ./scripts/Watch-RdpSession.ps1 -Minutes 330
#>
[CmdletBinding()]
param(
    # How long to keep everything alive (minutes).
    [int]$Minutes = 330,

    # Restart the tunnel proactively after this many minutes. Pinggy free
    # sessions are limited to about 60 minutes.
    [int]$RestartAfterMinutes = 50,

    # How often to check the tunnel.
    [int]$CheckIntervalSeconds = 150,

    # Local RDP port.
    [int]$LocalPort = 3389,

    # Path of the state file written by Start-RdpTunnel.ps1.
    [string]$StateFile = '',

    # Path of the state file written by Sync-RdpData.ps1.
    [string]$SyncStateFile = ''
)

$ErrorActionPreference = 'Continue'

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

function Test-PortOpen {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 4000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.Close(); return $false }
        $client.EndConnect($async); $client.Close(); return $true
    }
    catch { return $false }
}

function Test-RdpEndpoint {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 8000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $TimeoutMs
        $request = [byte[]]@(
            0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00
        )
        $stream = $client.GetStream()
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()
        $buffer = New-Object byte[] 64
        $read = 0
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ($read -lt 11 -and (Get-Date) -lt $deadline) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -ge 11 -and $buffer[0] -eq 0x03 -and $buffer[1] -eq 0x00 -and $buffer[5] -eq 0xd0) { return $true }
        return $false
    }
    catch { return $false }
    finally { if ($client) { $client.Close() } }
}

<#
    True when somebody (you) is actually logged in over RDP right now. Used to
    avoid restarting a tunnel out from under a live session.
#>
function Test-ActiveRdpSession {
    try {
        $output = & qwinsta.exe 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*(rdp|rdesktop|ica)[^\s]*\s+(\S+)\s+(\d+)\s+(Active|Connected)') { return $true }
        }
    }
    catch { }
    return $false
}

<#
    The autosave watcher is a separate background process. If it ever exits or
    stops making progress, start it again so nothing you do goes unsaved.
#>
function Test-SyncWatcher {
    param([int]$IntervalMinutes = 10, [switch]$Restart)

    $state = Read-State -Path $SyncStateFile
    if (-not $state) {
        Write-Step 'The autosave watcher has not written any state yet.' 'WARN'
        return $false
    }

    $alive = $false
    if ($state.watcherPid) {
        $alive = [bool](Get-Process -Id ([int]$state.watcherPid) -ErrorAction SilentlyContinue)
    }

    $ageMinutes = 999
    if ($state.lastCheck) {
        try { $ageMinutes = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.lastCheck).ToUniversalTime()).TotalMinutes }
        catch { }
    }

    $limit = [Math]::Max(25, ($IntervalMinutes * 2.5))
    if ($alive -and $ageMinutes -le $limit) { return $true }

    Write-Step "The autosave watcher looks dead (process alive: $alive, last cycle $([int]$ageMinutes) min ago)." 'WARN'
    if (-not $Restart) { return $false }

    $log = Join-Path (Split-Path $SyncStateFile) 'watch-restart.log'
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    try {
        Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-Mode', 'Watch') `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null
        Start-Sleep -Seconds 6
        Write-Step "Autosave watcher restarted (log: $log)" 'OK'
        return $true
    }
    catch {
        Write-Step "Could not restart the autosave watcher: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Read-State {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Path $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------ start ----
if (-not $StateFile) {
    if ($env:RDP_TUNNEL_STATE) { $StateFile = $env:RDP_TUNNEL_STATE }
    elseif ($env:RUNNER_TEMP) { $StateFile = Join-Path $env:RUNNER_TEMP 'tunnel\tunnel-state.json' }
    else { $StateFile = Join-Path ([System.IO.Path]::GetTempPath()) 'rdp-tunnel\tunnel-state.json' }
}

$tunnelScript = Join-Path $PSScriptRoot 'Start-RdpTunnel.ps1'
$syncScript = Join-Path $PSScriptRoot 'Sync-RdpData.ps1'

if (-not $SyncStateFile) {
    if ($env:RDP_SYNC_STATE) { $SyncStateFile = $env:RDP_SYNC_STATE }
    elseif ($env:RUNNER_TEMP) { $SyncStateFile = Join-Path $env:RUNNER_TEMP 'rdp-sync\sync-state.json' }
    else { $SyncStateFile = Join-Path ([System.IO.Path]::GetTempPath()) 'rdp-sync\sync-state.json' }
}
$syncEnabled = ($env:IN_SAVE_DATA -ne 'off') -and (Test-Path $syncScript)
$state = Read-State -Path $StateFile

if (-not $state) {
    Write-Step "No tunnel state found at $StateFile, nothing to watch." 'WARN'
    exit 1
}

$host_ = $state.host
$port = [int]$state.port
$provider = $state.provider
$restartCount = 0

$deadline = (Get-Date).AddMinutes($Minutes)
$nextRestart = (Get-Date).AddMinutes($RestartAfterMinutes)
$failures = 0

Write-Step "Watching $provider endpoint $host_:$port for $Minutes minutes (checking every $CheckIntervalSeconds s)." 'OK'

while ((Get-Date) -lt $deadline) {
    $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMinutes)

    # 1. is the local RDP service still listening?
    if (-not (Test-PortOpen -ComputerName '127.0.0.1' -Port $LocalPort)) {
        Write-Step "The local RDP listener on port $LocalPort is gone, restarting Remote Desktop Services ..." 'WARN'
        try { Restart-Service -Name TermService -Force -ErrorAction Stop }
        catch { & sc.exe start TermService | Out-Null }
        Start-Sleep -Seconds 10
    }

    # 2. does the public endpoint still answer like an RDP server?
    $ok = Test-RdpEndpoint -ComputerName $host_ -Port $port
    $busy = Test-ActiveRdpSession
    if ($ok) { $failures = 0 } else { $failures++ }

    $status = if ($ok) { 'OK' } else { "unreachable (attempt $failures)" }
    $level = if ($ok) { 'OK' } else { 'WARN' }
    Write-Step "status: $status | endpoint $host_:$port | provider $provider | remaining ~$remaining min | session in use: $busy" $level

    # 2b. is your data still being autosaved?
    if ($syncEnabled) {
        $syncInterval = 10
        if ($env:RDP_SAVE_INTERVAL_MINUTES -match '^\d+$') { $syncInterval = [int]$env:RDP_SAVE_INTERVAL_MINUTES }
        Test-SyncWatcher -IntervalMinutes $syncInterval -Restart | Out-Null
    }

    # 3. restart the tunnel when it is broken, or proactively before a relay
    #    drops us (only while nobody is connected).
    $needRestart = ($failures -ge 2) -or ((Get-Date) -ge $nextRestart -and -not $busy)

    if ($needRestart) {
        $restartCount++
        $useProvider = if ($restartCount -le 1) { $provider } else { 'auto' }
        Write-Step "Restarting the tunnel (attempt $restartCount, provider $useProvider) ..." 'WARN'

        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        try {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $tunnelScript -Provider $useProvider -LocalPort $LocalPort 2>&1 |
                ForEach-Object { Write-Host "    $_" }
        }
        catch {
            Write-Step "Tunnel restart raised an exception: $($_.Exception.Message)" 'ERROR'
        }

        $state = Read-State -Path $StateFile
        if ($state) {
            $host_ = $state.host
            $port = [int]$state.port
            $provider = $state.provider
            Write-Step "Tunnel restarted with $provider at $host_:$port" 'OK'
            $failures = 0
        }
        else {
            Write-Step 'The tunnel restart did not produce a new endpoint.' 'ERROR'
        }
        $nextRestart = (Get-Date).AddMinutes($RestartAfterMinutes)
    }

    if ((Get-Date) -ge $deadline) { break }
    Start-Sleep -Seconds $CheckIntervalSeconds
}

Write-Host ''
Write-Step 'The watch loop is done. The job will now end and the machine will be recycled.' 'OK'
Write-Step "Tunnel restarts during this run: $restartCount"
if ($env:GITHUB_STEP_SUMMARY) {
    @('', '### Watch loop finished', '', "Tunnel restarts: ``$restartCount``", '') | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
