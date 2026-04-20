# Module 3 — Policy-Based Routing, Firewall, Kill-switch, DNS Leak Protection · Design Spec

**Status:** Draft for user review
**Date:** 2026-04-20
**Project:** AmneziaGo (v2 of `asuswrt-merlin-amneziawg`)
**Depends on:** Module 1 (build/packaging), Module 2 (tunnel lifecycle).
**Repo branch:** `main`, HEAD `7f5883d` (M2 complete).
**Working directory:** `/Users/r00t/Desktop/AmneziaGo/`

## 1. Scope

Module 3 fills in the **firewall**, **policy-based routing**, **kill-switch**,
and **DNS leak protection** — everything needed for the `awg0` interface M2
creates to actually route the right traffic through it.

End-state after M3: user can mark devices as `vpn_all` / `vpn_geo` / `direct`,
kill-switch strict-drops VPN traffic when tunnel goes down, DNS cannot leak
to the ISP, IPv6 is gated by `AllowedIPs`, and a WAN flap does not rupture
live connections.

M3 does NOT introduce WebUI for PBR (that is M4), GeoIP auto-population
(M5), or observability/metrics (M6). Editing happens through CLI subcommands
on `amneziawg.sh` or by hand in `custom_settings.txt`.

## 2. Decisions (from brainstorming, locked in)

| # | Topic | Choice |
|---|---|---|
| 1 | Policy model | Per-device, 3 policies (`vpn_all`, `vpn_geo`, `direct`) + `default_policy`. Source-IP based. `ipset awg_geo_dst` empty in M3 (M5 populates). |
| 2 | Kill-switch | Strict DROP by default with UI-toggle `awg_killswitch_strict`. Watchdog arms on `tunnel_is_up=false`, disarms on `=true`. |
| 3 | IPv6 | Gated by `AllowedIPs`: contains `::/0` → awg-quick tunnels; else `ip6tables -I FORWARD -j DROP`. Override via `awg_ipv6_allow_bypass=1`. |
| 4 | DNS hijack | DNAT port 53 UDP/TCP for VPN devices to router's dnsmasq; REJECT port 853 (DoT); optional user-editable DoH blocklist (`awg_doh_blocklist`), empty by default. |
| 5 | Rule application | `iptables-restore --noflush` batch, `ipset restore` batch. Cuts apply latency from tens of seconds to <100ms at M3 scale. |
| 6 | firewall-start reaction | `pbr_reapply_incremental`: hash desired rules, compare to previous, diff-apply only when changed. Prevents v1-style connection disruption on WAN flap. |
| 7 | Custom chains | `AMNEZIAWG` (mangle PREROUTING), `AMNEZIAWG_DNS` (nat PREROUTING), `AMNEZIAWG_KILL` (filter FORWARD). Teardown = flush + delete chains. |
| 8 | MAC→IP resolution | On each `pbr_apply`: try `/var/lib/misc/dnsmasq.leases` first, then `ip neigh show`, fall back to stored IP. Fixes v1 bug where static IP break on DHCP renew. |
| 9 | fwmark / table | `0x100/0xFF00` / table `300`. Matches v1; does not collide with Merlin's native `0x7000` range. |

## 3. File structure

### 3.1 Modified lib files

| File | M2 state | After M3 |
|---|---|---|
| `addon/lib/pbr.sh` | stubs | Real: CRUD policies, MAC→IP resolve, apply, kill-switch arm/disarm, geo ipset management |
| `addon/lib/firewall.sh` | stubs | Real: custom chains, init/teardown, IPv6 gate, batch apply |
| `addon/lib/postup.sh` | stub | Calls `firewall_setup && pbr_setup` |
| `addon/lib/postdown.sh` | stub | Calls `pbr_teardown && firewall_teardown` |
| `addon/lib/events.sh` | `event_firewall` = stub | `event_firewall` → `pbr_reapply_incremental` |
| `addon/lib/watchdog.sh` | tracks `tunnel_is_up` | + `pbr_kill_switch_arm/disarm` on state change |
| `addon/lib/config.sh` | validates tunnel fields | + validates new schema keys (`awg_default_policy`, `awg_killswitch_strict`, `awg_ipv6_allow_bypass`, `awg_doh_blocklist`, `awg_geo_entries`, `awg_dev_*`) |
| `addon/amneziawg.sh` | M2 verbs | + `pbr list / set / remove / default / apply / geo-add / geo-remove` |

### 3.2 New lib files

| File | Responsibility |
|---|---|
| `addon/lib/dns.sh` | DNS hijack DNAT, DoT REJECT, DoH blocklist, dnsmasq.postconf generator. Separated from firewall.sh for clarity — L4 DNS specifics. |
| `addon/lib/iptables_chain.sh` | Low-level: `chain_ensure`, `chain_flush`, `chain_delete`, `rule_exists`, `rule_add_if_missing`, `rule_del_if_exists`. Shared by pbr.sh and firewall.sh. |

### 3.3 New tests

| File | Tests | Coverage |
|---|---|---|
| `addon/tests/iptables_chain_test.bats` | 8 | Primitives |
| `addon/tests/pbr_test.bats` | 16 | Policy CRUD, MAC→IP resolve, apply for each policy, kill-switch, geo ipset |
| `addon/tests/firewall_test.bats` | 12 | Chain lifecycle, incremental apply, IPv6 gating |
| `addon/tests/dns_test.bats` | 6 | DNAT, DoT REJECT, DoH blocklist, dnsmasq.postconf |
| `addon/tests/pbr_migrate_test.bats` | 6 | v1 policy migration (extends state_migrate coverage) |

Target: **≥48 new bats tests** (M1 30 + M2 113 + M3 48 = **≥191** total).

### 3.4 Fixtures

- `addon/tests/fixtures/mock_iptables.sh` — stateful `iptables`/`iptables-restore` mock (shared across tests).
- `addon/tests/fixtures/mock_ipset.sh` — stateful `ipset`/`ipset restore` mock.
- `addon/tests/fixtures/dnsmasq-leases-sample.txt` — sample leases for MAC→IP tests.

### 3.5 Schema additions

New keys in `custom_settings.txt`:

```
awg_default_policy       = direct | vpn_all | vpn_geo      (default: direct)
awg_killswitch_strict    = 0 | 1                           (default: 1)
awg_ipv6_allow_bypass    = 0 | 1                           (default: 0)
awg_doh_blocklist        = <cidr>,<cidr>,...               (optional, empty default)
awg_geo_entries          = <cidr>,<cidr>,...               (M3 manual; M5 auto-fills)
awg_dev_count            = <int>                           (number of configured devices)
awg_dev_<N>_ip           = <IPv4>                          (N = 0..count-1)
awg_dev_<N>_mac          = <lowercase-colon-MAC>           (optional)
awg_dev_<N>_name         = <cosmetic-string>               (optional)
awg_dev_<N>_policy       = vpn_all | vpn_geo | direct
```

Follows Merlin's 29-char key limit and 2999-char value limit.

### 3.6 Runtime state

```
/tmp/amneziawg/
├── pbr-state               # hash of last-applied rule set (for incremental diff)
├── killswitch-armed        # flag file; existence = kill-switch active
└── resolved-devices.json   # last pbr_apply's resolved {ip, mac, name, policy} snapshot

/jffs/configs/
└── dnsmasq.conf.add        # dnsmasq.postconf additions (M3 stub; M5 fills)
```

## 4. PBR architecture

### 4.1 Marking and routing table

- fwmark: `0x100` with mask `0xFF00`.
- Route table: `300`.
- Populated with default route to `awg0` at `awg-quick up` time.

### 4.2 ip rule priorities

```
prio 97  from <direct-device-ip> lookup main      # direct override (bypass vpn)
prio 98  fwmark 0x100/0xFF00    lookup 300        # generic: marked → vpn
prio 99  from <vpn_all-device-ip> lookup 300      # unconditional source vpn
```

**Flow for a given packet:**

- `vpn_all` device → prio 99 → table 300 → awg0.
- `vpn_geo` device to IP in `awg_geo_dst` → iptables MARK → prio 98 → table 300.
- `vpn_geo` device to IP outside ipset → no MARK → main → WAN.
- `direct` device → prio 97 → main → WAN.
- Unlisted device → `default_policy` applies (see §4.4).

### 4.3 iptables custom chains

```
mangle PREROUTING → AMNEZIAWG
    - per vpn_geo device: -s <ip> -m set --match-set awg_geo_dst dst -j MARK 0x100/0xFF00
    - if default_policy=vpn_all:
        - per direct device: -s <ip> -j RETURN   (exception first)
        - -s <LAN-subnet> -j MARK 0x100/0xFF00

nat PREROUTING → AMNEZIAWG_DNS
    - per vpn-policy device: UDP/TCP port 53 DNAT to <router-lan-ip>:53

filter FORWARD → AMNEZIAWG_KILL   (empty unless kill-switch armed)
    - when armed:
        -m mark --mark 0x100/0xFF00 -j DROP
        per vpn-policy device: -s <ip> -j DROP
```

### 4.4 default_policy

Affects how unlisted devices are treated:

- `default_policy=direct` — no blanket MARK, unlisted devices go straight to
  WAN. Typical for opt-in VPN ("my laptop, and only my laptop").
- `default_policy=vpn_all` — blanket MARK for LAN subnet, explicit `direct`
  entries RETURN first. Typical for opt-out ("whole LAN through VPN except
  smart-TV").

### 4.5 Device list and MAC→IP resolution

Each `pbr_apply` re-resolves the device IP:

```sh
_pbr_resolve_ip() {
    _mac="$1"
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        _ip="$(awk -v m="${_mac}" '$2 == m { print $3; exit }' \
                /var/lib/misc/dnsmasq.leases)"
        [ -n "${_ip}" ] && { printf '%s\n' "${_ip}"; return 0; }
    fi
    _ip="$(ip neigh show | awk -v m="${_mac}" \
          'tolower($5) == m { print $1; exit }')"
    [ -n "${_ip}" ] && { printf '%s\n' "${_ip}"; return 0; }
    return 1
}
```

If device has a `mac` stored, `pbr_apply` uses resolved IP (not stored).
Logs a warning when they differ. If no MAC stored or resolve fails, uses
stored IP.

## 5. Batch apply (performance)

v1 naive loop: `for dev in ...; do iptables -A ...; done` — 15-50 ms per
rule, minutes for geo lists.

M3 batch:

- `iptables-restore --noflush -t <table>`: one netlink transaction for the
  full chain content. 100 rules ~ 50 ms.
- `ipset restore`: one transaction for the full set. 5000 entries ~ 1 s.

`ip rule add/del` — kept as per-rule shell loop (no batch equivalent); few
dozen max, not a performance issue.

Capability probe in `firewall_setup`: if `iptables-restore` fails on the
target chain syntax, fall back to per-rule loop with a warning (known
limitation of very old busybox builds).

## 6. DNS leak protection

### 6.1 Force-hijack port 53

**Applied to:**

- Every listed device whose `policy` is `vpn_all` or `vpn_geo`.
- Unlisted devices **only if** `default_policy=vpn_all` — in that case, a
  blanket DNAT for `<LAN-subnet>` is issued, with explicit `-s <direct-ip>
  -j RETURN` rules added before it for every listed `direct` device.
- Unlisted devices are **not** hijacked for `default_policy=direct` (they
  have no VPN intent) or `default_policy=vpn_geo` (destination-filtered
  DNS hijack would either miss or over-block; keeping it tight for M3).

```
iptables -t nat -A AMNEZIAWG_DNS -s <device-ip> -p udp --dport 53 \
    -j DNAT --to-destination <router-lan-ip>:53
iptables -t nat -A AMNEZIAWG_DNS -s <device-ip> -p tcp --dport 53 \
    -j DNAT --to-destination <router-lan-ip>:53
```

Even if the device has `8.8.8.8` set as DNS, the packet is intercepted and
handed to router's dnsmasq. Client needs no reconfiguration. This is the
fix for v1's "set router as DNS manually" requirement.

### 6.2 DoT block (port 853)

REJECT TCP and UDP 853 for VPN-policy devices:

```
iptables -I FORWARD -s <device-ip> -p tcp --dport 853 -j REJECT --reject-with tcp-reset
iptables -I FORWARD -s <device-ip> -p udp --dport 853 -j REJECT
```

Clients fall back to plain DNS on 53 (which we hijack).

### 6.3 DoH blocklist (optional)

User-configurable via `awg_doh_blocklist` (comma-separated CIDRs). Empty by
default — does nothing.

```
for cidr in $(echo "${awg_doh_blocklist}" | tr ',' ' '); do
    iptables -I FORWARD -s <device-ip> -d "${cidr}" -p tcp --dport 443 \
        -j REJECT --reject-with tcp-reset
done
```

Unlike v1's hardcoded 6 IPs (which broke sites sharing those CDNs), M3
leaves it off by default. FAQ documents recommended values for paranoid
users.

### 6.4 dnsmasq.postconf hook (stub in M3)

`dns_dnsmasq_postconf_generate` writes `/jffs/configs/dnsmasq.conf.add` with:
- A banner comment `# Generated by amneziawg — M5 will fill geosite entries here`.
- In M3 — empty body.
- In M5 — `ipset=/domain.com/awg_geo_dst` lines.

Triggers `service restart_dnsmasq` if file changed.

## 7. Kill-switch

### 7.1 State machine

Flag file at `/tmp/amneziawg/killswitch-armed`.

| Current | Transition signal | Action |
|---|---|---|
| disarmed | `tunnel_is_up=true` | noop |
| disarmed | `tunnel_is_up=false` AND `awg_killswitch_strict=1` | arm (apply DROP) |
| disarmed | `tunnel_is_up=false` AND `awg_killswitch_strict=0` | noop (soft mode: allow WAN fallback, log warn once) |
| armed | `tunnel_is_up=true` | disarm (flush kill chain) |
| armed | `tunnel_is_up=false` | noop (rules already applied) |

### 7.2 Rules when armed

```
iptables -F AMNEZIAWG_KILL
iptables -A AMNEZIAWG_KILL -m mark --mark 0x100/0xFF00 -j DROP
# Per vpn-policy device (strict, even unmarked traffic blocked):
iptables -A AMNEZIAWG_KILL -s <vpn-device-ip> -j DROP
```

## 8. IPv6 handling

`firewall_setup` parses `awg0.conf`:

```sh
if grep -qE '^AllowedIPs[^=]*=.*::/0' "${AMNEZIAWG_CONF}"; then
    log_info "ipv6: routed through tunnel"
elif [ "$(state_get awg_ipv6_allow_bypass)" = "1" ]; then
    log_warn "ipv6: bypass allowed — IPv6 leaks possible"
else
    ip6tables -I FORWARD -j DROP 2>/dev/null
    log_info "ipv6: forwarding DROPped (no ::/0 in AllowedIPs)"
fi
```

`firewall_teardown` reverses: `ip6tables -D FORWARD -j DROP`.

No per-device IPv6 matching (SLAAC + privacy extensions give each device
many rotating v6 addresses; reliable per-device IPv6 ACL is infeasible for
M3 scope — it's in v2.x backlog).

## 9. Incremental apply (pbr_reapply_incremental)

Anti-disruption fix for `firewall-start` flap:

```
1. Compute desired state:
     iptables-save -t mangle | grep -E '^-A AMNEZIAWG '
     (same for nat/AMNEZIAWG_DNS, filter/AMNEZIAWG_KILL, ip rule, ipset)
2. hash_desired = sha1 of that
3. hash_current = contents of /tmp/amneziawg/pbr-state (empty first time)
4. If hash_current == hash_desired:
     log_debug "pbr: no changes, skip"
     return 0
5. Otherwise:
     full firewall_setup + pbr_apply (batch apply, ~50ms)
     echo hash_desired > /tmp/amneziawg/pbr-state
```

For most `firewall-start` events (WAN renew without policy change), step 4
returns in <5ms. Only explicit Save operations force rebuild.

## 10. CLI surface (`amneziawg.sh`)

New subcommands in M3:

```
amneziawg.sh pbr list                          # print devices + default_policy
amneziawg.sh pbr set <ip> <policy> [name] [mac]   # upsert device
amneziawg.sh pbr remove <ip>                   # delete device
amneziawg.sh pbr default <policy>              # set default_policy
amneziawg.sh pbr apply                         # force immediate re-apply
amneziawg.sh pbr geo-add <cidr>                # append to awg_geo_entries
amneziawg.sh pbr geo-remove <cidr>             # drop from list
amneziawg.sh pbr geo-clear                     # empty the list
amneziawg.sh pbr status                        # dump current rules / resolved IPs
```

All write operations persist to `custom_settings.txt` and call
`pbr_reapply_incremental`. Thus UI (M4) can wire its form handlers to these
subcommands (via `amng_custom` → `pbr apply` flow).

## 11. Definition of Done

1. All 7 libs (modified + new) match the §3 file table.
2. All new bats suites green; total bats ≥ 191 (30 M1 + 113 M2 + ≥48 M3).
3. `make lint` clean.
4. `make build-all` produces 6 `.ipk`; addon ≤ 200 KB.
5. `pbr_reapply_incremental` hash-identity case: `iptables` not invoked for
   writes (verified via stateful mock).
6. Manual integration checklist (§12) passes on AArch64 router.

## 12. Manual integration checklist

1. Install on AArch64 router; push a test awg0.conf with `Address = 10.8.0.2/24`.
2. `amneziawg.sh pbr set 192.168.1.100 vpn_all laptop aa:bb:cc:dd:ee:ff`.
3. `ip rule show | grep 300` → prio 99 entry present.
4. `iptables -t mangle -L AMNEZIAWG -v` → chain populated.
5. From `192.168.1.100`: `curl ifconfig.me` → VPN-server IP.
6. `amneziawg.sh pbr set 192.168.1.100 direct` → `curl ifconfig.me` → WAN IP
   (without disruption of other connections).
7. `tunnel_stop` → `curl` from 192.168.1.100 times out (kill-switch active).
8. `awg_ipv6_allow_bypass=0`, `AllowedIPs` IPv4-only → `curl -6 ifconfig.me`
   fails.
9. `opkg remove amneziawg-merlin-addon` → `iptables -S | grep AMNEZIAWG` →
   empty; `ipset list awg_geo_dst 2>&1 | grep -i "does not exist"` → matches.

## 13. Out of scope

- WebUI for PBR (M4).
- GeoIP/v2fly auto-population `awg_geo_dst` (M5).
- Domain-based routing via dnsmasq.postconf (M5 fills the stub).
- Per-device DNS override, per-destination advanced policies, MAC-based
  whitelist, per-policy MSS clamp — v2.x.
- Metrics/observability — M6.
- Server mode kill-switch — v2.x (client-only in M2-M6 cycle).
- nftables alternative backend — v2.2+.

## 14. Risks

| Risk | P | Mitigation |
|---|---|---|
| `iptables-restore` quirks on busybox | Med | Capability detect; fallback to per-rule loop |
| `ipset` type unsupported on old kernel | Med | Probe on setup; skip geo-policy with warning if fail |
| `ip neigh` output format variance | Low | Two-parser fallback (field 5 then 4) |
| Concurrent firewall-start events | Low | `flock /tmp/amneziawg/pbr.lock` |
| Empty `nvram lan_ipaddr` | Low | Check + log_error + refuse DNS hijack |
| User's own firewall-start rules conflict | Med | Isolated custom chains; coexistence tested manually only |
| Kill-switch over-blocks (router IP in range) | Low | Strict `-s <device-ip>` per rule; router LAN IP never in device list |

## 15. Backlog (v2.x / post-M3)

- Automatic DoH resolver detection via dnsmasq query introspection.
- Per-device DNS (conditional DNAT per source).
- MAC-spoofing defense (reject mismatched ARP).
- Per-policy MSS clamp (mangle FORWARD -j TCPMSS).
- QoS `cake` on `awg0` for per-category bandwidth limits.
- Subnet-based policies (`192.168.1.0/28` instead of per-IP).
- Time-based policies (VPN during 18:00-08:00 only).
- Bandwidth quotas per device.

## 16. Cross-references

- Module 1 spec: `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`
- Module 2 spec: `docs/superpowers/specs/2026-04-19-module-2-tunnel-lifecycle-design.md`
- Module 2 plan: `docs/superpowers/plans/2026-04-19-module-2-tunnel-lifecycle-plan.md`
- v1 audit findings (in-session memory): `r0otx/asuswrt-merlin-amneziawg@v1.1.6`.
- Merlin User-scripts wiki: https://github.com/RMerl/asuswrt-merlin.ng/wiki/User-scripts
- iptables-restore batch pattern reference: Netfilter project docs.
- Skynet firewall addon (similar batch approach): `Adamm00/IPSet_ASUS`.
