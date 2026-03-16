#!/bin/sh

set -eu

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/Recoba86/openwrt-passwall-openvpn-fix/main/passwall-openvpn-fix.sh}"
INSTALL_PATH="${INSTALL_PATH:-/root/passwall-openvpn-fix.sh}"
RESTART_SERVICES="${RESTART_SERVICES:-1}"

log() {
  printf '[install.sh] %s\n' "$*"
}

fail() {
  printf '[install.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

download_file() {
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -O "${INSTALL_PATH}" "${SCRIPT_URL}"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "${INSTALL_PATH}" "${SCRIPT_URL}"
    return 0
  fi

  fail "missing downloader: install wget or ensure uclient-fetch is available"
}

[ "$(id -u)" = "0" ] || fail "run this script as root"

log "downloading ${SCRIPT_URL}"
download_file
chmod 755 "${INSTALL_PATH}"

log "running ${INSTALL_PATH}"
RESTART_SERVICES="${RESTART_SERVICES}" sh "${INSTALL_PATH}" "$@"

log "completed"
