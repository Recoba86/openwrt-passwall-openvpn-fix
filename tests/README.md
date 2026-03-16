# Test Fixtures

This folder contains non-secret OpenVPN profile fixtures used to exercise the profile-aware normalization logic.

The fixtures are intentionally dummy profiles:

- they use reserved example IP ranges
- embedded certificate and key blocks are placeholders
- they are not expected to establish a real tunnel

Coverage:

- `auth-user-pass-only.ovpn`
  - username/password profile
  - unencrypted private key
  - legacy `cipher` only
- `encrypted-key-with-auth.ovpn`
  - username/password profile
  - encrypted private key
  - legacy `cipher` only
- `certificate-only.ovpn`
  - certificate-only profile
  - no `auth-user-pass`
  - existing `data-ciphers` already present

Use the fixture audit script to validate that the fixture set still covers those intended cases:

```sh
sh ./tests/fixture-audit.sh
```
