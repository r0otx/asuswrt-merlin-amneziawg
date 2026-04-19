# Architecture

High-level overview. Detailed per-module specs live in `docs/superpowers/specs/`.

## Three-package split

| Package | Role | Arch |
|---|---|---|
| `amneziawg-go` | userspace VPN daemon (Go, static) | aarch64-3.10, armv7-3.2 |
| `amneziawg-tools` | CLI (awg, awg-quick) | same |
| `amneziawg-merlin-addon` | shell lib + WebUI + hooks | all |

## Runtime layout

```
/opt/sbin/
├── amneziawg-go            (daemon, ~4–5 MB)
├── awg                     (config CLI)
└── awg-quick               (lifecycle wrapper)

/opt/etc/amneziawg/
├── awg0.conf               (user-managed; not in any IPK)
├── awg0.conf.example       (ships with addon)
└── schema.json             (UI field validator)

/jffs/addons/amneziawg/
├── amneziawg.sh            (dispatcher)
├── lib/*.sh                (modular backend)
├── hooks/*.block           (demarcated-block templates)
├── webui/*.asp             (copied into /www/user/userN.asp at boot)
└── scripts/uninstall.sh    (manual fallback)

/jffs/scripts/              (Merlin user-scripts)
├── service-event           (contains demarcated AmneziaWG-Addon-v2 block)
├── firewall-start          (same)
├── wan-event               (same)
└── services-start          (same)
```

## Hook model

Addon logic is triggered from four Merlin hook scripts. Each one contains a
demarcated block that backgrounds (`&`) a call into `amneziawg.sh`, so Merlin's
synchronous hook pipeline never blocks on our slow code (e.g. `curl` to GitHub).

```
service-event    → amneziawg.sh service_event   (reacts to webui form posts)
firewall-start   → amneziawg.sh firewall_start  (reinstalls iptables rules)
wan-event        → amneziawg.sh wan_event       (restart tunnel on WAN flap)
services-start   → amneziawg.sh services_start  (mount WebUI, start watchdog)
```

## WebUI mount

Standard Merlin Addons API: `am_get_webui_page` allocates a `user*.asp` slot,
our script copies the page in and bind-mounts a patched `menuTree.js` over the
read-only squashfs original. Concurrent addon boots coordinate via `flock` on
`/tmp/addonwebui.lock` FD 386.

## State storage

- UI form state: keys with `awg_` prefix in `/jffs/addons/custom_settings.txt`
  (Merlin's central addon settings file). Accessed via `state.sh`, atomic
  tmp+mv writes.
- Tunnel config: plain `awg0.conf` in `/opt/etc/amneziawg/`. Not stored in
  NVRAM (NVRAM is size-constrained and wear-sensitive).
- Runtime state: ephemeral under `/tmp/amneziawg/` (logs, status JSON).

## Planned modules (beyond Module 1)

- **Module 2** — Tunnel lifecycle (`amneziawg-go` start/stop, `awg-quick up/down`).
- **Module 3** — PBR / iptables / ipset / fwmark / kill-switch / DNS leak.
- **Module 4** — WebUI logic rewrite (validation, AJAX, H1 range support).
- **Module 5** — GeoIP + v2fly lists, selective routing by category.
- **Module 6** — Observability (structured logs, health endpoint, metrics).
