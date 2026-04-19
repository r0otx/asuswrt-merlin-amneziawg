# Uninstalling AmneziaWG

## Standard (preserves user state)

```
opkg remove amneziawg-merlin-addon amneziawg-tools amneziawg-go
```

This removes the binaries and the `/jffs/addons/amneziawg/` payload but
**preserves**:
- `/opt/etc/amneziawg/awg0.conf` (your tunnel config)
- `awg_*` keys in `/jffs/addons/custom_settings.txt` (UI settings)

## Full purge (also removes user state)

```
curl -fsSL https://github.com/r0otx/asuswrt-merlin-amneziawg/raw/main/scripts/install-online.sh \
    | sh -s -- --purge
```

or manually:

```
opkg remove amneziawg-merlin-addon amneziawg-tools amneziawg-go
rm -rf /opt/etc/amneziawg /opt/var/log/amneziawg /jffs/addons/amneziawg
awk '/^awg_/ { next } { print }' /jffs/addons/custom_settings.txt \
     > /jffs/addons/custom_settings.txt.tmp \
  && mv /jffs/addons/custom_settings.txt.tmp /jffs/addons/custom_settings.txt
```

Reboot afterwards to free the WebUI user-slot and clear bind-mounts.

## Manual fallback (opkg broken)

```
/jffs/addons/amneziawg/scripts/uninstall.sh --purge
```

This runs the same teardown without opkg.
