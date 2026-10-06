#Requires -Version 5.1
<#
.SYNOPSIS
    Makes the Windows desktop survive between RDP sessions: your files are
    saved while you work and restored automatically the next time you connect.

.DESCRIPTION
    A GitHub runner is wiped when the job ends, so "saving your data" has to
    mean "storing it somewhere outside the runner". This script keeps a single
    snapshot of your user profile in a git branch of the repository
    (rdp-data by default), which means:

      * it is saved every few minutes while you work, so closing the window,
        losing the connection, or the job hitting the 6 hour limit does not
        lose anything that was there a few minutes earlier
      * it is restored automatically at the start of the next session
      * you can browse or download your files at
        https://github.com/<owner>/<repo>/tree/rdp-data

    The default save set is your Desktop, Documents, Downloads, Pictures,
    Videos, Music, Favorites, Links, Contacts, Saved Games, VS Code settings,
    browser bookmarks and your PowerShell history. Add your own folders with
    -ExtraPaths or the save_paths workflow input.

    On a public repository the snapshot is encrypted with AES-256 + HMAC before
    it is pushed (the password comes from RDP_BACKUP_PASSWORD, or is generated
    and printed in the run summary if you have not set one).

    If you drop a script at Documents\rdp-startup.ps1 it runs automatically at
    the start of every session, after your data is restored - handy for
    reinstalling your tools.

.EXAMPLE
    # save once, then push the snapshot
    pwsh -File ./scripts/Sync-RdpData.ps1 -Mode Save

.EXAMPLE
    # restore the snapshot into this machine
    pwsh -File ./scripts/Sync-RdpData.ps1 -Mode Restore

.EXAMPLE
    # keep saving in the background every 10 minutes
    pwsh -File ./scripts/Sync-RdpData.ps1 -Mode Watch -IntervalMinutes 10
#>
[CmdletBinding()]
param(
    [ValidateSet('Save', 'Restore', 'Watch', 'Status', 'Prepare')]
    [string]$Mode = 'Save',

    # Minutes between snapshots while in Watch mode.
    # 0 = take it from RDP_SAVE_INTERVAL_MINUTES, or use 10.
    [int]$IntervalMinutes = 0,

    # Branch that holds the snapshot.
    [string]$Branch = '',

    # Backup password. Falls back to $env:RDP_BACKUP_PASSWORD.
    [string]$Password = '',

    # auto   = encrypt on a public repository (or whenever a password is set)
    # always = always encrypt (a password is generated if needed)
    # never  = never encrypt (only sensible for a private repository)
    # '' = take it from RDP_SAVE_ENCRYPTION, or use auto.
    [string]$Encryption = '',

    # Extra absolute paths to save, semicolon separated. Falls back to $env:RDP_SAVE_PATHS.
    [string]$ExtraPaths = '',

    # Largest single file that may be pushed (GitHub rejects files over 100 MB,
    # so the payload is split into parts of this size when needed).
    [int]$MaxPartMB = 90,

    # Do not push more than this in total.
    [int]$MaxTotalMB = 2048,

    # Save even when nothing changed.
    [switch]$Force,

    # Working directory for the clone/staging area. Defaults to RUNNER_TEMP\rdp-sync.
    [string]$WorkDir = '',

    # Do not run Documents\rdp-startup.ps1 after restoring.
    [switch]$SkipStartupScript
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- options ----
function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp UTC] [sync] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Set-EnvVar {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value" }
}

function Add-Summary {
    param([string]$Markdown)
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Markdown }
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
    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($upper[$buffer[0] % $upper.Length])
    $chars.Add($lower[$buffer[1] % $lower.Length])
    $chars.Add($digit[$buffer[2] % $digit.Length])
    $chars.Add($other[$buffer[3] % $other.Length])
    for ($i = 4; $i -lt $Length; $i++) { $chars.Add($all[$buffer[$i] % $all.Length]) }
    -join $chars
}

# ------------------------------------------------------------ environment ----
if (-not $WorkDir) {
    if ($env:RUNNER_TEMP) { $WorkDir = Join-Path $env:RUNNER_TEMP 'rdp-sync' }
    else { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) 'rdp-sync' }
}
$stage = Join-Path $WorkDir 'stage'
$repoDir = Join-Path $WorkDir 'git'
$statePath = Join-Path $WorkDir 'sync-state.json'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

if (-not $Branch) {
    if ($env:RDP_SAVE_BRANCH) { $Branch = $env:RDP_SAVE_BRANCH } else { $Branch = 'rdp-data' }
}
if (-not $Password -and $env:RDP_BACKUP_PASSWORD) { $Password = $env:RDP_BACKUP_PASSWORD }
if (-not $ExtraPaths -and $env:RDP_SAVE_PATHS) { $ExtraPaths = $env:RDP_SAVE_PATHS }
if ($IntervalMinutes -le 0) {
    if ($env:RDP_SAVE_INTERVAL_MINUTES -and $env:RDP_SAVE_INTERVAL_MINUTES -match '^\d+$') { $IntervalMinutes = [int]$env:RDP_SAVE_INTERVAL_MINUTES }
    else { $IntervalMinutes = 10 }
}
if (-not $Encryption) {
    if ($env:RDP_SAVE_ENCRYPTION -and @('auto', 'always', 'never') -contains $env:RDP_SAVE_ENCRYPTION) { $Encryption = $env:RDP_SAVE_ENCRYPTION }
    else { $Encryption = 'auto' }
}

$profileRoot = $env:USERPROFILE
$repository = $env:GITHUB_REPOSITORY

# Is the repository public? The event payload knows.
$repoPrivate = $true
if ($env:GITHUB_EVENT_PATH -and (Test-Path $env:GITHUB_EVENT_PATH)) {
    try {
        $payload = Get-Content -Path $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
        if ($null -ne $payload.repository) { $repoPrivate = [bool]$payload.repository.private }
    }
    catch { Write-Step "Could not read the event payload, assuming a private repository." 'WARN' }
}

# ------------------------------------------------------------ save set -------
function Get-SaveSet {
    param(
        [string]$ProfileRoot,
        [string]$Extras
    )

    $items = New-Object System.Collections.Generic.List[object]

    # Whole folders of the user profile.
    $profileDirs = @(
        'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music',
        'Favorites', 'Links', 'Contacts', 'Saved Games'
    )
    foreach ($dir in $profileDirs) {
        $full = Join-Path $ProfileRoot $dir
        if (Test-Path $full) { $items.Add(@{ Source = $full; Store = $dir; Kind = 'profile' }) }
    }

    # Individual files that are small but precious.
    $profileFiles = @(
        'AppData\Roaming\Code\User\settings.json',
        'AppData\Roaming\Code\User\keybindings.json',
        'AppData\Roaming\Code\User\snippets',
        'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt',
        'AppData\Roaming\Microsoft\Edge\User Data\Default\Bookmarks',
        'AppData\Roaming\Microsoft\Edge\User Data\Default\Preferences',
        'AppData\Local\Google\Chrome\User Data\Default\Bookmarks',
        'AppData\Local\Google\Chrome\User Data\Default\Preferences',
        'AppData\Roaming\Microsoft\Windows\Start Menu\Programs',
        '.gitconfig',
        '.wslconfig'
    )
    foreach ($rel in $profileFiles) {
        $full = Join-Path $ProfileRoot $rel
        if (Test-Path $full) { $items.Add(@{ Source = $full; Store = $rel; Kind = 'profile' }) }
    }

    # User supplied paths, stored under _extra\NN so restore knows where they go.
    $index = 0
    if ($Extras) {
        foreach ($raw in ($Extras -split ';')) {
            $path = $raw.Trim()
            if (-not $path) { continue }
            if (-not (Test-Path $path)) { Write-Step "Extra path does not exist, skipping: $path" 'WARN'; continue }
            $items.Add(@{
                Source   = (Resolve-Path $path).Path
                Store    = ('_extra\{0:d2}' -f $index)
                Original = (Resolve-Path $path).Path
                Kind     = 'extra'
            })
            $index++
        }
    }

    return $items
}

# Folders that are never worth saving.
$excludeDirs = @(
    'node_modules', '.git', '.cache', '.venv', '__pycache__', 'Temp',
    'Code Cache', 'GPUCache', 'CacheStorage', 'Service Worker', 'Crashpad',
    'ShaderCache', 'logs', 'Logs'
)
$excludeFiles = @('*.tmp', '*.lock', 'desktop.ini', 'thumbs.db', '*.log')

function Get-Signature {
    param($Items)
    $count = 0
    $bytes = 0
    $newest = [datetime]::MinValue
    foreach ($item in $Items) {
        try {
            $files = Get-ChildItem -LiteralPath $item.Source -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|Cache|Code Cache|GPUCache|Crashpad|Service Worker|__pycache__)\\' }
            foreach ($f in $files) {
                $count++
                $bytes += $f.Length
                if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc }
            }
        }
        catch { }
    }
    return [pscustomobject]@{ Count = $count; Bytes = $bytes; Newest = $newest; Key = "$count|$bytes|$($newest.ToString('o'))" }
}

# ------------------------------------------------------------ encryption -----
<#
    Format:  magic "RDPBK1" (6) | salt (16) | iv (16) | ciphertext (n) | hmac (32)
    PBKDF2-SHA1, 100000 iterations, AES-256-CBC, HMAC-SHA256 over salt+iv+ciphertext.
#>
function Protect-Payload {
    param([string]$InPath, [string]$OutPath, [string]$Password)

    # Layout: magic(6) | salt(16) | iv(16) | plainLength(8, big endian) |
    #         ciphertext(n, zero padded to a 16 byte boundary) | hmac-sha256(32)
    #
    # Padding is done by hand and the exact plaintext length lives in the
    # header, so decrypting never depends on how a particular .NET version
    # handles PKCS7 inside a CryptoStream.
    $plainLength = (Get-Item -LiteralPath $InPath).Length

    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)

    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    $aesKey = $kdf.GetBytes(32)
    $hmacKey = $kdf.GetBytes(32)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $aesKey
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None

    $lengthBytes = [System.BitConverter]::GetBytes([int64]$plainLength)
    [Array]::Reverse($lengthBytes)                                      # big endian

    $cipherPath = "$OutPath.cipher"
    $in = [System.IO.File]::OpenRead($InPath)
    $cipherOut = [System.IO.File]::Create($cipherPath)
    $crypto = New-Object System.Security.Cryptography.CryptoStream(
        $cipherOut, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
    try {
        $buffer = New-Object byte[] 1048576                             # multiple of 16
        while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($read -eq $buffer.Length) {
                $crypto.Write($buffer, 0, $read)
            }
            else {
                $padded = [int]([Math]::Ceiling($read / 16.0) * 16)
                for ($i = $read; $i -lt $padded; $i++) { $buffer[$i] = 0 }
                $crypto.Write($buffer, 0, $padded)
            }
        }
        $crypto.FlushFinalBlock()
    }
    finally {
        $crypto.Dispose(); $cipherOut.Dispose(); $in.Dispose()
    }

    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $hmacKey)
    $hmac.TransformBlock($salt, 0, $salt.Length, $salt, 0) | Out-Null
    $hmac.TransformBlock($iv, 0, $iv.Length, $iv, 0) | Out-Null
    $hmac.TransformBlock($lengthBytes, 0, $lengthBytes.Length, $lengthBytes, 0) | Out-Null
    $cipher = [System.IO.File]::OpenRead($cipherPath)
    try {
        $buffer = New-Object byte[] 1048576
        while (($read = $cipher.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hmac.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
        }
    }
    finally { $cipher.Dispose() }
    $hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null

    $final = [System.IO.File]::Create($OutPath)
    try {
        $magic = [System.Text.Encoding]::ASCII.GetBytes('RDPBK1')
        $final.Write($magic, 0, $magic.Length)
        $final.Write($salt, 0, $salt.Length)
        $final.Write($iv, 0, $iv.Length)
        $final.Write($lengthBytes, 0, $lengthBytes.Length)
        $cipher = [System.IO.File]::OpenRead($cipherPath)
        try { $cipher.CopyTo($final, 1048576) } finally { $cipher.Dispose() }
        $final.Write($hmac.Hash, 0, $hmac.Hash.Length)
    }
    finally { $final.Dispose() }
    Remove-Item $cipherPath -Force -ErrorAction SilentlyContinue

    return @{ PlainLength = $plainLength; Overhead = 46 + 32 }
}

function Unprotect-Payload {
    param([string]$InPath, [string]$OutPath, [string]$Password)

    $headerSize = 46                     # magic + salt + iv + plain length
    $fs = [System.IO.File]::OpenRead($InPath)
    try {
        if ($fs.Length -lt ($headerSize + 32)) { throw 'the backup file is too short' }
        $header = New-Object byte[] $headerSize
        if ($fs.Read($header, 0, $headerSize) -ne $headerSize) { throw 'the backup header is truncated' }
        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 6) -ne 'RDPBK1') { throw 'not an RDP backup file' }

        $salt = $header[6..21]
        $iv = $header[22..37]
        $lengthBytes = $header[38..45]
        [Array]::Reverse($lengthBytes)
        $plainLength = [System.BitConverter]::ToInt64($lengthBytes, 0)

        $cipherLength = $fs.Length - $headerSize - 32
        if ($cipherLength -le 0 -and $plainLength -gt 0) { throw 'the backup has no payload' }

        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
        $aesKey = $kdf.GetBytes(32)
        $hmacKey = $kdf.GetBytes(32)

        # Verify the HMAC before touching the data, using plain reads and
        # explicit offsets so nothing can read ahead past the ciphertext.
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $hmacKey)
        $hmac.TransformBlock($salt, 0, $salt.Length, $salt, 0) | Out-Null
        $hmac.TransformBlock($iv, 0, $iv.Length, $iv, 0) | Out-Null
        $hmac.TransformBlock($lengthBytes, 0, $lengthBytes.Length, $lengthBytes, 0) | Out-Null
        $fs.Position = $headerSize
        $buffer = New-Object byte[] 1048576
        $remaining = $cipherLength
        while ($remaining -gt 0) {
            $want = [Math]::Min($buffer.Length, $remaining)
            $read = $fs.Read($buffer, 0, $want)
            if ($read -le 0) { break }
            $hmac.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
            $remaining -= $read
        }
        $hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
        $fs.Position = $fs.Length - 32
        $storedHmac = New-Object byte[] 32
        if ($fs.Read($storedHmac, 0, 32) -ne 32) { throw 'the backup is truncated' }
        $difference = 0
        for ($i = 0; $i -lt 32; $i++) { $difference = $difference -bor ($storedHmac[$i] -bxor $hmac.Hash[$i]) }
        if ($difference -ne 0) { throw 'the backup password is wrong (or the file is damaged)' }

        # Decrypt with no padding and then cut the output to the stored length.
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $aesKey
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::None

        $fs.Position = $headerSize
        $out = [System.IO.File]::Create($OutPath)
        $crypto = New-Object System.Security.Cryptography.CryptoStream(
            $fs, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
        try {
            $remainingPlain = $plainLength
            $buffer = New-Object byte[] 1048576
            while ($remainingPlain -gt 0) {
                $want = [int][Math]::Min($buffer.Length, $remainingPlain)
                $read = $crypto.Read($buffer, 0, $want)
                if ($read -le 0) { break }
                $out.Write($buffer, 0, $read)
                $remainingPlain -= $read
            }
        }
        finally {
            $crypto.Dispose(); $out.Dispose()
        }
        return $plainLength
    }
    finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- helpers ----
function Invoke-Robocopy {
    param([string]$Source, [string]$Destination, [switch]$Quiet)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @(
        $Source, $Destination, '/E', '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:8',
        '/XF', 'desktop.ini', '/XF', 'thumbs.db', '/XF', '*.tmp'
    )
    if (-not $Quiet) { }
    & robocopy.exe @arguments | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "robocopy failed with exit code $code for $Source" }
    return $code
}

function New-ZipFile {
    param([string]$SourceDir, [string]$ZipPath)
    Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -a -c -f $ZipPath -C $SourceDir '.' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $ZipPath)) { return }
    }
    Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $ZipPath -Force -CompressionLevel Optimal
}

function Expand-ZipFile {
    param([string]$ZipPath, [string]$DestinationDir)
    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -x -f $ZipPath -C $DestinationDir 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive -Path $ZipPath -DestinationPath $DestinationDir -Force
}

function Split-File {
    param([string]$Path, [int]$PartBytes)
    $parts = New-Object System.Collections.Generic.List[string]
    $inputStream = [System.IO.File]::OpenRead($Path)
    try {
        $index = 0
        $buffer = New-Object byte[] 4194304
        while ($inputStream.Position -lt $inputStream.Length) {
            $partPath = "$Path.part{0:d3}" -f $index
            $out = [System.IO.File]::Create($partPath)
            $written = 0
            try {
                while ($written -lt $PartBytes -and $inputStream.Position -lt $inputStream.Length) {
                    $want = [Math]::Min($buffer.Length, [Math]::Min($PartBytes - $written, $inputStream.Length - $inputStream.Position))
                    $read = $inputStream.Read($buffer, 0, $want)
                    if ($read -le 0) { break }
                    $out.Write($buffer, 0, $read)
                    $written += $read
                }
            }
            finally { $out.Dispose() }
            $parts.Add((Split-Path -Leaf $partPath))
            $index++
        }
    }
    finally { $inputStream.Dispose() }
    return $parts
}

function Join-Files {
    param([string[]]$Parts, [string]$OutPath)
    $out = [System.IO.File]::Create($OutPath)
    try {
        foreach ($part in $Parts) {
            $in = [System.IO.File]::OpenRead($part)
            try { $in.CopyTo($out, 4194304) } finally { $in.Dispose() }
        }
    }
    finally { $out.Dispose() }
}

function Get-RepositoryUrl {
    param([switch]$WithToken)
    if (-not $repository) { return '' }
    if ($WithToken) {
        $token = ''
        if ($env:GH_PUSH_TOKEN) { $token = $env:GH_PUSH_TOKEN }
        elseif ($env:GITHUB_TOKEN) { $token = $env:GITHUB_TOKEN }
        if (-not $token) { throw 'No GitHub token available to push the backup (set the GH_PUSH_TOKEN environment variable).' }
        return "https://x-access-token:$token@github.com/$repository.git"
    }
    return "https://github.com/$repository.git"
}

function Read-SyncState {
    if (-not (Test-Path $statePath)) { return $null }
    try { return (Get-Content -Path $statePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-SyncState {
    param([hashtable]$Values)
    $state = @{}
    $existing = Read-SyncState
    if ($existing) {
        foreach ($property in $existing.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    foreach ($key in $Values.Keys) { $state[$key] = $Values[$key] }
    $state['updated'] = (Get-Date).ToUniversalTime().ToString('u')
    $state['watcherPid'] = $PID
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8
}

# ------------------------------------------------------------------ save -----
function Invoke-Save {
    param([switch]$ForceSave)

    $items = Get-SaveSet -ProfileRoot $profileRoot -Extras $ExtraPaths
    if (-not $items -or $items.Count -eq 0) {
        Write-Step 'Nothing to save, no save set could be built.' 'WARN'
        return $false
    }

    $signature = Get-Signature -Items $items
    $state = Read-SyncState
    if (-not $ForceSave -and $state -and $state.signature -eq $signature.Key) {
        Write-Step "Nothing changed since the last snapshot ($($signature.Count) files), skipping."
        Write-SyncState @{ lastCheck = (Get-Date).ToUniversalTime().ToString('u'); signature = $signature.Key }
        return $true
    }

    Write-Step "Building a snapshot of $($signature.Count) files ($([math]::Round($signature.Bytes / 1MB, 1)) MB) ..."
    Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $layout = [ordered]@{
        created     = (Get-Date).ToUniversalTime().ToString('u')
        host        = $env:COMPUTERNAME
        user        = $env:USERNAME
        run_id      = $env:GITHUB_RUN_ID
        profileRoot = $profileRoot
        rootItems   = @()
        extra       = @()
        fileCount   = $signature.Count
        bytes       = $signature.Bytes
    }

    foreach ($item in $items) {
        $target = Join-Path $stage $item.Store
        try {
            Invoke-Robocopy -Source $item.Source -Destination $target | Out-Null
            if ($item.Kind -eq 'extra') {
                $layout.extra += [ordered]@{ store = $item.Store; original = $item.Original }
            }
            else {
                $layout.rootItems += $item.Store
            }
        }
        catch {
            Write-Step "Could not stage $($item.Source): $($_.Exception.Message)" 'WARN'
        }
    }

    $layout | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $stage '_layout.json') -Encoding UTF8

    $zipPath = Join-Path $WorkDir 'profile.zip'
    New-ZipFile -SourceDir $stage -ZipPath $zipPath
    if (-not (Test-Path $zipPath)) { Write-Step 'Could not create the archive.' 'ERROR'; return $false }

    $zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Step "Snapshot archive is $zipMB MB."

    # ---- encryption ----
    $useEncryption = $false
    switch ($Encryption) {
        'always' { $useEncryption = $true }
        'never'  { $useEncryption = $false }
        default  { $useEncryption = ((-not $repoPrivate) -or [bool]$Password) }
    }

    $generatedPassword = $false
    if ($useEncryption -and -not $Password) {
        $Password = New-RandomPassword -Length 24
        $generatedPassword = $true
        Write-Step 'No backup password was configured, so a random one was generated for this session.' 'WARN'
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host '   BACKUP PASSWORD FOR THIS SESSION (save it somewhere):' -ForegroundColor Yellow
        Write-Host "   $Password" -ForegroundColor White
        Write-Host '   Set it as the RDP_BACKUP_PASSWORD secret to get your files' -ForegroundColor Yellow
        Write-Host '   restored automatically in the next session.' -ForegroundColor Yellow
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host ''
    }

    $payload = $zipPath
    if ($useEncryption) {
        $payload = Join-Path $WorkDir 'profile.enc'
        Protect-Payload -InPath $zipPath -OutPath $payload -Password $Password
        Write-Step "Encrypted the snapshot with AES-256 + HMAC (ran with encryption=$Encryption)." 'OK'
    }

    $payloadName = Split-Path -Leaf $payload
    $payloadMB = [math]::Round((Get-Item $payload).Length / 1MB, 1)
    if ($payloadMB -gt $MaxTotalMB) {
        Write-Step "The snapshot is $payloadMB MB which is over the $MaxTotalMB MB limit, not pushing it. Remove some files or raise -MaxTotalMB." 'ERROR'
        return $false
    }

    # ---- split into pushable parts ----
    $partFiles = @()
    if ($payloadMB -gt $MaxPartMB) {
        Write-Step "Splitting the $payloadMB MB snapshot into parts of at most $MaxPartMB MB ..."
        $partFiles = Split-File -Path $payload -PartBytes ($MaxPartMB * 1MB)
        Write-Step "Split into $($partFiles.Count) parts."
    }
    else {
        $partFiles = @($payloadName)
    }

    # ---- push to the backup branch ----
    if (-not $repository) {
        Write-Step 'Not running inside GitHub Actions, so the snapshot stays local.' 'WARN'
        Write-Step "Snapshot: $payload"
        Write-SyncState @{ signature = $signature.Key; lastSave = (Get-Date).ToUniversalTime().ToString('u'); localSnapshot = $payload }
        return $true
    }

    Remove-Item -Path $repoDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
    try {
        & git -C $repoDir init -q 2>&1 | Out-Null
        & git -C $repoDir config user.email 'rdp-sync@users.noreply.github.com' | Out-Null
        & git -C $repoDir config user.name 'RDP data sync' | Out-Null
        & git -C $repoDir config core.autocrlf false | Out-Null
        & git -C $repoDir checkout -q --orphan $Branch 2>&1 | Out-Null

        foreach ($part in $partFiles) {
            Copy-Item -Path (Join-Path $WorkDir $part) -Destination (Join-Path $repoDir $part) -Force
        }
        Copy-Item -Path (Join-Path $stage '_layout.json') -Destination (Join-Path $repoDir '_layout.json') -Force

        $info = [ordered]@{
            saved_at      = (Get-Date).ToUniversalTime().ToString('u')
            run_id        = $env:GITHUB_RUN_ID
            host          = $env:COMPUTERNAME
            user          = $env:USERNAME
            files         = $signature.Count
            source_bytes  = $signature.Bytes
            payload       = if ($useEncryption) { 'encrypted' } else { 'plain' }
            parts         = $partFiles
            payload_mb    = $payloadMB
            profile_root  = $profileRoot
            root_items    = $layout.rootItems
            extra_paths   = @($layout.extra | ForEach-Object { $_.original })
        }
        $info | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $repoDir 'last-save.json') -Encoding UTF8

        & git -C $repoDir add -A 2>&1 | Out-Null
        & git -C $repoDir -c core.safecrlf=false commit -q -m "RDP data snapshot $($info.saved_at) ($($signature.Count) files, $payloadMB MB)" 2>&1 | Out-Null

        $url = Get-RepositoryUrl -WithToken
        if ($env:GH_PUSH_TOKEN) { Write-Host "::add-mask::$($env:GH_PUSH_TOKEN)" }
        & git -C $repoDir -c http.postBuffer=157286400 push -q --force $url "HEAD:refs/heads/$Branch" 2>&1 |
            ForEach-Object { Write-Step "git: $_" 'WARN' }

        if ($LASTEXITCODE -ne 0) {
            Write-Step 'Could not push the snapshot. If the repository blocks write access for workflows, set Settings -> Actions -> General -> Workflow permissions to "Read and write permissions".' 'ERROR'
            return $false
        }

        Write-Step "Saved $($signature.Count) files ($payloadMB MB) to the '$Branch' branch." 'OK'
        if ($env:GITHUB_REPOSITORY) {
            Write-Host "::notice title=Data saved::$($signature.Count) files ($payloadMB MB) are in the $Branch branch"
        }
        Write-SyncState @{
            signature        = $signature.Key
            lastSave         = (Get-Date).ToUniversalTime().ToString('u')
            lastCheck        = (Get-Date).ToUniversalTime().ToString('u')
            payload          = $payloadName
            parts            = $partFiles.Count
            payloadMB        = $payloadMB
            encrypted        = $useEncryption
            fileCount        = $signature.Count
            generatedPassword = $generatedPassword
            password         = if ($generatedPassword) { $Password } else { '' }
        }
        Set-EnvVar -Name 'RDP_BACKUP_BRANCH' -Value $Branch
        Set-EnvVar -Name 'RDP_BACKUP_SOURCE' -Value $payload
        return $true
    }
    catch {
        Write-Step "Saving failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# --------------------------------------------------------------- restore -----
function Invoke-Restore {
    if (-not $repository) {
        Write-Step 'Not running inside GitHub Actions, nothing to restore from.' 'WARN'
        return $false
    }

    Remove-Item -Path $repoDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $repoDir -Force | Out-Null

    $url = Get-RepositoryUrl -WithToken
    Write-Step "Looking for a previous snapshot in the '$Branch' branch ..."
    & git -C $repoDir clone -q --depth 1 --single-branch --branch $Branch $url $repoDir 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $repoDir '_layout.json'))) {
        Write-Step 'No previous snapshot found, this looks like the first session.' 
        Add-Summary @('', '### Data restore', '', 'No previous snapshot was found, this is a fresh profile.', '')
        return $false
    }

    $layout = Get-Content -Path (Join-Path $repoDir '_layout.json') -Raw | ConvertFrom-Json
    $infoPath = Join-Path $repoDir 'last-save.json'
    $savedInfo = $null
    if (Test-Path $infoPath) { $savedInfo = Get-Content -Path $infoPath -Raw | ConvertFrom-Json }

    Write-Step "Found a snapshot from $($layout.created) with $($layout.fileCount) files."

    $payloadZip = Join-Path $WorkDir 'restore.zip'
    $plain = Join-Path $repoDir 'profile.zip'
    $encrypted = Join-Path $repoDir 'profile.enc'

    if (Test-Path $encrypted) {
        if (-not $Password) {
            Write-Step 'The stored snapshot is encrypted and there is no backup password for this run (set the RDP_BACKUP_PASSWORD secret to the password you used). Skipping the restore.' 'WARN'
            Add-Summary @('', '### Data restore', '', 'The stored snapshot is encrypted but no RDP_BACKUP_PASSWORD was available, so nothing was restored.', '')
            return $false
        }
        $parts = Get-ChildItem -Path $repoDir -Filter 'profile.enc.part*' | Sort-Object Name
        $source = $encrypted
        if ($parts.Count -gt 0) {
            $source = Join-Path $WorkDir 'restore.enc'
            Join-Files -Parts ($parts | ForEach-Object { $_.FullName }) -OutPath $source
            Write-Step "Reassembled $($parts.Count) parts."
        }
        Write-Step 'Decrypting the snapshot ...'
        try { Unprotect-Payload -InPath $source -OutPath $payloadZip -Password $Password }
        catch {
            Write-Step "Could not decrypt the snapshot: $($_.Exception.Message)" 'ERROR'
            Add-Summary @('', '### Data restore', '', "The snapshot could not be decrypted: $($_.Exception.Message)", '')
            return $false
        }
    }
    elseif (Test-Path $plain) {
        Copy-Item -Path $plain -Destination $payloadZip -Force
    }
    else {
        $parts = Get-ChildItem -Path $repoDir -Filter 'profile.zip.part*' | Sort-Object Name
        if ($parts.Count -eq 0) { Write-Step 'The snapshot branch has no payload.' 'WARN'; return $false }
        Join-Files -Parts ($parts | ForEach-Object { $_.FullName }) -OutPath $payloadZip
        Write-Step "Reassembled $($parts.Count) parts."
    }

    $extract = Join-Path $WorkDir 'extract'
    Remove-Item -Path $extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-ZipFile -ZipPath $payloadZip -DestinationDir $extract

    $restoredFiles = 0
    foreach ($item in @($layout.rootItems)) {
        $source = Join-Path $extract $item
        if (-not (Test-Path $source)) { continue }
        $target = Join-Path $profileRoot $item
        try {
            Invoke-Robocopy -Source $source -Destination $target -Quiet | Out-Null
            $restoredFiles += (Get-ChildItem -LiteralPath $source -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        }
        catch { Write-Step "Could not restore $item : $($_.Exception.Message)" 'WARN' }
    }

    foreach ($entry in @($layout.extra)) {
        $source = Join-Path $extract $entry.store
        if (-not (Test-Path $source)) { continue }
        $target = $entry.original
        try {
            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Invoke-Robocopy -Source $source -Destination $target -Quiet | Out-Null
            Write-Step "Restored extra path $target" 'OK'
        }
        catch { Write-Step "Could not restore $target : $($_.Exception.Message)" 'WARN' }
    }

    Write-Step "Restored $restoredFiles files into $profileRoot" 'OK'
    Host-Log "your files"
    Add-Summary @(
        '',
        '### Data restore',
        '',
        "| field | value |",
        "| --- | --- |",
        "| snapshot taken | ``$($layout.created)`` |",
        "| files restored | ``$restoredFiles`` |",
        "| profile | ``$profileRoot`` |",
        "| extra paths | ``$($layout.extra.Count)`` |",
        "| source | ``$Branch`` branch |",
        ''
    )
    Write-SyncState @{ restoredAt = (Get-Date).ToUniversalTime().ToString('u'); restoredFiles = $restoredFiles }
    Set-EnvVar -Name 'RDP_RESTORED_FILES' -Value "$restoredFiles"

    if (-not $SkipStartupScript) {
        $startup = Join-Path $profileRoot 'Documents\rdp-startup.ps1'
        if (Test-Path $startup) {
            Write-Step 'Running Documents\rdp-startup.ps1 ...'
            try {
                & pwsh -NoProfile -ExecutionPolicy Bypass -File $startup 2>&1 | ForEach-Object { Write-Host "    startup: $_" }
                Write-Step 'Startup script finished.' 'OK'
            }
            catch { Write-Step "Startup script failed: $($_.Exception.Message)" 'WARN' }
        }
    }

    return $true
}

function Host-Log { param([string]$What) }

# ----------------------------------------------------------- desktop bits ----
function New-HelperFiles {
    $desktop = Join-Path $profileRoot 'Desktop'
    if (-not (Test-Path $desktop)) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
    $helperDir = Join-Path $desktop 'RDP Data'
    New-Item -ItemType Directory -Path $helperDir -Force | Out-Null

    $scriptPath = Join-Path $PSScriptRoot 'Sync-RdpData.ps1'
    $cmd = @(
        '@echo off',
        'rem Saves everything you have done in this session right now.',
        'where pwsh >nul 2>&1',
        'if %ERRORLEVEL%==0 (',
        "  pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Save -Force",
        ') else (',
        "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Save -Force",
        ')',
        'echo.',
        'echo Done. Your files are in the rdp-data branch of the repository.',
        'pause'
    ) -join "`r`n"
    Set-Content -Path (Join-Path $helperDir 'Save now.cmd') -Value $cmd -Encoding ASCII

    $readme = @(
        'YOUR FILES ARE SAVED AUTOMATICALLY',
        '',
        'Everything in Desktop, Documents, Downloads, Pictures, Videos, Music,',
        'Favorites, Links, Contacts, Saved Games, plus your VS Code settings,',
        'browser bookmarks and PowerShell history is snapshotted every few',
        'minutes and pushed to the "rdp-data" branch of the repository.',
        '',
        'The next time you start a session, the newest snapshot is restored',
        'automatically before you log in.',
        '',
        'Double click "Save now.cmd" to force a snapshot immediately.',
        '',
        'You can download everything from',
        'https://github.com/' + $repository + '/tree/' + $Branch,
        '',
        'Installed programs are NOT saved (the machine is rebuilt each run).',
        'Put the commands you want re-run at the start of every session in',
        'Documents\rdp-startup.ps1 and they will be executed automatically.',
        ''
    ) -join "`r`n"
    Set-Content -Path (Join-Path $helperDir 'README.txt') -Value $readme -Encoding ASCII
    Write-Step "Created the helper files in $helperDir"
}

# ---------------------------------------------------------------- prepare ----
<#
    Runs once at the start of a session. Works out whether the snapshot will be
    encrypted and, if it will be but no password is configured, generates one
    and exports it for the whole session. The password ends up in the run
    summary, so it is impossible to miss.
#>
function Invoke-Prepare {
    $useEncryption = $false
    switch ($Encryption) {
        'always' { $useEncryption = $true }
        'never'  { $useEncryption = $false }
        default  { $useEncryption = ((-not $repoPrivate) -or [bool]$Password) }
    }

    $visibility = if ($repoPrivate) { 'private' } else { 'public' }
    $generated = $false
    if ($useEncryption -and -not $Password) {
        $script:Password = New-RandomPassword -Length 24
        $generated = $true
        Set-EnvVar -Name 'RDP_BACKUP_PASSWORD' -Value $script:Password
        Write-Host ''
        Write-Host '  ================================================================' -ForegroundColor Yellow
        Write-Host '   BACKUP PASSWORD FOR THIS SESSION - SAVE IT NOW' -ForegroundColor Yellow
        Write-Host "   $($script:Password)" -ForegroundColor White
        Write-Host '   The snapshot of your files is encrypted with it. Set it as the' -ForegroundColor Yellow
        Write-Host '   RDP_BACKUP_PASSWORD secret and your files will be restored' -ForegroundColor Yellow
        Write-Host '   automatically in the next session.' -ForegroundColor Yellow
        Write-Host '  ================================================================' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "::warning title=Backup password generated::Save this password to restore your files next time: $($script:Password)"
    }

    Write-SyncState @{
        encryption   = $useEncryption
        repoPrivate  = $repoPrivate
        generatedPassword = $generated
        prepareAt    = (Get-Date).ToUniversalTime().ToString('u')
    }

    Add-Summary @(
        '',
        '### Data persistence',
        '',
        "| field | value |",
        "| --- | --- |",
        "| repository | ``$visibility`` |",
        "| snapshot branch | ``$Branch`` |",
        "| autosave every | ``$IntervalMinutes`` minute(s) |",
        "| encrypted | ``$useEncryption`` |",
        "| backup password | $(if ($useEncryption) { if ($generated) { "``$($script:Password)`` (generated now - save it)" } else { 'from the RDP_BACKUP_PASSWORD secret' } } else { 'not used' }) |",
        '',
        "Your files are snapshotted every $IntervalMinutes minute(s) and restored at the start of the next session.",
        "You can download them from ``https://github.com/$repository/tree/$Branch``.",
        ''
    )
    Write-Step "Persistence ready (repository=$visibility, branch=$Branch, encryption=$useEncryption, every $IntervalMinutes min)." 'OK'
    Set-EnvVar -Name 'RDP_SAVE_INTERVAL_MINUTES' -Value "$IntervalMinutes"
    Set-EnvVar -Name 'RDP_SAVE_ENCRYPTION' -Value $Encryption
    return $useEncryption
}

# ------------------------------------------------------------------ watch ----
function Invoke-Watch {
    Write-Step "Watching for changes every $IntervalMinutes minute(s)."
    Write-SyncState @{ watcherStarted = (Get-Date).ToUniversalTime().ToString('u'); interval = $IntervalMinutes }
    $stopAt = (Get-Date).AddHours(7)
    while ((Get-Date) -lt $stopAt) {
        try { Invoke-Save | Out-Null }
        catch { Write-Step "Save cycle failed: $($_.Exception.Message)" 'ERROR' }
        Write-SyncState @{ lastCheck = (Get-Date).ToUniversalTime().ToString('u') }
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}

# ------------------------------------------------------------------- main ----
switch ($Mode) {
    'Save' { Invoke-Save -ForceSave:$Force | Out-Null }
    'Restore' {
        Invoke-Restore | Out-Null
        try { New-HelperFiles } catch { Write-Step "Could not create the desktop helper files: $($_.Exception.Message)" 'WARN' }
    }
    'Watch' { Invoke-Watch }
    'Prepare' { Invoke-Prepare | Out-Null }
    'Status' {
        $state = Read-SyncState
        if ($state) { $state | ConvertTo-Json -Depth 5 } else { Write-Step 'No sync state yet.' }
    }
}
