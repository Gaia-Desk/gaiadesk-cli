# Install gaiadesk-cli on Windows.
#
#   irm https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.ps1 | iex
#
# Environment:
#   GAIADESK_VERSION=x.y.z    pin a release instead of the latest
#   GAIADESK_INSTALL=<dir>    where to install (default: %LOCALAPPDATA%\GaiaDesk\bin)
#   GAIADESK_DOWNLOAD_BASE    a URL holding the release assets, instead of GitHub
#                             releases (mirrors, tests)
#   GAIADESK_NO_PATH=1        do not add the directory to the user PATH
#
# It downloads gaiadesk-cli-windows-<arch>.zip (or, pinned,
# gaiadesk-cli-<version>-windows-<arch>.zip) and its .sha256 from
# github.com/Gaia-Desk/gaiadesk-releases, checks the SHA-256, installs
# gaiadesk-cli.exe plus gaiadesk.exe (a hard link to it, or a copy), and adds
# the directory to your user PATH. No administrator rights needed.
#
# Windows PowerShell 5.1 or PowerShell 7+.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step([string]$Message) {
    Write-Host "gaiadesk install: $Message"
}

function Get-GaiaDeskArch {
    # A 32-bit PowerShell on 64-bit Windows reports x86 here and the real
    # architecture in PROCESSOR_ARCHITEW6432.
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    if (-not $a) {
        try { $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $a = '' }
    }
    switch -Regex ($a) {
        '^(AMD64|X64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        default { throw "unsupported CPU architecture: '$a' (gaiadesk-cli is built for x64 and arm64 Windows)" }
    }
}

function Get-Sha256Hex([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Save-Url([string]$Url, [string]$OutFile) {
    $params = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow on 5.1
    try { Invoke-WebRequest @params } finally { $ProgressPreference = $old }
}

function Add-UserPath([string]$Dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($user) { $parts = @($user.Split(';') | Where-Object { $_ -ne '' }) }
    $present = $parts | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $present) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'User')
        Write-Step "added $Dir to your user PATH (new terminals will see it)"
    }
    if (-not (($env:Path.Split(';')) | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })) {
        $env:Path = "$env:Path;$Dir"
    }
}

function Install-GaiaDeskCli {
    $onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
    if (-not $onWindows -and $env:GAIADESK_SKIP_OS_CHECK -ne '1') {
        throw 'this is not Windows; use install.sh: curl -fsSL https://raw.githubusercontent.com/Gaia-Desk/gaiadesk-cli/main/install.sh | sh'
    }
    # Windows PowerShell 5.1 may default to TLS 1.0, which GitHub refuses.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { Write-Verbose 'TLS 1.2 could not be enabled explicitly' }

    $repo = 'Gaia-Desk/gaiadesk-releases'
    $version = "$env:GAIADESK_VERSION".Trim()
    if ($version.StartsWith('v')) { $version = $version.Substring(1) }
    if ($version -and $version -notmatch '^[0-9A-Za-z.-]+$') { throw "not a version: '$version' (expected x.y.z)" }

    $dir = "$env:GAIADESK_INSTALL".Trim()
    if (-not $dir) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; set GAIADESK_INSTALL to the directory to install into' }
        $dir = Join-Path $env:LOCALAPPDATA 'GaiaDesk\bin'
    }

    $platform = "windows-$(Get-GaiaDeskArch)"
    if ($version) {
        $asset = "gaiadesk-cli-$version-$platform.zip"
        $base = "https://github.com/$repo/releases/download/v$version"
    } else {
        $asset = "gaiadesk-cli-$platform.zip"
        $base = "https://github.com/$repo/releases/latest/download"
    }
    if ($env:GAIADESK_DOWNLOAD_BASE) { $base = $env:GAIADESK_DOWNLOAD_BASE }
    $base = $base.TrimEnd('/')

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gaiadesk-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset
        $suffix = ''
        if ($version) { $suffix = " (version $version)" }
        Write-Step "downloading $asset$suffix"
        try { Save-Url "$base/$asset" $zip } catch {
            $hint = ''
            if ($version) { $hint = " (is $version a released version?)" }
            throw "could not download $base/$asset$hint`: $($_.Exception.Message)"
        }
        try { Save-Url "$base/$asset.sha256" "$zip.sha256" } catch {
            throw "could not download $base/$asset.sha256: $($_.Exception.Message)"
        }

        $line = (Get-Content -LiteralPath "$zip.sha256" -TotalCount 1)
        if ("$line" -notmatch '^\s*([0-9A-Fa-f]{64})') { throw "$asset.sha256 does not hold a SHA-256" }
        $want = $Matches[1].ToLowerInvariant()
        $got = Get-Sha256Hex $zip
        if ($want -ne $got) { throw "checksum mismatch for ${asset}: expected $want, got $got. Nothing was installed." }
        Write-Step 'checksum ok'

        $x = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
        $exe = Join-Path $x 'gaiadesk-cli.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "$asset has no gaiadesk-cli.exe at its root" }

        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $target = Join-Path $dir 'gaiadesk-cli.exe'
        $alias = Join-Path $dir 'gaiadesk.exe'
        # A running gaiadesk-cli.exe (an MCP server, a held connection) cannot
        # be overwritten, but it can be renamed out of the way.
        foreach ($f in @($target, $alias)) {
            if (Test-Path -LiteralPath $f) {
                $old = "$f.old-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
                Move-Item -LiteralPath $f -Destination $old -Force
                Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $dir -Filter '*.exe.old-*' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $exe -Destination $target
        try {
            New-Item -ItemType HardLink -Path $alias -Target $target | Out-Null
        } catch {
            Copy-Item -LiteralPath $target -Destination $alias
        }

        if ($env:GAIADESK_NO_PATH -ne '1') { Add-UserPath $dir }

        $installed = ''
        try { $installed = (& $target --version 2>$null | Select-Object -First 1) } catch { $installed = '' }
        if (-not $installed) { $installed = 'gaiadesk-cli' }
        Write-Step "installed $installed to $target (and $alias)"
        Write-Step 'next: gaiadesk login, then gaiadesk devices (gaiadesk --help for everything)'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Install-GaiaDeskCli
} catch {
    Write-Host "gaiadesk install: error: $($_.Exception.Message)" -ForegroundColor Red
    # `irm | iex` runs in the caller's session: throw rather than exit, so a
    # failure does not close their window; a script run still fails.
    throw
}
