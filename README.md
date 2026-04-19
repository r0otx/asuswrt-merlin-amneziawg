# AmneziaWG for Asuswrt-Merlin

**Status:** v2 — under construction. v1 available at tag `v1.1.6` / branch `legacy`.

AmneziaWG is a fork of WireGuard with anti-DPI obfuscation. This project packages
the userspace daemon (`amneziawg-go`) plus tools (`awg`, `awg-quick`) plus a
WebUI addon for Asuswrt-Merlin routers — installed via `opkg` from a personal
Entware feed.

## Quick install

```
curl -fsSL https://github.com/r0otx/asuswrt-merlin-amneziawg/raw/main/scripts/install-online.sh \
    | sh -s -- --add-feed
```

Then browse to `https://<router>` → `VPN → AmneziaWG`.

See [docs/INSTALL.md](docs/INSTALL.md) for all install paths and prerequisites.

## What's in the repo

- `/` — upstream `amneziawg-go` (Go daemon), hard-forked.
- `/tools/` — vendored `amneziawg-tools` C source (awg, awg-quick).
- `/addon/` — Merlin addon: shell libs, hooks, WebUI page.
- `/build/` — Docker cross-build + IPK packaging + CI helpers.
- `/scripts/install-online.sh` — router-side installer.
- `/docs/` — INSTALL, UNINSTALL, ARCHITECTURE, per-module specs under
  `docs/superpowers/`.

## Supported routers

AArch64 HND (most AX models): RT-AX88U, RT-AX86U/S/Pro, RT-AX58U, GT-AX11000,
GT-AXE11000, GT-AX6000, RT-AX68U, RT-AX82U, and similar.

ARMv7 HND (Merlin 386.12 EOL line): RT-AC86U, RT-AC88U, RT-AC5300, RT-AC3100,
RT-AC68U (GOARM=5 softfloat; beta — verify on your unit).

## License

MIT — see [LICENSE](LICENSE).

Upstream projects:
- amneziawg-go — https://github.com/amnezia-vpn/amneziawg-go (MIT)
- amneziawg-tools — https://github.com/amnezia-vpn/amneziawg-tools (GPL-2.0)
