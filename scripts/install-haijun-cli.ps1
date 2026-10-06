# install-haijun-cli.ps1 — CI-friendly Haijun Code CLI installer for Windows.
#
# Same contract as scripts/install-haijun-cli.sh: download the platform parts
# DIRECTLY (manifest + split .part files) with a fresh nonce and a fallback
# host, verify the sha256, and place haijun.exe under ~/.local/bin without
# running the internal `haijun install` (which can clobber the fork binary with
# the stock npm CLI and also relies on a stale hardcoded nonce that some
# Cloudflare edges 404).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/install-haijun-cli.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/install-haijun-cli.ps1 0.1.0
#
# Env:
#   HAIJUN_DOWNLOAD_BASE_URL   primary host
#   HAIJUN_DOWNLOAD_FALLBACK   secondary host
#   HAIJUN_CLI_VERSION         version (default latest)
#   HAIJUN_CLI_ARCH            force platform key (e.g. win32-x64)
#   HAIJUN_CLI_BIN_DIR         install dir (default $env:USERPROFILE\.local\bin)

param([string]$VersionArg = "")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$PRIMARY   = if ($env:HAIJUN_DOWNLOAD_BASE_URL) { $env:HAIJUN_DOWNLOAD_BASE_URL } else { "https://downloads.haijun.my.id/cli" }
$FALLBACK  = if ($env:HAIJUN_DOWNLOAD_FALLBACK) { $env:HAIJUN_DOWNLOAD_FALLBACK } else { "https://cli.rompahjunaidi.workers.dev/cli" }
$BIN_DIR   = if ($env:HAIJUN_CLI_BIN_DIR) { $env:HAIJUN_CLI_BIN_DIR } else { Join-Path $env:USERPROFILE ".local\bin" }
$CACHE_DIR = Join-Path $env:USERPROFILE ".haijun-code\downloads"

function Get-FromHosts {
    param([string]$RelativeUrl)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        foreach ($base in @($PRIMARY, $FALLBACK)) {
            # Unique nonce per request: second-resolution timestamps collide on
            # fast retries and the edge then serves a cached 404 for the same URL.
            $nonce = [Guid]::NewGuid().ToString("N")
            $url = "${base}/${RelativeUrl}?v=${nonce}"
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                    return @{ ok = $true; content = $resp.Content; bin = $false }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    return @{ ok = $false; content = ""; bin = $false }
}

function Get-BinaryFromHosts {
    param([string]$RelativeUrl, [string]$OutFile)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        foreach ($base in @($PRIMARY, $FALLBACK)) {
            # Unique nonce per request (see Get-FromHosts).
            $nonce = [Guid]::NewGuid().ToString("N")
            $url = "${base}/${RelativeUrl}?v=${nonce}"
            try {
                Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
                return $true
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$version = if ($VersionArg) { $VersionArg } else { if ($env:HAIJUN_CLI_VERSION) { $env:HAIJUN_CLI_VERSION } else { "latest" } }

if ($version -eq "latest") {
    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($base in @($PRIMARY, $FALLBACK)) {
        try {
            $raw = (Invoke-WebRequest -Uri "${base}/latest?v=${nonce}" -UseBasicParsing -TimeoutSec 30).Content
            if ($raw -match "^\d+\.\d+\.\d+") {
                $version = $Matches[0]
                break
            }
        } catch { }
    }
    if ($version -eq "latest") {
        Write-Error "Could not resolve latest Haijun Code CLI version."
        exit 1
    }
}

# Platform key
$os = if ($env:HAIJUN_CLI_ARCH) { $env:HAIJUN_CLI_ARCH } else {
    $bits = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "arm64" }
    "win32-$bits"
}

Write-Host ">>> Installing Haijun Code CLI v$version ($os)"

$man = Get-FromHosts "$version/manifest.v2.json"
if (-not $man.ok) {
    Write-Error "Failed to fetch manifest for $version from both hosts."
    exit 1
}
$manifest = $man.content | ConvertFrom-Json
$plat = $manifest.platforms.$os
if ($null -eq $plat) {
    Write-Error "Platform $os not found in manifest."
    exit 1
}

$checksum = $plat.checksum
$parts = [int]$plat.parts
if ($checksum -notmatch "^[0-9a-f]{64}$" -or $parts -lt 1) {
    Write-Error "Bad manifest entry for $os (checksum=$checksum parts=$parts)."
    exit 1
}

New-Item -ItemType Directory -Force -Path $BIN_DIR, $CACHE_DIR | Out-Null
$OUT = Join-Path $CACHE_DIR "haijun-$version-$os.exe"
if (Test-Path $OUT) { Remove-Item -Force $OUT }

for ($i = 0; $i -lt $parts; $i++) {
    $partFile = "$OUT.part$i"
    $partUrl = "$version/$os/haijun.exe.part$i"
    $ok = Get-BinaryFromHosts $partUrl $partFile
    if (-not $ok) {
        Write-Error "Download of part $i ($os) failed from both hosts."
        foreach ($j in 0..($parts - 1)) { if (Test-Path "$OUT.part$j") { Remove-Item -Force "$OUT.part$j" } }
        exit 1
    }
    $bytes = [System.IO.File]::ReadAllBytes($partFile)
    if ($i -eq 0) { [System.IO.File]::WriteAllBytes($OUT, $bytes) }
    else {
        $stream = [System.IO.File]::Open($OUT, [System.IO.FileMode]::Append)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    Remove-Item -Force $partFile
}

$actual = (Get-FileHash -Algorithm SHA256 -Path $OUT).Hash.ToLowerInvariant()
if ($actual -ne $checksum) {
    Write-Error "Checksum mismatch.`n  expected: $checksum`n  actual:   $actual"
    Remove-Item -Force $OUT
    exit 1
}
Write-Host ">>> Verified sha256 of $os binary"

New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null
Copy-Item -Force $OUT (Join-Path $BIN_DIR "haijun.exe")
"$BIN_DIR" | Out-File -FilePath (Join-Path $env:USERPROFILE ".haijun-cli-install-dir") -Encoding utf8

Write-Host ">>> Installed $(Join-Path $BIN_DIR 'haijun.exe')"
Write-Host "Add the directory to PATH: `$env:PATH = '$BIN_DIR;' + `$env:PATH"