#Requires -Version 5.1
<#
.SYNOPSIS
    Turns a Windows machine (a GitHub Actions Windows runner, or your own PC)
    into a Remote Desktop server that is ready to accept connections.

.DESCRIPTION
    Idempotent, safe to run more than once. It:
      1. sets fDenyTSConnections = 0 (the "Enable Remote Desktop" checkbox)
      2. makes sure the RDP-Tcp listener is bound to the requested port
      3. opens the firewall (and optionally turns the profile off entirely,
         which is what ephemeral CI runners normally do)
      4. sets a known password for the account you will log in with
      5. removes the idle / disconnected session timeouts so the desktop you
         are connected to does not get logged off in the middle of your work
      6. restarts TermService and waits until the port is really listening

    Connection details are exported through $env:GITHUB_ENV (RDP_USER,
    RDP_PASSWORD, RDP_PORT) when running inside GitHub Actions, so later steps
    can use them.

.EXAMPLE
    pwsh -File ./scripts/Enable-RdpServer.ps1 -Username runneradmin -Password 'P@ssw0rd!'

.EXAMPLE
    pwsh -File ./scripts/Enable-RdpServer.ps1 -Port 3389 -KeepFirewallOn
#>
[CmdletBinding()]
param(
    # Account that will be allowed to log in over RDP. Defaults to the account
    # that is running this script.
    [string]$Username = '',

    # Password for that account. If empty a strong random one is generated.
    [string]$Password = '',

    # TCP port the RDP listener uses.
    [int]$Port = 3389,

    # Keep Windows Firewall enabled (only the RDP rules are added). By default
    # the firewall profiles are disabled, which is what CI runners do.
    [switch]$KeepFirewallOn,

    # Require Network Level Authentication. Off by default for maximum client
    # compatibility (older Android/iOS/FreeRDP clients).
    [switch]$RequireNla,

    # Do not restart the TermService service (used for tests).
    [switch]$SkipServiceRestart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- helpers ----
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

function Set-EnvVar {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value"
    }
}

function New-RandomPassword {
    param([int]$Length = 20)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $other = '!@#$%^&*-_=+?'
    $all = $upper + $lower + $digit + $other

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] ($Length + 8)
    $rng.GetBytes($buffer)

    # Guarantee at least one character from every class (Windows password
    # complexity rules) and then fill the rest.
    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($upper[$buffer[0] % $upper.Length])
    $chars.Add($lower[$buffer[1] % $lower.Length])
    $chars.Add($digit[$buffer[2] % $digit.Length])
    $chars.Add($other[$buffer[3] % $other.Length])
    for ($i = 4; $i -lt $Length; $i++) {
        $chars.Add($all[$buffer[$i] % $all.Length])
    }
    -join $chars
}

function Resolve-TargetAccount {
    param([string]$Requested)
    if ($Requested) {
        if ($Requested -match '\\') { return ($Requested -split '\\')[-1] }
        return $Requested
    }
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $account = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -eq $sid } | Select-Object -First 1
        if ($account) { return $account.Name }
    }
    catch {
        Write-Step "Could not resolve the current local account: $($_.Exception.Message)" 'WARN'
    }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'runneradmin'
}

function Add-AccountToGroup {
    param([string]$Account, [string]$Group)
    try {
        $members = Get-LocalGroupMember -Group $Group -ErrorAction Stop
        if ($members | Where-Object { $_.Name -match "\\$([regex]::Escape($Account))$" }) {
            Write-Step "$Account is already in '$Group'"
            return
        }
        Add-LocalGroupMember -Group $Group -Member $Account -ErrorAction Stop
        Write-Step "Added $Account to '$Group'" 'OK'
    }
    catch {
        Write-Step "Could not add $Account to '$Group': $($_.Exception.Message)" 'WARN'
    }
}

function Wait-ForRdpListener {
    param([int]$ListenerPort, [int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $listening = $false
        try {
            if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                $listening = [bool](Get-NetTCPConnection -LocalPort $ListenerPort -State Listen -ErrorAction SilentlyContinue)
            }
            else {
                $netstat = & netstat.exe -ano 2>$null
                $listening = [bool]($netstat | Select-String -Pattern "LISTENING\s+\d+$" | Select-String -Pattern ":$ListenerPort\s")
            }
        }
        catch { $listening = $false }
        if ($listening) { return $true }
        Start-Sleep -Milliseconds 750
    }
    return $false
}

# ------------------------------------------------------------ pre-flight ----
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw 'This script must run as Administrator (RDP settings live in HKLM and need service restarts).'
}

Write-Host ''
Write-Host '=============================================================='
Write-Host '  Enabling Remote Desktop (RDP) on this machine'
Write-Host '=============================================================='

# ------------------------------------------------------------- 1. account ----
$targetUser = Resolve-TargetAccount -Requested $Username
$generated = $false
if (-not $Password) {
    $Password = New-RandomPassword
    $generated = $true
}

try {
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    Set-LocalUser -Name $targetUser -Password $secure -ErrorAction Stop
    Set-LocalUser -Name $targetUser -PasswordNeverExpires $true -ErrorAction SilentlyContinue
    Write-Step "Password set for account '$targetUser'" 'OK'
}
catch {
    Write-Step "Failed to set the password for '$targetUser': $($_.Exception.Message)" 'ERROR'
    throw
}

Add-AccountToGroup -Account $targetUser -Group 'Remote Desktop Users'
Add-AccountToGroup -Account $targetUser -Group 'Administrators'

# ------------------------------------------------------------ 2. registry ----
Write-Step 'Writing the RDP registry settings'

$tsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$tsWs = Join-Path $tsRoot 'WinStations\RDP-Tcp'

# The main "Remote Desktop" switch.
Set-ItemProperty -Path $tsRoot -Name 'fDenyTSConnections' -Value 0 -Type DWord

# Make sure a listener exists on the requested port and is not restricted to
# the console session.
Set-ItemProperty -Path $tsWs -Name 'PortNumber' -Value $Port -Type DWord
$nlaValue = 0
if ($RequireNla) { $nlaValue = 1 }
Set-ItemProperty -Path $tsWs -Name 'UserAuthentication' -Value $nlaValue -Type DWord
Set-ItemProperty -Path $tsWs -Name 'SecurityLayer' -Value 1 -Type DWord          # negotiate
Set-ItemProperty -Path $tsWs -Name 'MinEncryptionLevel' -Value 1 -Type DWord     # low (clients vary)
Set-ItemProperty -Path $tsWs -Name 'MaxInstanceCount' -Value 20 -Type DWord
Set-ItemProperty -Path $tsWs -Name 'fEnableWinStation' -Value 1 -Type DWord

# Allow a desktop session to stay alive while you are away from the keyboard.
$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
if (-not (Test-Path $policyKey)) { New-Item -Path $policyKey -Force | Out-Null }
Set-ItemProperty -Path $policyKey -Name 'MaxIdleTime' -Value 0 -Type DWord
Set-ItemProperty -Path $policyKey -Name 'MaxDisconnectionTime' -Value 0 -Type DWord
Set-ItemProperty -Path $policyKey -Name 'MaxConnectionTime' -Value 0 -Type DWord
Set-ItemProperty -Path $policyKey -Name 'fResetBroken' -Value 0 -Type DWord -ErrorAction SilentlyContinue

# Keep the machine from going to sleep / locking in the middle of a session.
try {
    powercfg.exe /change standby-timeout-ac 0 | Out-Null
    powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    powercfg.exe /change monitor-timeout-ac 0 | Out-Null
}
catch {
    Write-Step "powercfg tweaks skipped: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------ 3. firewall ----
Write-Step 'Configuring Windows Firewall'

try {
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop | Out-Null
    Write-Step "Enabled the 'Remote Desktop' firewall rule group" 'OK'
}
catch {
    Write-Step "The 'Remote Desktop' rule group was not available: $($_.Exception.Message)" 'WARN'
}

try {
    $ruleName = "RDP-TCP-In-$Port"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
            -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Step "Added inbound firewall rule '$ruleName'" 'OK'
    }
}
catch {
    Write-Step "Could not create the inbound rule: $($_.Exception.Message)" 'WARN'
}

if (-not $KeepFirewallOn) {
    try {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False -ErrorAction Stop
        Write-Step 'Windows Firewall profiles disabled (ephemeral runner)' 'OK'
    }
    catch {
        Write-Step "Could not disable the firewall profiles: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------- 4. TermService ------
if (-not $SkipServiceRestart) {
    Write-Step 'Restarting the Remote Desktop Services service ...'
    try {
        Restart-Service -Name TermService -Force -ErrorAction Stop
    }
    catch {
        Write-Step "Restart-Service TermService failed ($($_.Exception.Message)), trying sc.exe" 'WARN'
        & sc.exe stop TermService | Out-Null
        Start-Sleep -Seconds 3
        & sc.exe start TermService | Out-Null
    }
    Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------ 5. verify ------
$listening = Wait-ForRdpListener -ListenerPort $Port -TimeoutSeconds 90
if ($listening) {
    Write-Step "RDP listener is up on port $Port" 'OK'
}
else {
    Write-Step "Nothing is listening on port $Port yet. RDP may still come up a few seconds later." 'WARN'
}

# ------------------------------------------------------------ 6. report ------
Set-EnvVar -Name 'RDP_USER' -Value $targetUser
Set-EnvVar -Name 'RDP_PASSWORD' -Value $Password
Set-EnvVar -Name 'RDP_PORT' -Value "$Port"

if ($env:GITHUB_STEP_SUMMARY) {
    $mode = if ($RequireNla) { 'NLA required' } else { 'NLA optional (max client compatibility)' }
    @(
        '### RDP server enabled'
        ''
        "| setting | value |"
        "| --- | --- |"
        "| account | ``$targetUser`` |"
        "| password | ``$Password`` |"
        "| port | ``$Port`` |"
        "| listener | $(if ($listening) { 'up' } else { 'not confirmed yet' }) |"
        "| security | $mode |"
        ''
    ) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}

[pscustomobject]@{
    Username            = $targetUser
    Password            = $Password
    PasswordGenerated   = $generated
    Port                = $Port
    Listening           = $listening
    RequireNla          = [bool]$RequireNla
    FirewallDisabled    = (-not $KeepFirewallOn)
}
