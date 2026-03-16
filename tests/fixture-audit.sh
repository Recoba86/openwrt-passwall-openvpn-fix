#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

fail() {
  printf '[fixture-audit] ERROR: %s\n' "$*" >&2
  exit 1
}

check_contains() {
  file_path="$1"
  pattern="$2"
  if ! grep -Eq "${pattern}" "${file_path}"; then
    fail "${file_path} is missing pattern: ${pattern}"
  fi
}

check_absent() {
  file_path="$1"
  pattern="$2"
  if grep -Eq "${pattern}" "${file_path}"; then
    fail "${file_path} should not contain pattern: ${pattern}"
  fi
}

auth_only="${FIXTURES_DIR}/auth-user-pass-only.ovpn"
encrypted_auth="${FIXTURES_DIR}/encrypted-key-with-auth.ovpn"
cert_only="${FIXTURES_DIR}/certificate-only.ovpn"

for fixture in "${auth_only}" "${encrypted_auth}" "${cert_only}"; do
  [ -f "${fixture}" ] || fail "missing fixture: ${fixture}"
done

check_contains "${auth_only}" '^auth-user-pass$'
check_contains "${auth_only}" '^cipher AES-256-CBC$'
check_absent "${auth_only}" 'BEGIN ENCRYPTED PRIVATE KEY'
check_absent "${auth_only}" '^askpass($|[[:space:]])'

check_contains "${encrypted_auth}" '^auth-user-pass$'
check_contains "${encrypted_auth}" 'BEGIN ENCRYPTED PRIVATE KEY'
check_contains "${encrypted_auth}" '^cipher AES-128-CBC$'
check_absent "${encrypted_auth}" '^askpass($|[[:space:]])'

check_absent "${cert_only}" '^auth-user-pass($|[[:space:]])'
check_absent "${cert_only}" 'BEGIN ENCRYPTED PRIVATE KEY'
check_contains "${cert_only}" '^data-ciphers AES-256-CBC:AES-128-CBC$'
check_contains "${cert_only}" '^data-ciphers-fallback AES-256-CBC$'

printf '[fixture-audit] fixture set looks good\n'
