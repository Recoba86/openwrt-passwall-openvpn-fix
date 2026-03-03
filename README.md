# Passwall2 + OpenVPN Compatibility Fix

This project contains an idempotent OpenWrt shell script that re-applies the runtime fixes needed for Passwall2 to work correctly with an OpenVPN outbound interface.

It is designed for the exact issue we diagnosed on your router:

- Passwall2 stores the logical OpenWrt interface name (`ovpn0`)
- Xray and nftables need the real kernel device name (`tun0`)
- after package updates, the patched Passwall2 generator can be overwritten

The script re-applies the known-good fixes without changing your routing logic, shunt logic, domain policy, or outbound selection.

## What It Changes

- Ensures the OpenVPN profile keeps:
  - `route-nopull`
  - `pull-filter ignore "redirect-gateway"`
  - `auth-nocache`
- Ensures OpenWrt has:
  - `network.ovpn0.proto='none'`
  - `network.ovpn0.device='tun0'`
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

## Customization

If your OpenVPN profile name or interface names differ, override them with environment variables:

```sh
OPENVPN_SECTION=MyVPN \
OPENVPN_CONFIG=/etc/openvpn/MyVPN.ovpn \
NETWORK_IFACE=ovpn0 \
NETWORK_DEVICE=tun0 \
RESTART_SERVICES=1 \
sh ./passwall-openvpn-fix.sh
```

## Recommended Next Step

Store this script somewhere persistent on the router (for example `/root/passwall-openvpn-fix.sh`) and re-run it after:

- reinstalling Passwall2
- updating Passwall2
- flashing a fresh OpenWrt image
- restoring an OpenVPN profile on a fresh system
