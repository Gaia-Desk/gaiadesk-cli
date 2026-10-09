# Smoke-test install.ps1 against a fake release served on localhost by
# `python -m http.server` (through GAIADESK_DOWNLOAD_BASE).
#
#   pwsh -File test/smoke-install.ps1        (Windows; elsewhere it sets GAIADESK_SKIP_OS_CHECK)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("gdsmoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$server = $null
$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows

function Fail([string]$Message) { throw "FAIL: $Message" }
function Pass([string]$Message) { Write-Host "ok: $Message" }

function Build-FakeAsset([string]$Dir, [string]$Name, [string]$Version) {
    $stage = Join-Path $work "stage-$Version"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $exe = Join-Path $stage 'gaiadesk-cli.exe'
    if ($onWindows) {
        # Any real executable will do: the installer only copies and links it.
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\hostname.exe') -Destination $exe -Force
    } else {
        Set-Content -LiteralPath $exe -Value "fake gaiadesk-cli $Version" -NoNewline
    }
    $zip = Join-Path $Dir $Name
    Compress-Archive -LiteralPath $exe -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $Name"
    return $hash
}

function Invoke-Installer([hashtable]$Env) {
    $names = @('GAIADESK_VERSION', 'GAIADESK_INSTALL', 'GAIADESK_DOWNLOAD_BASE', 'GAIADESK_NO_PATH', 'GAIADESK_SKIP_OS_CHECK')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
        if (-not $onWindows) { $env:GAIADESK_SKIP_OS_CHECK = '1' }
        foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        # As `irm ... | iex` runs it: the script's text, in this session.
        Invoke-Expression (Get-Content -Raw -LiteralPath (Join-Path $root 'install.ps1'))
        return $null
    } catch {
        return $_.Exception.Message
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

try {
    $release = Join-Path $work 'release'
    New-Item -ItemType Directory -Path $release | Out-Null
    $latest = @{}; $pinned = @{}
    foreach ($a in @('x64', 'arm64')) {
        $latest[$a] = Build-FakeAsset $release "gaiadesk-cli-windows-$a.zip" '9.9.9'
        $pinned[$a] = Build-FakeAsset $release "gaiadesk-cli-1.2.3-windows-$a.zip" '1.2.3'
    }

    # Windows: `python` (python3 may be the Microsoft Store stub); elsewhere python3.
    $names = @('python3', 'python')
    if ($onWindows) { $names = @('python', 'python3') }
    $python = $names | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $python) { Fail 'no python to serve the fake release' }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $sp = @{
        FilePath               = $python.Source
        ArgumentList           = @('-m', 'http.server', "$port", '--bind', '127.0.0.1')
        WorkingDirectory       = $release
        PassThru               = $true
        RedirectStandardOutput = (Join-Path $work 'srv.out')
        RedirectStandardError  = (Join-Path $work 'srv.err')
    }
    if ($onWindows) { $sp.WindowStyle = 'Hidden' }
    $server = Start-Process @sp
    $base = "http://127.0.0.1:$port"
    $up = $false
    for ($i = 0; $i -lt 50 -and -not $up; $i++) {
        try { Invoke-WebRequest -UseBasicParsing "$base/gaiadesk-cli-windows-x64.zip.sha256" | Out-Null; $up = $true } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $up) { Fail 'the test server did not start' }

    # 1. Latest into GAIADESK_INSTALL, with the user PATH left alone.
    $bin = Join-Path $work 'bin'
    $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = $base; GAIADESK_INSTALL = $bin; GAIADESK_NO_PATH = '1' }
    if ($err) { Fail "install: $err" }
    $cli = Join-Path $bin 'gaiadesk-cli.exe'
    $alias = Join-Path $bin 'gaiadesk.exe'
    if (-not (Test-Path $cli)) { Fail "no $cli" }
    if (-not (Test-Path $alias)) { Fail "no $alias" }
    $h = (Get-FileHash -Algorithm SHA256 $cli).Hash
    if ((Get-FileHash -Algorithm SHA256 $alias).Hash -ne $h) { Fail 'gaiadesk.exe differs from gaiadesk-cli.exe' }
    Pass 'latest installs gaiadesk-cli.exe and gaiadesk.exe'

    # 2. Pinned, over the existing install.
    $before = $h
    $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = $base; GAIADESK_INSTALL = $bin; GAIADESK_VERSION = 'v1.2.3'; GAIADESK_NO_PATH = '1' }
    if ($err) { Fail "pinned: $err" }
    if (-not $onWindows -and (Get-FileHash -Algorithm SHA256 $cli).Hash -eq $before) { Fail 'the pinned install did not replace the binary' }
    if (Get-ChildItem -LiteralPath $bin -Filter '*.old-*') { Fail 'renamed old binaries were left behind' }
    Pass 'GAIADESK_VERSION pins the versioned asset and replaces the old install'

    # 3. A bad checksum installs nothing.
    $bad = Join-Path $release 'bad'
    New-Item -ItemType Directory -Path $bad | Out-Null
    foreach ($a in @('x64', 'arm64')) {
        Copy-Item (Join-Path $release "gaiadesk-cli-windows-$a.zip") $bad
        Set-Content -LiteralPath (Join-Path $bad "gaiadesk-cli-windows-$a.zip.sha256") -Value ('0' * 64 + '  x')
    }
    $bin3 = Join-Path $work 'bin3'
    $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = "$base/bad"; GAIADESK_INSTALL = $bin3; GAIADESK_NO_PATH = '1' }
    if (-not $err -or $err -notmatch 'checksum mismatch') { Fail "expected a checksum mismatch, got: $err" }
    if (Test-Path (Join-Path $bin3 'gaiadesk-cli.exe')) { Fail 'a binary was installed after a checksum mismatch' }
    Pass 'a checksum mismatch fails and installs nothing'

    # 4. A missing version fails with a hint.
    $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = $base; GAIADESK_INSTALL = (Join-Path $work 'bin4'); GAIADESK_VERSION = '7.7.7'; GAIADESK_NO_PATH = '1' }
    if (-not $err -or $err -notmatch 'is 7\.7\.7 a released version') { Fail "expected a missing-version error, got: $err" }
    Pass 'a missing version fails with a hint'

    # 5. The user PATH (Windows only: elsewhere there is no user environment to write).
    if ($onWindows) {
        $savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        try {
            $bin5 = Join-Path $work 'bin5'
            $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = $base; GAIADESK_INSTALL = $bin5 }
            if ($err) { Fail "PATH install: $err" }
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (@($userPath.Split(';') | Where-Object { $_ -ieq $bin5 }).Count -ne 1) { Fail "user PATH lacks $bin5" }
            $err = Invoke-Installer @{ GAIADESK_DOWNLOAD_BASE = $base; GAIADESK_INSTALL = $bin5 }
            if ($err) { Fail "PATH reinstall: $err" }
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (@($userPath.Split(';') | Where-Object { $_ -ieq $bin5 }).Count -ne 1) { Fail 'the PATH entry was added twice' }
            Pass 'the install directory is added to the user PATH once'
        } finally {
            [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
        }
    }

    Write-Host 'all install.ps1 smoke tests passed'
} finally {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# A failure throws (Fail); reaching here means every check passed. Without
# this the last native command's exit code (a deliberately failing install)
# leaks out as the step's result: CI read a passing run as exit 1.
exit 0
