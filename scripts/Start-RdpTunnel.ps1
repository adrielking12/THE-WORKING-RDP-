#Requires -Version 5.1
<#
.SYNOPSIS
    Exposes a local TCP port (the RDP port, 3389 by default) to the internet so
    you can reach it from your own PC, wherever the machine is running.

.DESCRIPTION
    Providers, in the order they are tried for -Provider auto:

      1. tailscale  - private WireGuard mesh. Most reliable, no account-less
                      option, but free. Needs TS_AUTHKEY.
      2. ngrok      - the classic tcp tunnel. Needs NGROK_AUTH_TOKEN.
                      NOTE: ngrok now requires a payment method on file even
                      for the free plan before TCP endpoints work, so this
                      fails for a lot of accounts - that is exactly why the
                      account-less providers below exist.
      3. pinggy     - plain ssh reverse tunnel, NO account at all
                      (ssh -R0:localhost:3389 tcp@free.pinggy.io)
      4. bore       - open source TCP relay, NO account at all
                      (bore local 3389 --to bore.pub)
      5. serveo     - ssh reverse tunnel, NO account at all

    Whichever provider wins, the script verifies the result by speaking the
    first bytes of the RDP protocol through the public endpoint, then writes
    the connection details to a file, to $GITHUB_ENV and to the job summary.

.EXAMPLE
    pwsh -File ./scripts/Start-RdpTunnel.ps1 -Provider auto -LocalPort 3389

.EXAMPLE
    pwsh -File ./scripts/Start-RdpTunnel.ps1 -Provider pinggy
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'tailscale', 'ngrok', 'pinggy', 'bore', 'serveo')]
    [string]$Provider = 'auto',

    # Local port to publish (RDP is 3389).
    [int]$LocalPort = 3389,

    # ngrok authtoken. Falls back to $env:NGROK_AUTH_TOKEN / $env:NGROK_TOKEN.
    [string]$NgrokToken = '',

    # Tailscale auth key (optional, enables the tailscale provider).
    [string]$TailscaleAuthKey = '',

    # Comma separated CIDR list. Only used by ngrok, which can filter at the
    # edge, for example "203.0.113.7/32".
    [string]$AllowedCidrs = '',

    # Where tunnel logs/PIDs live. Defaults to $env:RUNNER_TEMP\tunnel or %TEMP%\rdp-tunnel.
    [string]$LogDir = '',

    # Where to write the plain text connection info.
    [string]$InfoFile = '',

    # How long to wait for a provider to hand us a public endpoint.
    [int]$StartTimeoutSeconds = 60,

    # Skip the end-to-end RDP handshake test.
    [switch]$SkipSelfTest,

    # Do not kill tunnels started by previous runs of this script.
    [switch]$KeepExisting
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- helpers ----
$script:Warnings = New-Object System.Collections.Generic.List[string]

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
    if ($Level -eq 'WARN' -or $Level -eq 'ERROR') { $script:Warnings.Add($Message) }
}

function Set-EnvVar {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value" }
}

function Get-Text {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    try { return (Get-Content -Path $Path -Raw -ErrorAction Stop) } catch { return '' }
}

function Quote-Arg {
    param([string]$Argument)
    if ($Argument -match '[\s"]') { return '"' + ($Argument -replace '"', '\"') + '"' }
    return $Argument
}

function Start-HiddenProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$StdOut,
        [string]$StdErr
    )
    foreach ($f in @($StdOut, $StdErr)) {
        if ($f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
    }
    $argLine = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    return Start-Process -FilePath $FilePath -ArgumentList $argLine -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
}

function Test-PortOpen {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 6000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.Close(); return $false }
        $client.EndConnect($async)
        $client.Close()
        return $true
    }
    catch { return $false }
}

<#
    Speaks the first exchange of the RDP protocol (an X.224 connection request)
    against host:port and checks that an X.224 connection confirm comes back.
    This proves the whole chain: client -> public relay -> tunnel -> RDP server.
#>
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
        # X.224 Connection Confirm: TPKT header 0x03 0x00, then 0xd0
        if ($read -ge 11 -and $buffer[0] -eq 0x03 -and $buffer[1] -eq 0x00 -and $buffer[5] -eq 0xd0) { return $true }
        return $false
    }
    catch { return $false }
    finally { if ($client) { $client.Close() } }
}

function Get-SshPath {
    $candidates = @()
    $cmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\ssh.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-BinaryPathByName {
    param([string]$Name, [string[]]$ExtraPaths)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $ExtraPaths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Stop-TrackedProcess {
    param([int]$ProcessId)
    if (-not $ProcessId) { return }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($p) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

function Stop-PreviousTunnels {
    param([string]$WorkDir)
    $statePath = Join-Path $WorkDir 'tunnel-state.json'
    if (-not (Test-Path $statePath)) { return }
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        foreach ($processId in @($state.pids)) { Stop-TrackedProcess -ProcessId ([int]$processId) }
        Write-Step "Stopped previous tunnel process(es): $($state.pids -join ', ')"
    }
    catch { }
    Remove-Item $statePath -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------- settings ----
if (-not $LogDir) {
    if ($env:RUNNER_TEMP) { $LogDir = Join-Path $env:RUNNER_TEMP 'tunnel' }
    else { $LogDir = Join-Path ([System.IO.Path]::GetTempPath()) 'rdp-tunnel' }
}
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

if (-not $InfoFile) { $InfoFile = Join-Path $LogDir 'rdp-info.txt' }

if (-not $NgrokToken) {
    if ($env:NGROK_AUTH_TOKEN) { $NgrokToken = $env:NGROK_AUTH_TOKEN }
    elseif ($env:NGROK_TOKEN) { $NgrokToken = $env:NGROK_TOKEN }
}
if (-not $TailscaleAuthKey -and $env:TS_AUTHKEY) { $TailscaleAuthKey = $env:TS_AUTHKEY }
if (-not $AllowedCidrs -and $env:ALLOWED_CIDRS) { $AllowedCidrs = $env:ALLOWED_CIDRS }

$script:NgrokToken = $NgrokToken
$script:WorkDir = $LogDir
$script:LocalPort = $LocalPort

if (-not $KeepExisting) { Stop-PreviousTunnels -WorkDir $LogDir }

# ------------------------------------------------------------- providers -----
function Start-Ngrok {
    if (-not $script:NgrokToken) {
        Write-Step 'ngrok: skipped, no authtoken (set the NGROK_AUTH_TOKEN secret to enable it).'
        return $null
    }
    $work = $script:WorkDir
    $exe = Get-BinaryPathByName -Name 'ngrok.exe' -ExtraPaths @((Join-Path $work 'ngrok.exe'))
    if (-not $exe) {
        Write-Step 'ngrok: downloading the agent ...'
        try {
            $zip = Join-Path $work 'ngrok.zip'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip' -OutFile $zip -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $work -Force
            $exe = Join-Path $work 'ngrok.exe'
        }
        catch {
            Write-Step "ngrok: download failed ($($_.Exception.Message)), trying chocolatey ..." 'WARN'
            try {
                & choco install ngrok -y --no-progress 2>&1 | Out-Null
                $exe = Get-BinaryPathByName -Name 'ngrok.exe'
            }
            catch { }
        }
    }
    if (-not $exe -or -not (Test-Path $exe)) {
        Write-Step 'ngrok: agent unavailable, skipping.' 'WARN'
        return $null
    }

    & $exe config add-authtoken $script:NgrokToken 2>&1 | ForEach-Object { Write-Host "    ngrok: $_" }

    $stdout = Join-Path $work 'ngrok.out'
    $stderr = Join-Path $work 'ngrok.err'
    $arguments = @('tcp', "$($script:LocalPort)", '--log', 'stdout')
    if ($AllowedCidrs) { $arguments += @('--cidr-allow', $AllowedCidrs) }

    $proc = Start-HiddenProcess -FilePath $exe -Arguments $arguments -StdOut $stdout -StdErr $stderr
    $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $text = (Get-Text $stdout) + "`n" + (Get-Text $stderr)
        if ($text -match 'ERR_NGROK_\d+') {
            $err = [regex]::Matches($text, 'ERR_NGROK_\d+[^\r\n]*') | ForEach-Object { $_.Value } | Select-Object -First 3
            Write-Step "ngrok: $($err -join ' | ')" 'WARN'
            if ($text -match 'payment|ERR_NGROK_3004|ERR_NGROK_108') {
                Write-Step 'ngrok: the free plan needs a payment method on file before TCP endpoints work, and only one agent session is allowed per account.' 'WARN'
            }
            Stop-TrackedProcess -ProcessId $proc.Id
            return $null
        }
        # The log line contains both "addr=tcp://localhost:3389" and
        # "url=tcp://x.tcp.ngrok.io:PORT", so look for url= first and never
        # accept a loopback address as the public endpoint.
        $m = [regex]::Match($text, 'url=tcp://([A-Za-z0-9\.\-]+):(\d{2,5})')
        if (-not $m.Success) {
            $m = [regex]::Match($text, 'tcp://(?!localhost|127\.0\.0\.1)([A-Za-z0-9\.\-]+):(\d{2,5})')
        }
        if ($m.Success) {
            return @{ Provider = 'ngrok'; Host = $m.Groups[1].Value; Port = [int]$m.Groups[2].Value; Pid = $proc.Id }
        }
        if ($proc.HasExited) { break }
    }
    Write-Step 'ngrok: no public endpoint was handed out in time.' 'WARN'
    Stop-TrackedProcess -ProcessId $proc.Id
    return $null
}

function Start-Pinggy {
    $ssh = Get-SshPath
    if (-not $ssh) { Write-Step 'pinggy: no ssh client found, skipping.' ; return $null }
    $work = $script:WorkDir
    $key = Join-Path $work 'pinggy_ed25519'
    if (-not (Test-Path $key)) {
        & ssh-keygen -q -t ed25519 -N '""' -C 'rdp-github-runner' -f $key 2>&1 | Out-Null
    }
    if (-not (Test-Path $key)) { Write-Step 'pinggy: could not create an ssh key.' 'WARN'; return $null }

    $stdout = Join-Path $work 'pinggy.out'
    $stderr = Join-Path $work 'pinggy.err'
    $knownHosts = Join-Path $work 'known_hosts'
    if (-not (Test-Path $knownHosts)) { New-Item -ItemType File -Path $knownHosts -Force | Out-Null }

    $arguments = @(
        '-p', '443', '-T',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'TCPKeepAlive=yes',
        '-o', 'ExitOnForwardFailure=yes',
        '-i', $key,
        '-R', "0:localhost:$($script:LocalPort)",
        'tcp@free.pinggy.io'
    )
    $proc = Start-HiddenProcess -FilePath $ssh -Arguments $arguments -StdOut $stdout -StdErr $stderr

    $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $text = (Get-Text $stdout) + "`n" + (Get-Text $stderr)
        $m = [regex]::Match($text, '([A-Za-z0-9\.\-]*pinggy\.io):(\d{2,5})')
        if (-not $m.Success) { $m = [regex]::Match($text, '(?:tcp|port)[^\r\n]{0,40}?:(\d{2,5})', 'IgnoreCase') }
        if ($m.Success) {
            if ($m.Groups.Count -ge 3 -and $m.Groups[1].Value) {
                return @{ Provider = 'pinggy'; Host = $m.Groups[1].Value; Port = [int]$m.Groups[2].Value; Pid = $proc.Id }
            }
            return @{ Provider = 'pinggy'; Host = 'free.pinggy.io'; Port = [int]$m.Groups[1].Value; Pid = $proc.Id }
        }
        if ($proc.HasExited) {
            Write-Step "pinggy: ssh exited early ($($text.Trim()))" 'WARN'
            return $null
        }
    }
    Write-Step 'pinggy: no public port was handed out in time.' 'WARN'
    Stop-TrackedProcess -ProcessId $proc.Id
    return $null
}

function Start-Bore {
    $work = $script:WorkDir
    $exe = Join-Path $work 'bore.exe'
    if (-not (Test-Path $exe)) {
        Write-Step 'bore: downloading the client ...'
        try {
            $zip = Join-Path $work 'bore.zip'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-pc-windows-msvc.zip' -OutFile $zip -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $work -Force
        }
        catch {
            Write-Step "bore: download failed ($($_.Exception.Message))." 'WARN'
            return $null
        }
    }
    if (-not (Test-Path $exe)) { Write-Step 'bore: executable missing.' 'WARN'; return $null }

    # The public bore.pub relay hands out a random port; if it is busy we simply retry.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $stdout = Join-Path $work "bore-$attempt.out"
        $stderr = Join-Path $work "bore-$attempt.err"
        $proc = Start-HiddenProcess -FilePath $exe -Arguments @('local', "$($script:LocalPort)", '--to', 'bore.pub') -StdOut $stdout -StdErr $stderr
        $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 750
            $text = (Get-Text $stdout) + "`n" + (Get-Text $stderr)
            $m = [regex]::Match($text, 'bore\.pub:(\d{2,5})')
            if ($m.Success) {
                return @{ Provider = 'bore'; Host = 'bore.pub'; Port = [int]$m.Groups[1].Value; Pid = $proc.Id }
            }
            if ($proc.HasExited) { break }
        }
        Stop-TrackedProcess -ProcessId $proc.Id
        $detail = ((Get-Text $stdout) + (Get-Text $stderr)).Trim()
        Write-Step "bore: attempt $attempt failed ($detail)" 'WARN'
        Start-Sleep -Seconds 2
    }
    return $null
}

function Start-Serveo {
    $ssh = Get-SshPath
    if (-not $ssh) { Write-Step 'serveo: no ssh client found, skipping.' ; return $null }
    $work = $script:WorkDir
    $stdout = Join-Path $work 'serveo.out'
    $stderr = Join-Path $work 'serveo.err'
    $knownHosts = Join-Path $work 'known_hosts'
    if (-not (Test-Path $knownHosts)) { New-Item -ItemType File -Path $knownHosts -Force | Out-Null }

    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', 'ServerAliveInterval=30',
        '-o', 'ExitOnForwardFailure=yes',
        '-R', "0:localhost:$($script:LocalPort)",
        'serveo.net'
    )
    $proc = Start-HiddenProcess -FilePath $ssh -Arguments $arguments -StdOut $stdout -StdErr $stderr
    $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $text = (Get-Text $stdout) + "`n" + (Get-Text $stderr)
        $m = [regex]::Match($text, 'serveo\.net:(\d{2,5})')
        if ($m.Success) {
            return @{ Provider = 'serveo'; Host = 'serveo.net'; Port = [int]$m.Groups[1].Value; Pid = $proc.Id }
        }
        if ($proc.HasExited) {
            Write-Step "serveo: ssh exited early ($($text.Trim()))" 'WARN'
            return $null
        }
    }
    Write-Step 'serveo: no public port was handed out in time.' 'WARN'
    Stop-TrackedProcess -ProcessId $proc.Id
    return $null
}

<#
    Tailscale gives the machine a stable private IP on your own tailnet. Your
    client has to be logged into the same tailnet, which is why this is
    optional: it is the most reliable option but not "zero setup".
#>
function Start-Tailscale {
    if (-not $TailscaleAuthKey) {
        Write-Step 'tailscale: skipped, no TS_AUTHKEY secret.'
        return $null
    }
    $work = $script:WorkDir
    $exe = 'C:\Program Files\Tailscale\tailscale.exe'
    if (-not (Test-Path $exe)) {
        Write-Step 'tailscale: installing the client ...'
        try {
            $msi = Join-Path $work 'tailscale.msi'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi -ErrorAction Stop
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', (Quote-Arg $msi), '/qn', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { Write-Step "tailscale: msiexec exited with $($p.ExitCode)" 'WARN' }
        }
        catch {
            Write-Step "tailscale: install failed ($($_.Exception.Message))." 'WARN'
            return $null
        }
    }
    if (-not (Test-Path $exe)) { Write-Step 'tailscale: client not installed.' 'WARN'; return $null }

    $hostname = "gh-rdp-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
    & $exe up --authkey=$TailscaleAuthKey --hostname=$hostname --accept-routes --unattended 2>&1 |
        ForEach-Object { Write-Host "    tailscale: $_" }

    $ip = ''
    $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ip = (& $exe ip -4 2>$null | Select-Object -First 1)
        if ($ip) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $ip) { Write-Step 'tailscale: no tailnet IP was assigned.' 'WARN'; return $null }
    return @{ Provider = 'tailscale'; Host = $ip.Trim(); Port = $script:LocalPort; Pid = 0 }
}

# ------------------------------------------------------------ pick one ------
$order = switch ($Provider) {
    'auto' { @('ngrok', 'pinggy', 'bore', 'serveo', 'tailscale') }
    default { @($Provider) }
}

Write-Host ''
Write-Host '=============================================================='
Write-Host '  Opening a public tunnel to the RDP port'
Write-Host "  local port : $LocalPort"
Write-Host "  provider   : $Provider"
Write-Host '=============================================================='

$endpoint = $null
foreach ($candidate in $order) {
    Write-Step "Trying provider '$candidate' ..."
    $result = $null
    try {
        switch ($candidate) {
            'ngrok'     { $result = Start-Ngrok }
            'pinggy'    { $result = Start-Pinggy }
            'bore'      { $result = Start-Bore }
            'serveo'    { $result = Start-Serveo }
            'tailscale' { $result = Start-Tailscale }
        }
    }
    catch {
        Write-Step "$candidate threw an exception: $($_.Exception.Message)" 'WARN'
        $result = $null
    }
    if ($result -and $result.Host -and $result.Port -and $result.Host -notmatch '^(localhost|127\.0\.0\.1)$') {
        $endpoint = $result
        Write-Step "$candidate is up: $($result.Host):$($result.Port)" 'OK'
        break
    }
    Write-Step "$candidate did not produce an endpoint, moving on." 'WARN'
    $debugFiles = Get-ChildItem -Path $script:WorkDir -Filter "$candidate*" -ErrorAction SilentlyContinue
    foreach ($f in $debugFiles) {
        $raw = (Get-Text $f.FullName).Trim()
        if ($raw) { Write-Step "  last output of $($f.Name): $($raw.Substring(0, [Math]::Min(400, $raw.Length)))" }
    }
}

if (-not $endpoint) {
    Write-Host ''
    Write-Step 'No tunnel could be established.' 'ERROR'
    Write-Host 'Hints:'
    Write-Host '  * ngrok now needs a payment method on file even for the free plan, and only one agent session is allowed.'
    Write-Host '  * Set the NGROK_AUTH_TOKEN secret, or use one of the account-less providers (pinggy, bore, serveo).'
    Write-Host '  * Or set the TS_AUTHKEY secret to use tailscale instead.'
    if ($env:GITHUB_STEP_SUMMARY) {
        @('### No tunnel could be established', '', 'See the job log for the per-provider errors above.') |
            Add-Content -Path $env:GITHUB_STEP_SUMMARY
    }
    exit 1
}

# ------------------------------------------------------------ self test -----
$verified = $false
if (-not $SkipSelfTest) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Step "Verifying the RDP handshake through $($endpoint.Host):$($endpoint.Port) (attempt $attempt) ..."
        if (Test-RdpEndpoint -ComputerName $endpoint.Host -Port $endpoint.Port) { $verified = $true; break }
        Start-Sleep -Seconds 4
    }
    if ($verified) { Write-Step 'End-to-end RDP handshake through the public endpoint: OK' 'OK' }
    else { Write-Step 'The public endpoint did not answer with an RDP handshake yet. Some relays refuse connections that come from the same network they were opened from, so this can be a false alarm. Check with your own RDP client.' 'WARN' }
}

# ------------------------------------------------------------ reporting -----
$user = if ($env:RDP_USER) { $env:RDP_USER } else { $env:USERNAME }
$password = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD } else { '(see the "Set RDP credentials" step)' }

$info = [ordered]@{
    provider         = $endpoint.Provider
    host             = $endpoint.Host
    port             = $endpoint.Port
    process_id       = $endpoint.Pid
    local_port       = $LocalPort
    username         = $user
    password         = $password
    verified         = $verified
    started_utc      = (Get-Date).ToUniversalTime().ToString('u')
    connect_windows  = "mstsc /v:$($endpoint.Host):$($endpoint.Port)"
    connect_linux    = "xfreerdp /v:$($endpoint.Host):$($endpoint.Port) /u:$user /p:`"$password`" /dynamic-resolution +clipboard"
    connect_macos    = "Microsoft Remote Desktop app -> PC name: $($endpoint.Host):$($endpoint.Port)"
}

$jsonPath = Join-Path $LogDir 'rdp-info.json'
$info | ConvertTo-Json | Set-Content -Path $jsonPath -Encoding UTF8

@(
    "PROVIDER=$($endpoint.Provider)",
    "HOST=$($endpoint.Host)",
    "PORT=$($endpoint.Port)",
    "USERNAME=$user",
    "PASSWORD=$password",
    "VERIFIED=$verified"
) | Set-Content -Path $InfoFile -Encoding UTF8

# State file so the keep-alive step can restart the tunnel it owns.
$statePath = Join-Path $LogDir 'tunnel-state.json'
@{
    provider  = $endpoint.Provider
    host      = $endpoint.Host
    port      = $endpoint.Port
    pids      = @($endpoint.Pid)
    localPort = $LocalPort
    logDir    = $LogDir
    infoFile  = $InfoFile
    started   = (Get-Date).ToUniversalTime().ToString('u')
} | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

Set-EnvVar -Name 'RDP_HOST' -Value $endpoint.Host
Set-EnvVar -Name 'RDP_TUNNEL_PORT' -Value "$($endpoint.Port)"
Set-EnvVar -Name 'RDP_PROVIDER' -Value $endpoint.Provider
Set-EnvVar -Name 'RDP_INFO_FILE' -Value $InfoFile
Set-EnvVar -Name 'RDP_TUNNEL_STATE' -Value $statePath

# Machine readable lines: client/get-rdp-info.ps1 and get-rdp-info.sh grep for these.
Write-Host ''
Write-Host '[rdp-info] BEGIN'
Write-Host "[rdp-info] provider=$($endpoint.Provider)"
Write-Host "[rdp-info] address=$($endpoint.Host):$($endpoint.Port)"
Write-Host "[rdp-info] username=$user"
Write-Host "[rdp-info] password=$password"
Write-Host "[rdp-info] verified=$verified"
Write-Host '[rdp-info] END'
Write-Host ''

$width = 62
$bar = '=' * $width
Write-Host $bar -ForegroundColor Cyan
Write-Host '  YOUR RDP SESSION IS READY' -ForegroundColor Cyan
Write-Host $bar -ForegroundColor Cyan
Write-Host "  Address  : $($endpoint.Host):$($endpoint.Port)" -ForegroundColor White
Write-Host "  Username : $user" -ForegroundColor White
Write-Host "  Password : $password" -ForegroundColor White
Write-Host "  Provider : $($endpoint.Provider)" -ForegroundColor White
Write-Host $bar -ForegroundColor Cyan
Write-Host '  Windows : mstsc /v:' -NoNewline; Write-Host "$($endpoint.Host):$($endpoint.Port)" -ForegroundColor Green
Write-Host '  Linux   : xfreerdp /v:' -NoNewline; Write-Host "$($endpoint.Host):$($endpoint.Port) /u:$user" -ForegroundColor Green
Write-Host '  macOS   : Microsoft Remote Desktop, PC name ' -NoNewline; Write-Host "$($endpoint.Host):$($endpoint.Port)" -ForegroundColor Green
Write-Host $bar -ForegroundColor Cyan
Write-Host ''

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        '### RDP session ready',
        '',
        '| field | value |',
        '| --- | --- |',
        "| address | ``$($endpoint.Host):$($endpoint.Port)`` |",
        "| username | ``$user`` |",
        "| password | ``$password`` |",
        "| provider | ``$($endpoint.Provider)`` |",
        "| end-to-end verified | ``$verified`` |",
        '',
        'Copy/paste on Windows:',
        '',
        '```',
        "mstsc /v:$($endpoint.Host):$($endpoint.Port)",
        '```',
        '',
        'Copy/paste on Linux:',
        '',
        '```',
        "xfreerdp /v:$($endpoint.Host):$($endpoint.Port) /u:$user /p:'$password' /dynamic-resolution +clipboard",
        '```',
        ''
    ) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "host=$($endpoint.Host)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "port=$($endpoint.Port)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "provider=$($endpoint.Provider)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "verified=$verified"
}

# A notice annotation shows up at the top of the run page, which is a lot
# easier to find than scrolling through the log.
Write-Host "::notice title=RDP endpoint ($($endpoint.Provider))::$($endpoint.Host):$($endpoint.Port) - user $user"

[pscustomobject]@{
    Provider = $endpoint.Provider
    Host     = $endpoint.Host
    Port     = $endpoint.Port
    Username = $user
    Password = $password
    Verified = $verified
    Pid      = $endpoint.Pid
    InfoFile = $InfoFile
}
