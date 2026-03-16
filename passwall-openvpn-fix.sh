#!/bin/sh

set -eu

SCRIPT_NAME="${0##*/}"
LOG_PREFIX="[${SCRIPT_NAME}]"

OPENVPN_SECTION="${OPENVPN_SECTION:-}"
OPENVPN_CONFIG="${OPENVPN_CONFIG:-}"
OPENVPN_AUTH_FILE="${OPENVPN_AUTH_FILE:-}"
OPENVPN_USERPASS_FALLBACK="${OPENVPN_USERPASS_FALLBACK:-}"
NETWORK_IFACE="${NETWORK_IFACE:-}"
NETWORK_DEVICE="${NETWORK_DEVICE:-}"
PASSWALL_PACKAGE="${PASSWALL_PACKAGE:-passwall2}"
PASSWALL_XRAY_LUA="${PASSWALL_XRAY_LUA:-/usr/lib/lua/luci/passwall2/util_xray.lua}"
PASSWALL_XRAY_BIN="${PASSWALL_XRAY_BIN:-/usr/bin/xray}"
RESTART_SERVICES="${RESTART_SERVICES:-0}"
DRY_RUN="${DRY_RUN:-0}"

CHANGED=0
BACKED_UP_FILES=""
PASSWALL_IFACES=""
PRIMARY_OPENVPN_SECTION=""
PRIMARY_OPENVPN_CONFIG=""
PRIMARY_OPENVPN_AUTH_FILE=""
PRIMARY_OPENVPN_USERPASS_FALLBACK=""
PRIMARY_OPENVPN_KEYPASS_FILE=""
NETWORK_DEVICE_WAIT_SECONDS="${NETWORK_DEVICE_WAIT_SECONDS:-15}"

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

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        cat <<'EOF'
Usage: passwall-openvpn-fix.sh [--dry-run]

Options:
  --dry-run  Report what would change without modifying files, UCI, or services.
EOF
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
    shift
  done
}

mark_changed() {
  CHANGED=1
}

list_uci_sections() {
  package_name="$1"
  type_name="$2"
  uci show "${package_name}" 2>/dev/null | awk -F'[.=]' -v expected="${type_name}" '$3 == expected {print $2}'
}

append_unique_word() {
  current_list="$1"
  new_word="$2"
  [ -n "${new_word}" ] || {
    printf '%s\n' "${current_list}"
    return 0
  }
  case " ${current_list} " in
    *" ${new_word} "*) printf '%s\n' "${current_list}" ;;
    *) printf '%s %s\n' "${current_list}" "${new_word}" | awk '{$1=$1; print}' ;;
  esac
}

backup_file() {
  file_path="$1"
  [ -f "${file_path}" ] || return 0
  case " ${BACKED_UP_FILES} " in
    *" ${file_path} "*) return 0 ;;
  esac
  backup_path="${file_path}.bak.$(date +%Y%m%d%H%M%S)"
  if [ "${DRY_RUN}" = "1" ]; then
    mark_changed
    BACKED_UP_FILES="${BACKED_UP_FILES} ${file_path}"
    log "would create backup: ${backup_path}"
    return 0
  fi
  cp "${file_path}" "${backup_path}"
  BACKED_UP_FILES="${BACKED_UP_FILES} ${file_path}"
  log "backup created: ${backup_path}"
}

set_uci_value() {
  key="$1"
  expected="$2"
  current="$(uci -q get "${key}" 2>/dev/null || true)"
  if [ "${current}" != "${expected}" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would set ${key}='${expected}'"
      return 0
    fi
    uci set "${key}=${expected}"
    mark_changed
    log "set ${key}='${expected}'"
  fi
}

detect_openvpn_section() {
  [ -n "${PRIMARY_OPENVPN_SECTION}" ] && return 0
  [ -n "${OPENVPN_SECTION}" ] && PRIMARY_OPENVPN_SECTION="${OPENVPN_SECTION}"
  [ -n "${PRIMARY_OPENVPN_SECTION}" ] && return 0

  running_section="$(ps w 2>/dev/null | sed -n 's/.*openvpn(\([^)]*\)).*/\1/p' | head -n 1)"
  if [ -n "${running_section}" ]; then
    config_value="$(uci -q get "openvpn.${running_section}.config" 2>/dev/null || true)"
    if [ -n "${config_value}" ] && [ -f "${config_value}" ]; then
      PRIMARY_OPENVPN_SECTION="${running_section}"
      return 0
    fi
  fi

  for section_name in $(list_uci_sections openvpn openvpn); do
    enabled_value="$(uci -q get "openvpn.${section_name}.enabled" 2>/dev/null || echo 0)"
    config_value="$(uci -q get "openvpn.${section_name}.config" 2>/dev/null || true)"
    if [ "${enabled_value}" = "1" ] && [ -n "${config_value}" ] && [ -f "${config_value}" ]; then
      PRIMARY_OPENVPN_SECTION="${section_name}"
      return 0
    fi
  done

  for section_name in $(list_uci_sections openvpn openvpn); do
    config_value="$(uci -q get "openvpn.${section_name}.config" 2>/dev/null || true)"
    if [ -n "${config_value}" ] && [ -f "${config_value}" ]; then
      PRIMARY_OPENVPN_SECTION="${section_name}"
      return 0
    fi
  done

  if [ -n "${OPENVPN_CONFIG}" ] && [ -f "${OPENVPN_CONFIG}" ]; then
    PRIMARY_OPENVPN_SECTION="$(basename "${OPENVPN_CONFIG}" .ovpn)"
    return 0
  fi

  fail "could not detect an OpenVPN instance; set OPENVPN_SECTION or OPENVPN_CONFIG explicitly"
}

detect_openvpn_config() {
  [ -n "${PRIMARY_OPENVPN_CONFIG}" ] && return 0
  [ -n "${OPENVPN_CONFIG}" ] && PRIMARY_OPENVPN_CONFIG="${OPENVPN_CONFIG}"
  [ -n "${PRIMARY_OPENVPN_CONFIG}" ] && return 0

  config_value="$(uci -q get "openvpn.${PRIMARY_OPENVPN_SECTION}.config" 2>/dev/null || true)"
  if [ -n "${config_value}" ]; then
    PRIMARY_OPENVPN_CONFIG="${config_value}"
  else
    PRIMARY_OPENVPN_CONFIG="/etc/openvpn/${PRIMARY_OPENVPN_SECTION}.ovpn"
  fi
}

detect_openvpn_auth_source() {
  [ -n "${PRIMARY_OPENVPN_AUTH_FILE}" ] && return 0
  [ -n "${OPENVPN_AUTH_FILE}" ] && PRIMARY_OPENVPN_AUTH_FILE="${OPENVPN_AUTH_FILE}"
  [ -n "${PRIMARY_OPENVPN_AUTH_FILE}" ] && return 0

  auth_path="$(awk '/^auth-user-pass[[:space:]]+/ {print $2; exit}' "${PRIMARY_OPENVPN_CONFIG}" 2>/dev/null || true)"
  if [ -n "${auth_path}" ]; then
    PRIMARY_OPENVPN_AUTH_FILE="${auth_path}"
    return 0
  fi

  config_dir="$(dirname "${PRIMARY_OPENVPN_CONFIG}")"
  config_base="$(basename "${PRIMARY_OPENVPN_CONFIG}" .ovpn)"
  PRIMARY_OPENVPN_AUTH_FILE="${config_dir}/${config_base}.auth"
}

detect_openvpn_userpass_fallback() {
  [ -n "${PRIMARY_OPENVPN_USERPASS_FALLBACK}" ] && return 0
  [ -n "${OPENVPN_USERPASS_FALLBACK}" ] && PRIMARY_OPENVPN_USERPASS_FALLBACK="${OPENVPN_USERPASS_FALLBACK}"
  [ -n "${PRIMARY_OPENVPN_USERPASS_FALLBACK}" ] && return 0

  config_dir="$(dirname "${PRIMARY_OPENVPN_CONFIG}")"
  config_base="$(basename "${PRIMARY_OPENVPN_CONFIG}" .ovpn)"
  auth_dir="$(dirname "${PRIMARY_OPENVPN_AUTH_FILE}")"
  auth_base="$(basename "${PRIMARY_OPENVPN_AUTH_FILE}")"
  auth_stem="${auth_base%.*}"

  for candidate in \
    "${config_dir}/${config_base}.userpass" \
    "${auth_dir}/${auth_stem}.userpass" \
    "/etc/openvpn/${PRIMARY_OPENVPN_SECTION}.userpass"
  do
    if [ -f "${candidate}" ]; then
      PRIMARY_OPENVPN_USERPASS_FALLBACK="${candidate}"
      return 0
    fi
  done

  PRIMARY_OPENVPN_USERPASS_FALLBACK="${config_dir}/${config_base}.userpass"
}

get_openvpn_dev_hint() {
  dev_value="$(uci -q get "openvpn.${PRIMARY_OPENVPN_SECTION}.dev" 2>/dev/null || true)"
  if [ -n "${dev_value}" ]; then
    printf '%s\n' "${dev_value}"
    return 0
  fi

  awk '/^dev[[:space:]]+/ {print $2; exit}' "${PRIMARY_OPENVPN_CONFIG}" 2>/dev/null || true
}

probe_network_device() {
  preferred_device="$(get_openvpn_dev_hint)"

  if [ -n "${NETWORK_IFACE}" ]; then
    existing_device="$(uci -q get "network.${NETWORK_IFACE}.device" 2>/dev/null || true)"
    if [ -n "${existing_device}" ]; then
      printf '%s\n' "${existing_device}"
      return 0
    fi
  fi

  for iface_name in ${PASSWALL_IFACES}; do
    existing_device="$(uci -q get "network.${iface_name}.device" 2>/dev/null || true)"
    if [ -n "${existing_device}" ]; then
      printf '%s\n' "${existing_device}"
      return 0
    fi
  done

  if [ -n "${preferred_device}" ] && [ "${preferred_device}" != "tun" ] && [ "${preferred_device}" != "tap" ]; then
    if ip -o link show "${preferred_device}" >/dev/null 2>&1; then
      printf '%s\n' "${preferred_device}"
      return 0
    fi
  fi

  active_device="$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(tun|tap)[0-9]+$/ {print $2; exit}')"
  if [ -n "${active_device}" ]; then
    printf '%s\n' "${active_device}"
    return 0
  fi

  if [ -n "${preferred_device}" ] && [ "${preferred_device}" != "tun" ] && [ "${preferred_device}" != "tap" ]; then
    printf '%s\n' "${preferred_device}"
    return 0
  fi
}

detect_network_device() {
  [ -n "${NETWORK_DEVICE}" ] && return 0

  detected_device="$(probe_network_device)"
  if [ -n "${detected_device}" ]; then
    NETWORK_DEVICE="${detected_device}"
    return 0
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log "could not detect the OpenVPN tunnel device in dry-run mode; a live tunnel or explicit NETWORK_DEVICE is required to preview network rebinding"
    return 0
  fi

  fail "could not detect the OpenVPN tunnel device automatically; bring the tunnel up once or set NETWORK_DEVICE explicitly"
}

wait_for_network_device() {
  [ -n "${NETWORK_DEVICE}" ] && return 0

  remaining_seconds="${NETWORK_DEVICE_WAIT_SECONDS}"
  while [ "${remaining_seconds}" -gt 0 ]; do
    detected_device="$(probe_network_device)"
    if [ -n "${detected_device}" ]; then
      NETWORK_DEVICE="${detected_device}"
      log "detected tunnel device after restart: ${NETWORK_DEVICE}"
      return 0
    fi
    sleep 1
    remaining_seconds=$((remaining_seconds - 1))
  done
}

detect_passwall_ifaces() {
  PASSWALL_IFACES=""
  for node_id in $(list_uci_sections "${PASSWALL_PACKAGE}" nodes); do
    protocol_value="$(uci -q get "${PASSWALL_PACKAGE}.${node_id}.protocol" 2>/dev/null || true)"
    iface_value="$(uci -q get "${PASSWALL_PACKAGE}.${node_id}.iface" 2>/dev/null || true)"
    if [ "${protocol_value}" = "_iface" ] && [ -n "${iface_value}" ]; then
      PASSWALL_IFACES="$(append_unique_word "${PASSWALL_IFACES}" "${iface_value}")"
    fi
  done
}

detect_network_iface() {
  if [ -n "${NETWORK_IFACE}" ]; then
    PASSWALL_IFACES="$(append_unique_word "${PASSWALL_IFACES}" "${NETWORK_IFACE}")"
    return 0
  fi

  if [ -n "${PASSWALL_IFACES}" ]; then
    NETWORK_IFACE="$(printf '%s\n' "${PASSWALL_IFACES}" | awk '{print $1}')"
    return 0
  fi

  for iface_name in $(list_uci_sections network interface); do
    device_value="$(uci -q get "network.${iface_name}.device" 2>/dev/null || true)"
    if [ -n "${NETWORK_DEVICE}" ] && [ "${device_value}" = "${NETWORK_DEVICE}" ]; then
      NETWORK_IFACE="${iface_name}"
      PASSWALL_IFACES="$(append_unique_word "${PASSWALL_IFACES}" "${iface_name}")"
      return 0
    fi
  done

  NETWORK_IFACE="${PRIMARY_OPENVPN_SECTION}"
  PASSWALL_IFACES="$(append_unique_word "${PASSWALL_IFACES}" "${NETWORK_IFACE}")"
}

resolve_context() {
  detect_openvpn_section
  detect_openvpn_config
  [ -f "${PRIMARY_OPENVPN_CONFIG}" ] || fail "OpenVPN config not found: ${PRIMARY_OPENVPN_CONFIG}"
  detect_openvpn_auth_source
  detect_openvpn_userpass_fallback
  detect_passwall_ifaces
  NETWORK_DEVICE="$(probe_network_device)"
  detect_network_iface

  log "detected OpenVPN section: ${PRIMARY_OPENVPN_SECTION}"
  log "detected OpenVPN config: ${PRIMARY_OPENVPN_CONFIG}"
  log "detected auth file: ${PRIMARY_OPENVPN_AUTH_FILE}"
  if [ -n "${NETWORK_DEVICE}" ]; then
    log "detected tunnel device: ${NETWORK_DEVICE}"
  else
    log "tunnel device not detected yet; it will be resolved from the live tunnel or existing network binding"
  fi
  log "detected network iface(s): ${PASSWALL_IFACES}"
}

ensure_openvpn_line() {
  line="$1"
  grep -Fqx "${line}" "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null && return 0
  if [ "${DRY_RUN}" = "1" ]; then
    mark_changed
    log "would add to ${PROFILE_OPENVPN_CONFIG}: ${line}"
    return 0
  fi
  printf '\n%s\n' "${line}" >> "${PROFILE_OPENVPN_CONFIG}"
  mark_changed
  log "added to ${PROFILE_OPENVPN_CONFIG}: ${line}"
}

ensure_openvpn_auth_source() {
  if [ ! -e "${PROFILE_OPENVPN_AUTH_FILE}" ]; then
    if [ -s "${PROFILE_OPENVPN_USERPASS_FALLBACK}" ]; then
      if [ "${DRY_RUN}" = "1" ]; then
        mark_changed
        log "would create ${PROFILE_OPENVPN_AUTH_FILE} from ${PROFILE_OPENVPN_USERPASS_FALLBACK}"
      else
        cp "${PROFILE_OPENVPN_USERPASS_FALLBACK}" "${PROFILE_OPENVPN_AUTH_FILE}"
        chmod 600 "${PROFILE_OPENVPN_AUTH_FILE}"
        mark_changed
        log "created ${PROFILE_OPENVPN_AUTH_FILE} from ${PROFILE_OPENVPN_USERPASS_FALLBACK}"
      fi
    else
      if [ "${DRY_RUN}" = "1" ]; then
        mark_changed
        log "would create empty auth file ${PROFILE_OPENVPN_AUTH_FILE}"
      else
        : > "${PROFILE_OPENVPN_AUTH_FILE}"
        chmod 600 "${PROFILE_OPENVPN_AUTH_FILE}"
        mark_changed
        log "created empty auth file ${PROFILE_OPENVPN_AUTH_FILE}"
      fi
    fi
  fi

  if grep -q '^auth-user-pass ' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    if ! grep -q "^auth-user-pass ${PROFILE_OPENVPN_AUTH_FILE}\$" "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
      backup_file "${PROFILE_OPENVPN_CONFIG}"
      if [ "${DRY_RUN}" = "1" ]; then
        mark_changed
        log "would set auth-user-pass source to ${PROFILE_OPENVPN_AUTH_FILE}"
      else
        sed -i "s#^auth-user-pass .*#auth-user-pass ${PROFILE_OPENVPN_AUTH_FILE}#" "${PROFILE_OPENVPN_CONFIG}"
        mark_changed
        log "set auth-user-pass source to ${PROFILE_OPENVPN_AUTH_FILE}"
      fi
    fi
  elif grep -q '^auth-user-pass$' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would set auth-user-pass source to ${PROFILE_OPENVPN_AUTH_FILE}"
    else
      sed -i "s#^auth-user-pass\$#auth-user-pass ${PROFILE_OPENVPN_AUTH_FILE}#" "${PROFILE_OPENVPN_CONFIG}"
      mark_changed
      log "set auth-user-pass source to ${PROFILE_OPENVPN_AUTH_FILE}"
    fi
  else
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would add auth-user-pass source ${PROFILE_OPENVPN_AUTH_FILE}"
    else
      printf '\nauth-user-pass %s\n' "${PROFILE_OPENVPN_AUTH_FILE}" >> "${PROFILE_OPENVPN_CONFIG}"
      mark_changed
      log "added auth-user-pass source ${PROFILE_OPENVPN_AUTH_FILE}"
    fi
  fi
}

ensure_openvpn_keypass_source() {
  if ! grep -q 'BEGIN ENCRYPTED PRIVATE KEY' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    return 0
  fi

  if [ ! -e "${PROFILE_OPENVPN_KEYPASS_FILE}" ] && [ -s "${PROFILE_OPENVPN_KEYPASS_FALLBACK}" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would create ${PROFILE_OPENVPN_KEYPASS_FILE} from ${PROFILE_OPENVPN_KEYPASS_FALLBACK}"
    else
      cp "${PROFILE_OPENVPN_KEYPASS_FALLBACK}" "${PROFILE_OPENVPN_KEYPASS_FILE}"
      chmod 600 "${PROFILE_OPENVPN_KEYPASS_FILE}"
      mark_changed
      log "created ${PROFILE_OPENVPN_KEYPASS_FILE} from ${PROFILE_OPENVPN_KEYPASS_FALLBACK}"
    fi
  fi

  if [ ! -e "${PROFILE_OPENVPN_KEYPASS_FILE}" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would create empty keypass file ${PROFILE_OPENVPN_KEYPASS_FILE}"
    else
      : > "${PROFILE_OPENVPN_KEYPASS_FILE}"
      chmod 600 "${PROFILE_OPENVPN_KEYPASS_FILE}"
      mark_changed
      log "created empty keypass file ${PROFILE_OPENVPN_KEYPASS_FILE}"
    fi
  fi

  if grep -q '^askpass ' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    if ! grep -q "^askpass ${PROFILE_OPENVPN_KEYPASS_FILE}\$" "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
      backup_file "${PROFILE_OPENVPN_CONFIG}"
      if [ "${DRY_RUN}" = "1" ]; then
        mark_changed
        log "would set askpass source to ${PROFILE_OPENVPN_KEYPASS_FILE}"
      else
        sed -i "s#^askpass .*#askpass ${PROFILE_OPENVPN_KEYPASS_FILE}#" "${PROFILE_OPENVPN_CONFIG}"
        mark_changed
        log "set askpass source to ${PROFILE_OPENVPN_KEYPASS_FILE}"
      fi
    fi
  elif grep -q '^askpass$' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would set askpass source to ${PROFILE_OPENVPN_KEYPASS_FILE}"
    else
      sed -i "s#^askpass\$#askpass ${PROFILE_OPENVPN_KEYPASS_FILE}#" "${PROFILE_OPENVPN_CONFIG}"
      mark_changed
      log "set askpass source to ${PROFILE_OPENVPN_KEYPASS_FILE}"
    fi
  else
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would add askpass source ${PROFILE_OPENVPN_KEYPASS_FILE}"
    else
      printf '\naskpass %s\n' "${PROFILE_OPENVPN_KEYPASS_FILE}" >> "${PROFILE_OPENVPN_CONFIG}"
      mark_changed
      log "added askpass source ${PROFILE_OPENVPN_KEYPASS_FILE}"
    fi
  fi
}

ensure_openvpn_profile() {
  ensure_openvpn_auth_source
  ensure_openvpn_keypass_source
  if ! grep -Fqx 'route-nopull' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null || \
     ! grep -Fqx 'pull-filter ignore "redirect-gateway"' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null || \
     ! grep -Fqx 'auth-nocache' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    ensure_openvpn_line 'route-nopull'
    ensure_openvpn_line 'pull-filter ignore "redirect-gateway"'
    ensure_openvpn_line 'auth-nocache'
  fi

  if ! grep -q '^data-ciphers ' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    ensure_openvpn_line 'data-ciphers AES-128-CBC'
  fi

  if ! grep -q '^data-ciphers-fallback ' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null; then
    backup_file "${PROFILE_OPENVPN_CONFIG}"
    ensure_openvpn_line 'data-ciphers-fallback AES-128-CBC'
  fi

  if ! uci -q get "openvpn.${PROFILE_OPENVPN_SECTION}" >/dev/null 2>&1; then
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would create openvpn section: ${PROFILE_OPENVPN_SECTION}"
    else
      uci set "openvpn.${PROFILE_OPENVPN_SECTION}=openvpn"
      mark_changed
      log "created openvpn section: ${PROFILE_OPENVPN_SECTION}"
    fi
  fi

  set_uci_value "openvpn.${PROFILE_OPENVPN_SECTION}.config" "${PROFILE_OPENVPN_CONFIG}"
}

normalize_profile() {
  PROFILE_OPENVPN_SECTION="$1"
  PROFILE_OPENVPN_CONFIG="$2"
  [ -f "${PROFILE_OPENVPN_CONFIG}" ] || return 0

  profile_dir="$(dirname "${PROFILE_OPENVPN_CONFIG}")"
  profile_base="$(basename "${PROFILE_OPENVPN_CONFIG}" .ovpn)"
  PROFILE_OPENVPN_AUTH_FILE="$(awk '/^auth-user-pass[[:space:]]+/ {print $2; exit}' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null || true)"
  [ -n "${PROFILE_OPENVPN_AUTH_FILE}" ] || PROFILE_OPENVPN_AUTH_FILE="${profile_dir}/${profile_base}.auth"
  PROFILE_OPENVPN_USERPASS_FALLBACK="${profile_dir}/${profile_base}.userpass"
  [ -e "${PROFILE_OPENVPN_USERPASS_FALLBACK}" ] || PROFILE_OPENVPN_USERPASS_FALLBACK="$(dirname "${PROFILE_OPENVPN_AUTH_FILE}")/$(basename "${PROFILE_OPENVPN_AUTH_FILE}" .auth).userpass"
  PROFILE_OPENVPN_KEYPASS_FILE="$(awk '/^askpass[[:space:]]+/ {print $2; exit}' "${PROFILE_OPENVPN_CONFIG}" 2>/dev/null || true)"
  [ -n "${PROFILE_OPENVPN_KEYPASS_FILE}" ] || PROFILE_OPENVPN_KEYPASS_FILE="${profile_dir}/${profile_base}.keypass"
  PROFILE_OPENVPN_KEYPASS_FALLBACK="${profile_dir}/${profile_base}.keypass"

  if [ "${PROFILE_OPENVPN_SECTION}" = "${PRIMARY_OPENVPN_SECTION}" ]; then
    [ -n "${PRIMARY_OPENVPN_AUTH_FILE}" ] && PROFILE_OPENVPN_AUTH_FILE="${PRIMARY_OPENVPN_AUTH_FILE}"
    [ -n "${PRIMARY_OPENVPN_USERPASS_FALLBACK}" ] && PROFILE_OPENVPN_USERPASS_FALLBACK="${PRIMARY_OPENVPN_USERPASS_FALLBACK}"
  elif [ ! -e "${PROFILE_OPENVPN_AUTH_FILE}" ] && [ -s "${PRIMARY_OPENVPN_AUTH_FILE}" ]; then
    PROFILE_OPENVPN_USERPASS_FALLBACK="${PRIMARY_OPENVPN_AUTH_FILE}"
  fi

  if [ "${PROFILE_OPENVPN_SECTION}" = "${PRIMARY_OPENVPN_SECTION}" ]; then
    primary_keypass_candidate="$(awk '/^askpass[[:space:]]+/ {print $2; exit}' "${PRIMARY_OPENVPN_CONFIG}" 2>/dev/null || true)"
    [ -n "${primary_keypass_candidate}" ] && PRIMARY_OPENVPN_KEYPASS_FILE="${primary_keypass_candidate}"
    if [ -z "${PRIMARY_OPENVPN_KEYPASS_FILE:-}" ]; then
      PRIMARY_OPENVPN_KEYPASS_FILE="$(dirname "${PRIMARY_OPENVPN_CONFIG}")/$(basename "${PRIMARY_OPENVPN_CONFIG}" .ovpn).keypass"
    fi
    PROFILE_OPENVPN_KEYPASS_FALLBACK="${PRIMARY_OPENVPN_KEYPASS_FILE}"
  elif [ ! -e "${PROFILE_OPENVPN_KEYPASS_FILE}" ] && [ -s "${PRIMARY_OPENVPN_KEYPASS_FILE:-}" ]; then
    PROFILE_OPENVPN_KEYPASS_FALLBACK="${PRIMARY_OPENVPN_KEYPASS_FILE}"
  fi

  log "normalizing profile ${PROFILE_OPENVPN_SECTION} (${PROFILE_OPENVPN_CONFIG})"
  ensure_openvpn_profile
}

normalize_all_profiles() {
  processed_configs=""

  if [ -n "${PRIMARY_OPENVPN_SECTION}" ] && [ -n "${PRIMARY_OPENVPN_CONFIG}" ]; then
    normalize_profile "${PRIMARY_OPENVPN_SECTION}" "${PRIMARY_OPENVPN_CONFIG}"
    processed_configs="$(append_unique_word "${processed_configs}" "${PRIMARY_OPENVPN_CONFIG}")"
  fi

  for section_name in $(list_uci_sections openvpn openvpn); do
    config_value="$(uci -q get "openvpn.${section_name}.config" 2>/dev/null || true)"
    [ -n "${config_value}" ] || continue
    [ -f "${config_value}" ] || continue
    case " ${processed_configs} " in
      *" ${config_value} "*) continue ;;
    esac
    normalize_profile "${section_name}" "${config_value}"
    processed_configs="$(append_unique_word "${processed_configs}" "${config_value}")"
  done

  for config_path in /etc/openvpn/*.ovpn; do
    [ -f "${config_path}" ] || continue
    case " ${processed_configs} " in
      *" ${config_path} "*) continue ;;
    esac
    normalize_profile "$(basename "${config_path}" .ovpn)" "${config_path}"
    processed_configs="$(append_unique_word "${processed_configs}" "${config_path}")"
  done
}

ensure_network_binding() {
  if [ -z "${NETWORK_DEVICE}" ]; then
    log "skipping network device binding because no tunnel device could be resolved"
    return 0
  fi

  for iface_name in ${PASSWALL_IFACES}; do
    if ! uci -q get "network.${iface_name}" >/dev/null 2>&1; then
      if [ "${DRY_RUN}" = "1" ]; then
        mark_changed
        log "would create network interface section: ${iface_name}"
      else
        uci set "network.${iface_name}=interface"
        mark_changed
        log "created network interface section: ${iface_name}"
      fi
    fi

    set_uci_value "network.${iface_name}.proto" "none"
    set_uci_value "network.${iface_name}.device" "${NETWORK_DEVICE}"
  done
}

ensure_passwall_paths() {
  uci -q get "${PASSWALL_PACKAGE}.@global_app[0]" >/dev/null 2>&1 || fail "missing ${PASSWALL_PACKAGE}.@global_app[0]"
  [ -x "${PASSWALL_XRAY_BIN}" ] || fail "xray binary not found: ${PASSWALL_XRAY_BIN}"
  set_uci_value "${PASSWALL_PACKAGE}.@global_app[0].xray_file" "${PASSWALL_XRAY_BIN}"
}

patch_passwall_xray_generator() {
  [ -f "${PASSWALL_XRAY_LUA}" ] || fail "Passwall xray generator not found: ${PASSWALL_XRAY_LUA}"
  patch_state="$(
    lua - "${PASSWALL_XRAY_LUA}" "${DRY_RUN}" <<'EOF'
local path = arg[1]
local dry_run = arg[2] == "1"
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
  if not dry_run then
    local out = assert(io.open(path .. ".tmp", "w"))
    out:write(source)
    out:close()
  end
  print("changed")
else
  print("unchanged")
end
EOF
  )"

  if [ "${patch_state}" = "changed" ]; then
    backup_file "${PASSWALL_XRAY_LUA}"
    if [ "${DRY_RUN}" = "1" ]; then
      mark_changed
      log "would patch ${PASSWALL_XRAY_LUA}"
    else
      mv "${PASSWALL_XRAY_LUA}.tmp" "${PASSWALL_XRAY_LUA}"
      cp "${PASSWALL_XRAY_LUA}" "${PASSWALL_XRAY_LUA}.last-applied"
      mark_changed
      log "patched ${PASSWALL_XRAY_LUA}"
    fi
  else
    [ "${DRY_RUN}" = "1" ] || rm -f "${PASSWALL_XRAY_LUA}.tmp"
    log "${PASSWALL_XRAY_LUA} already patched"
  fi
}

commit_openvpn_and_passwall() {
  if [ "${DRY_RUN}" = "1" ]; then
    log "would commit UCI changes: openvpn, ${PASSWALL_PACKAGE}"
    return 0
  fi
  uci commit openvpn
  uci commit "${PASSWALL_PACKAGE}"
}

commit_network() {
  if [ "${DRY_RUN}" = "1" ]; then
    log "would commit UCI changes: network"
    return 0
  fi
  uci commit network
}

restart_openvpn() {
  [ "${RESTART_SERVICES}" = "1" ] || return 0
  if [ "${DRY_RUN}" = "1" ]; then
    log "would restart openvpn"
    return 0
  fi

  log "restarting openvpn"
  /etc/init.d/openvpn restart
  wait_for_network_device
}

restart_passwall() {
  [ "${RESTART_SERVICES}" = "1" ] || return 0
  if [ "${DRY_RUN}" = "1" ]; then
    log "would restart passwall2"
    return 0
  fi

  log "restarting passwall2"
  /etc/init.d/passwall2 restart
}

main() {
  parse_args "$@"
  require_root
  require_cmd uci
  require_cmd lua
  require_cmd cp
  require_cmd mv

  resolve_context
  normalize_all_profiles
  ensure_passwall_paths
  patch_passwall_xray_generator
  commit_openvpn_and_passwall
  restart_openvpn
  detect_network_device
  ensure_network_binding
  commit_network
  restart_passwall

  if [ "${CHANGED}" = "1" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      log "dry-run completed; changes were not applied"
    else
      log "completed successfully"
    fi
  else
    if [ "${DRY_RUN}" = "1" ]; then
      log "dry-run completed; nothing would change"
    else
      log "nothing changed"
    fi
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log "dry-run mode skipped file writes, UCI commits, and service restarts"
  elif [ "${RESTART_SERVICES}" != "1" ]; then
    log "restarts were skipped; set RESTART_SERVICES=1 to restart openvpn and passwall2 automatically"
  fi
}

main "$@"
