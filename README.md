# Passwall2 + OpenVPN Compatibility Fix

This project contains an idempotent OpenWrt shell script that re-applies the runtime fixes needed for Passwall2 to work correctly with an OpenVPN outbound interface.

It is designed for the exact issue we diagnosed on OpenWrt routers that use Passwall2 with an OpenVPN interface outbound:

- Passwall2 stores a logical OpenWrt interface name
- Xray and nftables need the real kernel device name
- after package updates, the patched Passwall2 generator can be overwritten

The script auto-detects the running OpenVPN instance first, then enabled LuCI/UCI profiles, then falls back to the first usable profile. It detects the config file, auth file path, live tunnel device, and the Passwall `_iface` logical interface names. After it finds the primary profile, it normalizes every OpenVPN profile it can find under LuCI/UCI and `/etc/openvpn/*.ovpn`, while preserving each profile's own auth and cipher model instead of forcing one fixed template.

## What It Changes

- Ensures the OpenVPN profile keeps:
  - `auth-user-pass /etc/openvpn/<profile>.auth` only when the profile already uses `auth-user-pass`
  - `askpass /etc/openvpn/<profile>.keypass` only when the private key is encrypted
  - `route-nopull`
  - `pull-filter ignore "redirect-gateway"`
  - `auth-nocache`
  - `data-ciphers` and `data-ciphers-fallback` derived from the profile's own existing `cipher` or `data-ciphers` settings
- Ensures OpenWrt has:
  - `network.<passwall-iface>.proto='none'`
  - `network.<passwall-iface>.device='<detected tun/tap device>'`
- Ensures Passwall2 uses:
  - `passwall2.@global_app[0].xray_file='/usr/bin/xray'`
- Patches `util_xray.lua` so Passwall2 resolves logical interface names to real device names before generating:
  - Xray `sockopt.interface`
  - Passwall iface marker files used by nftables

## What It Does Not Change

- Passwall2 routing rules
- shunt rules
- geosite/domain policy
- node selection
- a profile's original auth mode
- a profile's original cipher family unless compatibility metadata is missing or duplicated
- your OpenVPN server/certificate settings

## One-Line Install

For a fresh router or after a package update, SSH into the router and run this single command:

```sh
wget -O- https://raw.githubusercontent.com/Recoba86/openwrt-passwall-openvpn-fix/main/install.sh | sh
```

That command will:

- download the main fix script to `/root/passwall-openvpn-fix.sh`
- make it executable
- run it immediately
- restart `openvpn` and `passwall2` by default

If you want to apply the files without restarting services immediately:

```sh
RESTART_SERVICES=0 wget -O- https://raw.githubusercontent.com/Recoba86/openwrt-passwall-openvpn-fix/main/install.sh | sh
```

If you only want to preview what the installer would change:

```sh
wget -O- https://raw.githubusercontent.com/Recoba86/openwrt-passwall-openvpn-fix/main/install.sh | sh -s -- --dry-run
```

## Usage

Copy the script to the router and run it as `root`.

```sh
scp ./passwall-openvpn-fix.sh root@192.168.10.1:/root/
ssh root@192.168.10.1 'sh /root/passwall-openvpn-fix.sh'
```

By default, the script updates files and UCI config but does not restart services.

To restart OpenVPN and Passwall2 automatically after patching:

```sh
ssh root@192.168.10.1 'RESTART_SERVICES=1 sh /root/passwall-openvpn-fix.sh'
```

To preview changes without modifying files, UCI, or services:

```sh
ssh root@192.168.10.1 'sh /root/passwall-openvpn-fix.sh --dry-run'
```

If the tunnel is currently down and the router has no existing `network.<iface>.device` binding yet, dry-run will report that it cannot preview the final network rebinding until a live tunnel exists or `NETWORK_DEVICE` is provided explicitly.

## Customization

The script is meant to work without manual edits, but you can still override detection with environment variables when needed:

```sh
OPENVPN_SECTION=MyVPN \
OPENVPN_CONFIG=/etc/openvpn/MyVPN.ovpn \
OPENVPN_AUTH_FILE=/etc/openvpn/MyVPN.auth \
OPENVPN_USERPASS_FALLBACK=/etc/openvpn/MyVPN.userpass \
NETWORK_IFACE=my_openvpn_iface \
NETWORK_DEVICE=my_tunnel_device \
RESTART_SERVICES=1 \
sh ./passwall-openvpn-fix.sh
```

When the OpenVPN profile uses a generic `dev tun` or `dev tap`, the script now learns the real kernel device from the live router state instead of assuming a fixed device name. During the normal installer flow this happens automatically after OpenVPN restarts.

The normalization is profile-aware:

- profiles that already use `auth-user-pass` are rewritten to use an explicit per-profile auth file path
- profiles that do not use `auth-user-pass` are left certificate-only
- encrypted private keys get an `askpass` path, unencrypted keys do not
- legacy `cipher` settings are used to derive OpenVPN 2.5+ `data-ciphers` compatibility when needed
- duplicate or conflicting compatibility directives are collapsed to one canonical profile-specific value
- secret fallbacks are no longer copied from one profile into another

## Recommended Next Step

Store this script somewhere persistent on the router (for example `/root/passwall-openvpn-fix.sh`) and re-run it after:

- reinstalling Passwall2
- updating Passwall2
- flashing a fresh OpenWrt image
- restoring an OpenVPN profile on a fresh system
