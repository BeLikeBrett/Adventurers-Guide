#!/bin/sh
set -eu
umask 077
GUIDE_ADDON=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUIDE_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/adventurers-guide"
mkdir -p "$GUIDE_BASE"
GUIDE_NODE=""
if command -v node >/dev/null 2>&1 && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||a===22&&b>=2?0:1)' 2>/dev/null; then
  GUIDE_NODE=$(command -v node)
fi
if [ -z "$GUIDE_NODE" ]; then
  GUIDE_VERSION=v22.23.3
  case $(uname -m) in x86_64) GUIDE_ARCH=x64;; aarch64|arm64) GUIDE_ARCH=arm64;; *) printf '%s\n' 'This launcher supports Linux x64 and ARM64.'; exit 1;; esac
  GUIDE_FOLDER="node-$GUIDE_VERSION-linux-$GUIDE_ARCH"
  GUIDE_NODE="$GUIDE_BASE/runtime/$GUIDE_FOLDER/bin/node"
  if [ ! -x "$GUIDE_NODE" ]; then
    printf '%s\n' 'Preparing Adventurer’s Guide: downloading Node.js from nodejs.org…'
    mkdir -p "$GUIDE_BASE/runtime"
    GUIDE_TMP=$(mktemp -d "$GUIDE_BASE/runtime/download.XXXXXX")
    trap 'rm -rf "$GUIDE_TMP"' EXIT HUP INT TERM
    GUIDE_ARCHIVE="$GUIDE_FOLDER.tar.xz"
    guide_fetch() {
      if command -v curl >/dev/null 2>&1; then curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$1" -o "$2"
      elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
      else printf '%s\n' 'Install curl or wget, then run Start Guide again.'; exit 1; fi
    }
    guide_fetch "https://nodejs.org/dist/$GUIDE_VERSION/$GUIDE_ARCHIVE" "$GUIDE_TMP/$GUIDE_ARCHIVE"
    guide_fetch "https://nodejs.org/dist/$GUIDE_VERSION/SHASUMS256.txt" "$GUIDE_TMP/SHASUMS256.txt"
    GUIDE_HASH=$(awk -v f="$GUIDE_ARCHIVE" '$2==f {print $1}' "$GUIDE_TMP/SHASUMS256.txt")
    [ -n "$GUIDE_HASH" ] || { printf '%s\n' 'Missing download checksum.'; exit 1; }
    printf '%s  %s\n' "$GUIDE_HASH" "$GUIDE_TMP/$GUIDE_ARCHIVE" | sha256sum -c -
    tar -xJf "$GUIDE_TMP/$GUIDE_ARCHIVE" -C "$GUIDE_BASE/runtime"
    rm -rf "$GUIDE_TMP"
    trap - EXIT HUP INT TERM
  fi
fi
nohup "$GUIDE_NODE" "$GUIDE_ADDON/companion/bridge/setup.mjs" >"$GUIDE_BASE/setup.log" 2>&1 </dev/null &
printf '%s\n' 'Adventurer’s Guide setup is opening in your browser.'
