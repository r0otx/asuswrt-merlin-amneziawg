# Installing AmneziaWG on Asuswrt-Merlin

Three supported paths; pick whichever fits your workflow.

## Prerequisites

- Asuswrt-Merlin 386.12 (EOL) or 388.7+ or 3006.102.5+.
- Entware installed (via `amtm ep`).
- JFFS enabled (`Administration → System`).
- `am_addons` in `nvram get rc_support` output.
- USB storage for Entware (SSH: `opkg install jq curl iptables ipset conntrack-tools`).

## Path 1: Online installer (recommended)

SSH into the router and run:

```
curl -fsSL https://github.com/r0otx/asuswrt-merlin-amneziawg/raw/main/scripts/install-online.sh \
    | sh -s -- --add-feed
```

Flags:
- `--yes` — non-interactive (auto-confirm v1 migration prompt).
- `--no-migrate` — skip v1 detection.
- `--version X.Y.Z` — install specific version instead of latest.
- `--channel stable|rc|beta` — release channel.

All downloads are SHA256-verified. Run `sha256sum` + manual install if paranoid.

## Path 2: opkg feed subscription

After one-time feed setup, `opkg upgrade` handles future versions.

```
echo 'src/gz amneziawg-stable https://r0otx.github.io/asuswrt-merlin-amneziawg/stable/aarch64-k3.10' \
  >> /opt/etc/opkg.conf
opkg update
opkg install amneziawg-merlin-addon
```

Replace `aarch64-k3.10` with `armv7sf-k2.6` on ARMv7 routers (RT-AC86U and similar).

## Path 3: Manual from GitHub Releases

1. Download the three `.ipk` from https://github.com/r0otx/asuswrt-merlin-amneziawg/releases
   matching your arch.
2. Download `SHA256SUMS` and verify: `sha256sum -c SHA256SUMS`.
3. Install in dep order:
   ```
   opkg install amneziawg-go_X.Y.Z-1_<arch>.ipk \
                amneziawg-tools_X.Y.Z-1_<arch>.ipk \
                amneziawg-merlin-addon_X.Y.Z-1_all.ipk
   ```
4. Open `https://<router>` → `VPN → AmneziaWG`.

## Troubleshooting

- `ERROR: Entware not installed` — run `amtm` → install Entware first.
- `ERROR: addon support not detected` — upgrade Merlin to 386.12+ or enable JFFS scripts.
- After install, no menu entry — reboot once; menuTree is remounted at each `services-start`.
