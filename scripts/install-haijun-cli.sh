#!/usr/bin/env bash
#
# install-haijun-cli.sh — CI-friendly Haijun Code CLI installer.
#
# Downloads the platform tarball parts DIRECTLY (manifest + split parts) rather
# than streaming the remote install-v2.sh. This sidesteps two flaky-classes of
# failure seen in CI:
#
#   1. Edge-cached 404s: install-v2.sh hardcodes a built-time nonce
#      (?v=...) that some Cloudflare edges serve a stale 404 for, even though
#      the fresh nonce answers 200. Here every request uses a fresh nonce and a
#      fallback host.
#   2. `haijun install` clobbering the fork binary with the stock npm CLI. We
#      place the downloaded binary directly under ~/.local/bin and never run
#      the internal installer.
#
# The downloaded binary is checksum-verified against the manifest, placed at
# ~/.local/bin/haijun), and left for PATH.
#
# Usage:
#   bash scripts/install-haijun-cli.sh            # auto-detect platform
#   bash scripts/install-haijun-cli.sh 0.1.0      # pin a version
#   HAIJUN_CLI_ARCH=darwin-x64 bash scripts/install-haijun-cli.sh  # force arch
#
# Env:
#   HAIJUN_DOWNLOAD_BASE_URL   primary host (default downloads.haijun.my.id)
#   HAIJUN_DOWNLOAD_FALLBACK   secondary host (default cli.rompahjunaidi.workers.dev)
#   HAIJUN_CLI_VERSION         version to install (default latest)
#   HAIJUN_CLI_ARCH            force platform key (e.g. darwin-x64)
#   HAIJUN_CLI_BIN_DIR         install dir (default $HOME/.local/bin)
set -euo pipefail

HAIJUN_VERSION="${HAIJUN_CLI_VERSION:-${1:-latest}}"

PRIMARY="${HAIJUN_DOWNLOAD_BASE_URL:-https://downloads.haijun.my.id/cli}"
FALLBACK="${HAIJUN_DOWNLOAD_FALLBACK:-https://cli.rompahjunaidi.workers.dev/cli}"

# Resolve "latest" to a concrete version when a pinned one wasn't given.
if [ "$HAIJUN_VERSION" = "latest" ]; then
  for base in "$PRIMARY" "$FALLBACK"; do
    RAW="$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "$base/latest?v=$RANDOM$(date +%s%N)" 2>/dev/null || true)"
    if [[ "$RAW" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      HAIJUN_VERSION="$RAW"
      break
    fi
  done
  if [ "$HAIJUN_VERSION" = "latest" ]; then
    echo "Error: could not resolve latest Haijun Code CLI version." >&2
    exit 1
  fi
fi

# fetch <rel-path> -> first successful host by descending order is PRIMARY.
# A fresh high-entropy nonce per request avoids edge-cached 404s: second
# resolution timestamps collide on fast retries and the edge then serves a
# stale 404 for the identical URL.
fetch() {
  local rel="$1"
  local out="${2:-}"
  for base in "$PRIMARY" "$FALLBACK"; do
    local url="$base/$rel?nocache=$RANDOM$RANDOM$(date +%s%N)"
    if [ -n "$out" ]; then
      if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "$url" -o "$out" 2>/dev/null; then
        return 0
      fi
    else
      if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        "$url" 2>/dev/null; then
        return 0
      fi
    fi
  done
  return 1
}

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="win32" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64|arm64v8) arch="arm64" ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  PLATFORM="${os}-${arch}"
  # Rosetta: on an ARM Mac running an x64 shell, prefer the native arm64 slice.
  if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
      PLATFORM="darwin-arm64"
    fi
  fi
}

if [ -n "${HAIJUN_CLI_ARCH:-}" ]; then
  PLATFORM="$HAIJUN_CLI_ARCH"
else
  detect_platform
fi

echo ">>> Installing Haijun Code CLI v$HAIJUN_VERSION ($PLATFORM)"

MANIFEST="$(fetch "$HAIJUN_VERSION/manifest.v2.json" || true)"
if [ -z "$MANIFEST" ]; then
  echo "Error: failed to fetch manifest for $HAIJUN_VERSION" >&2
  exit 1
fi

# jq-free extraction with bash regexes keeps the script dependency-light.
get_field() {
  local field="$1"
  local json="$2"
  local one_line
  one_line="$(printf '%s' "$json" | tr -d '\n\r\t')"
  if [[ $one_line =~ \"$PLATFORM\"[[:space:]]*:[[:space:]]*[{][^{}]*\"$field\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ $one_line =~ \"$PLATFORM\"[[:space:]]*:[[:space:]]*[{][^{}]*\"$field\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

checksum="$(get_field checksum "$MANIFEST" || true)"
parts="$(get_field parts "$MANIFEST" || true)"
size="$(get_field size "$MANIFEST" || true)"

if [ -z "$checksum" ] || ! [[ "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Error: platform $PLATFORM not found in manifest (bad checksum)." >&2
  exit 1
fi
if [ -z "$parts" ] || ! [[ "$parts" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: manifest has no parts list for $PLATFORM." >&2
  exit 1
fi

BIN_DIR="${HAIJUN_CLI_BIN_DIR:-$HOME/.local/bin}"
CACHE_DIR="$HOME/.haijun-code/downloads"
mkdir -p "$BIN_DIR" "$CACHE_DIR"

# Windows ships parts as haijun.exe.part$i; POSIX as haijun.part$i.
EXT=""
if [ "$PLATFORM" = "win32-x64" ] || [ "$PLATFORM" = "win32-arm64" ]; then
  EXT=".exe"
fi
OUT="$CACHE_DIR/haijun-${HAIJUN_VERSION}-${PLATFORM}${EXT}"

rm -f "$OUT"
i=0
while [ "$i" -lt "$parts" ]; do
  partname="haijun${EXT}.part${i}"
  if ! fetch "$HAIJUN_VERSION/$PLATFORM/$partname" "$OUT.part$i"; then
    echo "Error: download of part $i ($PLATFORM) failed from both hosts." >&2
    rm -f "$OUT" "$OUT".part* 2>/dev/null
    exit 1
  fi
  cat "$OUT.part$i" >> "$OUT"
  rm -f "$OUT.part$i"
  i=$((i + 1))
done

# Verify checksum (cross-platform: shasum on Darwin, sha256sum elsewhere).
if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$OUT" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$OUT" | awk '{print $1}')"
else
  echo "Error: no sha256 tool (shasum/sha256sum) available." >&2
  rm -f "$OUT"
  exit 1
fi
if [ "$actual" != "$checksum" ]; then
  echo "Error: checksum mismatch." >&2
  echo "  expected: $checksum" >&2
  echo "  actual:   $actual" >&2
  rm -f "$OUT"
  exit 1
fi
echo ">>> Verified sha256 of $PLATFORM binary (${size:-?} bytes)"

chmod +x "$OUT"
if [ -n "$EXT" ]; then
  cp -f "$OUT" "$BIN_DIR/haijun.exe"
  printf '%s' "$BIN_DIR" > "$HOME/.haijun-cli-install-dir"
else
  cp -f "$OUT" "$BIN_DIR/haijun"
  printf '%s' "$BIN_DIR" > "$HOME/.haijun-cli-install-dir"
fi

echo ">>> Installed $BIN_DIR/haijun${EXT}"
export PATH="$BIN_DIR:$PATH"
echo "Re-run with: export PATH=\"$BIN_DIR:\$PATH\""