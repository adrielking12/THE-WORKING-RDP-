#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the address, username and password of the newest running RDP session
    straight out of the GitHub Actions log, and optionally starts the Remote
    Desktop client for you.

.DESCRIPTION
    Requires the GitHub CLI (gh) and a one time "gh auth login". Works on
    Windows, macOS and Linux with pwsh installed.

.EXAMPLE
    # just show the connection details
    pwsh -File ./client/get-rdp-info.ps1

.EXAMPLE
    # show them and start mstsc immediately
    pwsh -File ./client/get-rdp-info.ps1 -Launch

.EXAMPLE
    # watch until the running workflow publishes its endpoint
    pwsh -File ./client/get-rdp-info.ps1 -Wait -Launch
#>
[CmdletBinding()]
param(
    # owner/name of the repository. Defaults to the current git remote.
    [string]$Repository = '',

    # Workflow file name.
    [string]$Workflow = 'main.yml',

    # Keep polling while the newest run has not published an endpoint yet.
    [switch]$Wait,

    # Start the RDP client as soon as the details are known.
    [switch]$Launch,

    # Also write a .rdp shortcut file next to this script.
    [switch]$WriteRdpFile = $true,

    # Seconds between polls when -Wait is used.
    [int]$PollSeconds = 20
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "[get-rdp-info] $m" }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-WarnMsg { param([string]$m) Write-Host $m -ForegroundColor Yellow }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'The GitHub CLI (gh) is required. Install it from https://cli.github.com and run "gh auth login".'
}

# ------------------------------------------------------------- repository ----
if (-not $Repository) {
    try {
        $remote = (git remote get-url origin 2>$null)
        if ($remote -match 'github\.com[:/](.+?)(\.git)?$') { $Repository = $Matches[1] }
    }
    catch { }
}
if (-not $Repository) {
    throw 'Could not work out the repository. Pass it explicitly, for example -Repository adrielking12/THE-WORKING-RDP-'
}
Write-Info "repository: $Repository"

function Get-LatestRun {
    $json = & gh run list --repo $Repository --workflow $Workflow --limit 10 `
        --json databaseId,status,conclusion,createdAt,headBranch,event 2>$null
    if (-not $json) { return $null }
    $runs = $json | ConvertFrom-Json
    if (-not $runs) { return $null }
    # Prefer a run that is still going, otherwise take the newest one.
    $running = $runs | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1
    if ($running) { return $running }
    return $runs | Select-Object -First 1
}

function Get-RdpDetails {
    param([string]$RunId)
    $log = & gh run view $RunId --repo $Repository --log 2>$null
    if (-not $log) { return $null }
    $details = @{}
    foreach ($line in ($log -split "`n")) {
        if ($line -match '\[rdp-info\]\s+(\w+)=(.*)$') {
            $details[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    if ($details.ContainsKey('address') -and $details.ContainsKey('username')) { return $details }
    return $null
}

# --------------------------------------------------------------- poll --------
$details = $null
while (-not $details) {
    $run = Get-LatestRun
    if (-not $run) {
        throw "No runs of '$Workflow' found in $Repository. Start the workflow first (Actions -> RDP -> Run workflow)."
    }
    Write-Info "newest run: $($run.databaseId) ($($run.status) / $($run.conclusion)) on $($run.headBranch)"
    $details = Get-RdpDetails -RunId $run.databaseId

    if (-not $details) {
        if ($run.status -eq 'completed') {
            Write-WarnMsg 'That run has finished, so its RDP session is gone. Start a new workflow run and try again.'
            exit 2
        }
        if (-not $Wait) {
            Write-WarnMsg 'The run has not published an endpoint yet. Re-run with -Wait to keep polling.'
            exit 3
        }
        Write-Info "no endpoint yet, retrying in $PollSeconds s ..."
        Start-Sleep -Seconds $PollSeconds
    }
}

# -------------------------------------------------------------- output -------
$address = $details['address']
$username = $details['username']
$password = $details['password']
$provider = $details['provider']
$verified = $details['verified']
$hostname = ($address -split ':')[0]

$bar = '=' * 62
Write-Host ''
Write-Ok $bar
Write-Ok '  RDP SESSION FOUND'
Write-Ok $bar
Write-Host "  Address  : $address"
Write-Host "  Username : $username"
Write-Host "  Password : $password"
Write-Host "  Provider : $provider   (end-to-end verified: $verified)"
Write-Ok $bar
Write-Host ''

# --------------------------------------------------------- .rdp shortcut -----
$rdpPath = $null
if ($WriteRdpFile) {
    try {
        $rdpPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "rdp-$($hostname.Replace('.', '-')).rdp"
        @(
            "full address:s:$address",
            "username:s:$username",
            'prompt for credentials:i:0',
            'authentication level:i:0',
            'enablecredsspsupport:i:1',
            'screen mode id:i:1',
            'use multimon:i:1',
            'audiomode:i:0',
            'redirectclipboard:i:1',
            'dynamic resolution:i:1',
            'smart sizing:i:1',
            'displayconnectionbar:i:1',
            'reconnect enable automatic reconnection:i:1'
        ) | Set-Content -Path $rdpPath -Encoding ASCII
        Write-Info "wrote $rdpPath (double click it, then enter the password)"
    }
    catch { Write-WarnMsg "Could not write the .rdp file: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- launch -----
$isWindowsHost = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $isWindowsHost = $IsWindows }

if ($Launch) {
    if ($isWindowsHost) {
        Start-Process -FilePath 'mstsc.exe' -ArgumentList @("/v:$address") | Out-Null
        Write-Ok "Started mstsc /v:$address - log in as $username with the password above."
    }
    else {
        if (Get-Command xfreerdp -ErrorAction SilentlyContinue) {
            Start-Process -FilePath 'xfreerdp' -ArgumentList @("/v:$address", "/u:$username", "/p:$password", '/dynamic-resolution', '+clipboard', '/cert:tofu')
            Write-Ok "Started xfreerdp /v:$address"
        }
        elseif (Get-Command remmina -ErrorAction SilentlyContinue) {
            & remmina -c "rdp://$username@$address"
        }
        else {
            Write-WarnMsg 'No xfreerdp or remmina found. Install one, then connect with:'
            Write-Host "  xfreerdp /v:$address /u:$username /p:'$password' /dynamic-resolution +clipboard /cert:tofu"
        }
    }
}
else {
    Write-Host 'Connect with one of these:'
    Write-Host "  Windows : mstsc /v:$address"
    Write-Host "  Linux   : xfreerdp /v:$address /u:$username /p:'$password' /dynamic-resolution +clipboard /cert:tofu"
    Write-Host "  macOS   : Microsoft Remote Desktop app, PC name $address"
    if ($rdpPath) { Write-Host "  Shortcut: $rdpPath" }
}

[pscustomobject]@{
    Address  = $address
    Username = $username
    Password = $password
    Provider = $provider
    Verified = $verified
    RdpFile  = $rdpPath
}
