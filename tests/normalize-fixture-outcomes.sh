#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"
FIXER_SCRIPT="${REPO_DIR}/passwall-openvpn-fix.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

fail() {
  printf '[normalize-test] ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '[normalize-test] %s\n' "$*"
}

load_fixer_library() {
  lib_path="${TMP_DIR}/passwall-openvpn-fix.lib.sh"
  sed '/^main "\$@"$/d' "${FIXER_SCRIPT}" > "${lib_path}"
  # shellcheck disable=SC1090
  . "${lib_path}"
}

UCI_STATE="${TMP_DIR}/uci.state"
: > "${UCI_STATE}"

uci() {
  quiet=0
  if [ "${1:-}" = "-q" ]; then
    quiet=1
    shift
  fi

  cmd="${1:-}"
  shift || true

  case "${cmd}" in
    get)
      key="${1:-}"
      if value="$(awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, length($1) + 2); found=1; exit} END {if (!found) exit 1}' "${UCI_STATE}")"; then
        printf '%s\n' "${value}"
        return 0
      fi
      [ "${quiet}" = "1" ] || printf 'uci: entry not found: %s\n' "${key}" >&2
      return 1
      ;;
    set)
      key="${1%%=*}"
      value="${1#*=}"
      awk -F= -v wanted="${key}" '$1 != wanted {print $0}' "${UCI_STATE}" > "${UCI_STATE}.tmp"
      printf '%s=%s\n' "${key}" "${value}" >> "${UCI_STATE}.tmp"
      mv "${UCI_STATE}.tmp" "${UCI_STATE}"
      ;;
    commit|show)
      return 0
      ;;
    *)
      fail "unsupported mock uci command: ${cmd}"
      ;;
  esac
}

assert_contains() {
  file_path="$1"
  pattern="$2"
  if ! grep -Eq "${pattern}" "${file_path}"; then
    fail "${file_path} is missing pattern: ${pattern}"
  fi
}

assert_absent() {
  file_path="$1"
  pattern="$2"
  if grep -Eq "${pattern}" "${file_path}"; then
    fail "${file_path} should not contain pattern: ${pattern}"
  fi
}

assert_count() {
  file_path="$1"
  pattern="$2"
  expected="$3"
  actual="$(grep -Ec "${pattern}" "${file_path}" || true)"
  if [ "${actual}" != "${expected}" ]; then
    fail "${file_path} pattern ${pattern} expected count ${expected}, got ${actual}"
  fi
}

reset_case_state() {
  CHANGED=0
  BACKED_UP_FILES=""
  PROFILE_OPENVPN_SECTION=""
  PROFILE_OPENVPN_CONFIG=""
  PROFILE_OPENVPN_AUTH_FILE=""
  PROFILE_OPENVPN_USERPASS_FALLBACK=""
  PROFILE_OPENVPN_KEYPASS_FILE=""
  PROFILE_OPENVPN_KEYPASS_FALLBACK=""
  PRIMARY_OPENVPN_SECTION=""
  PRIMARY_OPENVPN_CONFIG=""
  PRIMARY_OPENVPN_AUTH_FILE=""
  PRIMARY_OPENVPN_USERPASS_FALLBACK=""
  PRIMARY_OPENVPN_KEYPASS_FILE=""
  DRY_RUN=0
}

prepare_case() {
  fixture_name="$1"
  section_name="$2"
  case_dir="${TMP_DIR}/${section_name}"
  mkdir -p "${case_dir}"
  cp "${FIXTURE_DIR}/${fixture_name}" "${case_dir}/${section_name}.ovpn"
  printf '%s\n' "${case_dir}/${section_name}.ovpn"
}

run_normalize() {
  section_name="$1"
  config_path="$2"
  reset_case_state
  PRIMARY_OPENVPN_SECTION="${section_name}"
  PRIMARY_OPENVPN_CONFIG="${config_path}"
  normalize_profile "${section_name}" "${config_path}"
}

test_auth_user_pass_only() {
  config_path="$(prepare_case auth-user-pass-only.ovpn auth_only)"
  run_normalize auth_only "${config_path}"

  assert_contains "${config_path}" '^auth-user-pass .*/auth_only\.auth$'
  assert_contains "${config_path}" '^route-nopull$'
  assert_contains "${config_path}" '^pull-filter ignore "redirect-gateway"$'
  assert_contains "${config_path}" '^auth-nocache$'
  assert_contains "${config_path}" '^data-ciphers AES-256-CBC$'
  assert_contains "${config_path}" '^data-ciphers-fallback AES-256-CBC$'
  assert_absent "${config_path}" '^askpass($|[[:space:]])'
  assert_count "${config_path}" '^auth-user-pass($|[[:space:]].*)' 1
  assert_count "${config_path}" '^data-ciphers[[:space:]]+' 1
  assert_count "${config_path}" '^data-ciphers-fallback[[:space:]]+' 1
  [ -f "${TMP_DIR}/auth_only/auth_only.auth" ] || fail "auth file was not created for auth_only"
}

test_encrypted_key_with_auth() {
  config_path="$(prepare_case encrypted-key-with-auth.ovpn encrypted_auth)"
  run_normalize encrypted_auth "${config_path}"

  assert_contains "${config_path}" '^auth-user-pass .*/encrypted_auth\.auth$'
  assert_contains "${config_path}" '^askpass .*/encrypted_auth\.keypass$'
  assert_contains "${config_path}" '^data-ciphers AES-128-CBC$'
  assert_contains "${config_path}" '^data-ciphers-fallback AES-128-CBC$'
  assert_count "${config_path}" '^askpass($|[[:space:]].*)' 1
  [ -f "${TMP_DIR}/encrypted_auth/encrypted_auth.auth" ] || fail "auth file was not created for encrypted_auth"
  [ -f "${TMP_DIR}/encrypted_auth/encrypted_auth.keypass" ] || fail "keypass file was not created for encrypted_auth"
}

test_certificate_only() {
  config_path="$(prepare_case certificate-only.ovpn cert_only)"
  run_normalize cert_only "${config_path}"

  assert_absent "${config_path}" '^auth-user-pass($|[[:space:]].*)'
  assert_absent "${config_path}" '^askpass($|[[:space:]].*)'
  assert_contains "${config_path}" '^data-ciphers AES-256-CBC:AES-128-CBC$'
  assert_contains "${config_path}" '^data-ciphers-fallback AES-256-CBC$'
  assert_contains "${config_path}" '^route-nopull$'
  assert_contains "${config_path}" '^pull-filter ignore "redirect-gateway"$'
  [ ! -e "${TMP_DIR}/cert_only/cert_only.auth" ] || fail "certificate-only profile should not create auth file"
}

test_conflicting_directives_cleanup() {
  config_path="$(prepare_case auth-user-pass-only.ovpn dirty_auth)"
  cat >> "${config_path}" <<'EOF'

route-nopull
pull-filter ignore "redirect-gateway"
data-ciphers AES-128-CBC
data-ciphers-fallback AES-128-CBC
EOF
  run_normalize dirty_auth "${config_path}"

  assert_contains "${config_path}" '^data-ciphers AES-256-CBC$'
  assert_contains "${config_path}" '^data-ciphers-fallback AES-256-CBC$'
  assert_count "${config_path}" '^route-nopull$' 1
  assert_count "${config_path}" '^pull-filter ignore "redirect-gateway"$' 1
  assert_count "${config_path}" '^data-ciphers[[:space:]]+' 1
  assert_count "${config_path}" '^data-ciphers-fallback[[:space:]]+' 1
}

load_fixer_library
test_auth_user_pass_only
note 'auth-user-pass-only fixture passed'
test_encrypted_key_with_auth
note 'encrypted-key-with-auth fixture passed'
test_certificate_only
note 'certificate-only fixture passed'
test_conflicting_directives_cleanup
note 'dirty profile cleanup fixture passed'
note 'all normalization outcome checks passed'
