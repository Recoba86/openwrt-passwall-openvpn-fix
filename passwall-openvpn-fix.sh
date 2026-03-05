#!/bin/sh

set -eu

SCRIPT_NAME="${0##*/}"
LOG_PREFIX="[${SCRIPT_NAME}]"

OPENVPN_SECTION="${OPENVPN_SECTION:-Yashar}"
OPENVPN_CONFIG="${OPENVPN_CONFIG:-/etc/openvpn/${OPENVPN_SECTION}.ovpn}"
OPENVPN_AUTH_FILE="${OPENVPN_AUTH_FILE:-/etc/openvpn/${OPENVPN_SECTION}.auth}"
OPENVPN_USERPASS_FALLBACK="${OPENVPN_USERPASS_FALLBACK:-/etc/openvpn/${OPENVPN_SECTION}.userpass}"
NETWORK_IFACE="${NETWORK_IFACE:-ovpn0}"
NETWORK_DEVICE="${NETWORK_DEVICE:-tun0}"
PASSWALL_PACKAGE="${PASSWALL_PACKAGE:-passwall2}"
PASSWALL_XRAY_LUA="${PASSWALL_XRAY_LUA:-/usr/lib/lua/luci/passwall2/util_xray.lua}"
PASSWALL_XRAY_BIN="${PASSWALL_XRAY_BIN:-/usr/bin/xray}"
RESTART_SERVICES="${RESTART_SERVICES:-0}"

CHANGED=0
BACKED_UP_FILES=""

log() {
  printf '%s %s\n' "${LOG_PREFIX}" "$*"
}

fail() {
  printf '%s ERROR: %s\n' "${LOG_PREFIX}" "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" = "0" ] || fail "run this script as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

backup_file() {
  file_path="$1"
  [ -f "${file_path}" ] || return 0
  case " ${BACKED_UP_FILES} " in
    *" ${file_path} "*) return 0 ;;
  esac
  backup_path="${file_path}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${file_path}" "${backup_path}"
  BACKED_UP_FILES="${BACKED_UP_FILES} ${file_path}"
  log "backup created: ${backup_path}"
}

set_uci_value() {
  key="$1"
  expected="$2"
  current="$(uci -q get "${key}" 2>/dev/null || true)"
  if [ "${current}" != "${expected}" ]; then
    uci set "${key}=${expected}"
    CHANGED=1
    log "set ${key}='${expected}'"
  fi
}

ensure_openvpn_line() {
  line="$1"
  grep -Fqx "${line}" "${OPENVPN_CONFIG}" 2>/dev/null && return 0
  printf '\n%s\n' "${line}" >> "${OPENVPN_CONFIG}"
  CHANGED=1
  log "added to ${OPENVPN_CONFIG}: ${line}"
}

ensure_openvpn_auth_source() {
  if [ ! -s "${OPENVPN_AUTH_FILE}" ]; then
    if [ -s "${OPENVPN_USERPASS_FALLBACK}" ]; then
      cp "${OPENVPN_USERPASS_FALLBACK}" "${OPENVPN_AUTH_FILE}"
      chmod 600 "${OPENVPN_AUTH_FILE}"
      CHANGED=1
      log "created ${OPENVPN_AUTH_FILE} from ${OPENVPN_USERPASS_FALLBACK}"
    else
      fail "missing credential file: ${OPENVPN_AUTH_FILE}"
    fi
  fi

  if grep -q '^auth-user-pass ' "${OPENVPN_CONFIG}" 2>/dev/null; then
    if ! grep -q "^auth-user-pass ${OPENVPN_AUTH_FILE}\$" "${OPENVPN_CONFIG}" 2>/dev/null; then
      backup_file "${OPENVPN_CONFIG}"
      sed -i "s#^auth-user-pass .*#auth-user-pass ${OPENVPN_AUTH_FILE}#" "${OPENVPN_CONFIG}"
      CHANGED=1
      log "set auth-user-pass source to ${OPENVPN_AUTH_FILE}"
    fi
  elif grep -q '^auth-user-pass$' "${OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${OPENVPN_CONFIG}"
    sed -i "s#^auth-user-pass\$#auth-user-pass ${OPENVPN_AUTH_FILE}#" "${OPENVPN_CONFIG}"
    CHANGED=1
    log "set auth-user-pass source to ${OPENVPN_AUTH_FILE}"
  else
    backup_file "${OPENVPN_CONFIG}"
    printf '\nauth-user-pass %s\n' "${OPENVPN_AUTH_FILE}" >> "${OPENVPN_CONFIG}"
    CHANGED=1
    log "added auth-user-pass source ${OPENVPN_AUTH_FILE}"
  fi
}

ensure_openvpn_profile() {
  [ -f "${OPENVPN_CONFIG}" ] || fail "OpenVPN config not found: ${OPENVPN_CONFIG}"
  ensure_openvpn_auth_source
  if ! grep -Fqx 'route-nopull' "${OPENVPN_CONFIG}" 2>/dev/null || \
     ! grep -Fqx 'pull-filter ignore "redirect-gateway"' "${OPENVPN_CONFIG}" 2>/dev/null || \
     ! grep -Fqx 'auth-nocache' "${OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${OPENVPN_CONFIG}"
    ensure_openvpn_line 'route-nopull'
    ensure_openvpn_line 'pull-filter ignore "redirect-gateway"'
    ensure_openvpn_line 'auth-nocache'
  fi

  if ! uci -q get "openvpn.${OPENVPN_SECTION}" >/dev/null 2>&1; then
    uci set "openvpn.${OPENVPN_SECTION}=openvpn"
    CHANGED=1
    log "created openvpn section: ${OPENVPN_SECTION}"
  fi

  set_uci_value "openvpn.${OPENVPN_SECTION}.config" "${OPENVPN_CONFIG}"
  set_uci_value "openvpn.${OPENVPN_SECTION}.enabled" "1"
}

ensure_network_binding() {
  if ! uci -q get "network.${NETWORK_IFACE}" >/dev/null 2>&1; then
    uci set "network.${NETWORK_IFACE}=interface"
    CHANGED=1
    log "created network interface section: ${NETWORK_IFACE}"
  fi

  set_uci_value "network.${NETWORK_IFACE}.proto" "none"
  set_uci_value "network.${NETWORK_IFACE}.device" "${NETWORK_DEVICE}"
}

ensure_passwall_paths() {
  uci -q get "${PASSWALL_PACKAGE}.@global_app[0]" >/dev/null 2>&1 || fail "missing ${PASSWALL_PACKAGE}.@global_app[0]"
  [ -x "${PASSWALL_XRAY_BIN}" ] || fail "xray binary not found: ${PASSWALL_XRAY_BIN}"
  set_uci_value "${PASSWALL_PACKAGE}.@global_app[0].xray_file" "${PASSWALL_XRAY_BIN}"
}

patch_passwall_xray_generator() {
  [ -f "${PASSWALL_XRAY_LUA}" ] || fail "Passwall xray generator not found: ${PASSWALL_XRAY_LUA}"
  patch_state="$(
    lua - "${PASSWALL_XRAY_LUA}" <<'EOF'
local path = arg[1]
local f = assert(io.open(path, "r"))
local source = f:read("*a")
f:close()

local original = source
if not source:find("local function resolve_bind_interface", 1, true) then
  local anchor = "local CACHE_PATH = api.CACHE_PATH\n"
  local helper = anchor .. [[

local function resolve_bind_interface(iface)
  if not iface or iface == "" then return iface end
  local device = uci:get("network", iface, "device")
  if device and device ~= "" then
    return device
  end
  return iface
end
]]
  local replaced, count = source:gsub(anchor, helper, 1)
  assert(count == 1, "failed to insert resolve_bind_interface helper")
  source = replaced
end

local function ensure_replace(pattern, replacement)
  if source:find(replacement, 1, true) then
    return
  end

  local replaced_count = 0
  source = source:gsub(
    pattern,
    function()
      replaced_count = replaced_count + 1
      return replacement
    end
  )

  assert(replaced_count >= 1, "missing pattern: " .. pattern)
end

ensure_replace(
  "interface = node%.outbound_node_iface",
  "interface = resolve_bind_interface(node.outbound_node_iface)"
)
ensure_replace(
  "interface = node%.iface",
  "interface = resolve_bind_interface(node.iface)"
)
ensure_replace(
  'api%.TMP_IFACE_PATH, node%.outbound_node_iface%)',
  'api.TMP_IFACE_PATH, resolve_bind_interface(node.outbound_node_iface))'
)
ensure_replace(
  'api%.TMP_IFACE_PATH, node%.iface%)',
  'api.TMP_IFACE_PATH, resolve_bind_interface(node.iface))'
)

assert(source:find("interface = resolve_bind_interface(node.outbound_node_iface)", 1, true))
assert(source:find("interface = resolve_bind_interface(node.iface)", 1, true))
assert(source:find("api.TMP_IFACE_PATH, resolve_bind_interface(node.outbound_node_iface))", 1, true))
assert(source:find("api.TMP_IFACE_PATH, resolve_bind_interface(node.iface))", 1, true))
local compile = loadstring or load
assert(compile(source), "generated util_xray.lua is invalid")

if source ~= original then
  local out = assert(io.open(path .. ".tmp", "w"))
  out:write(source)
  out:close()
  print("changed")
else
  print("unchanged")
end
EOF
  )"

  if [ "${patch_state}" = "changed" ]; then
    backup_file "${PASSWALL_XRAY_LUA}"
    mv "${PASSWALL_XRAY_LUA}.tmp" "${PASSWALL_XRAY_LUA}"
    cp "${PASSWALL_XRAY_LUA}" "${PASSWALL_XRAY_LUA}.last-applied"
    CHANGED=1
    log "patched ${PASSWALL_XRAY_LUA}"
  else
    rm -f "${PASSWALL_XRAY_LUA}.tmp"
    log "${PASSWALL_XRAY_LUA} already patched"
  fi
}

commit_changes() {
  uci commit openvpn
  uci commit network
  uci commit "${PASSWALL_PACKAGE}"
}

restart_services() {
  [ "${RESTART_SERVICES}" = "1" ] || return 0

  log "restarting openvpn"
  /etc/init.d/openvpn restart

  log "restarting passwall2"
  /etc/init.d/passwall2 restart
}

main() {
  require_root
  require_cmd uci
  require_cmd lua
  require_cmd cp
  require_cmd mv

  ensure_openvpn_profile
  ensure_network_binding
  ensure_passwall_paths
  patch_passwall_xray_generator
  commit_changes
  restart_services

  if [ "${CHANGED}" = "1" ]; then
    log "completed successfully"
  else
    log "nothing changed"
  fi

  if [ "${RESTART_SERVICES}" != "1" ]; then
    log "restarts were skipped; set RESTART_SERVICES=1 to restart openvpn and passwall2 automatically"
  fi
}

main "$@"
