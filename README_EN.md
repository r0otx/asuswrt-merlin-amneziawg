# AmneziaWG for Asuswrt-Merlin

[[русский]](README.md) [[english]](README_EN.md)

DPI-obfuscated WireGuard VPN client with web UI for ASUS routers running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware. Provides per-device policy routing and GeoIP/GeoSite selective routing using [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) protocol.

Fully userspace implementation -- no kernel module required, works on any kernel version.

<details>
    <summary>Supported devices</summary>

All aarch64 (ARM64) routers running Asuswrt-Merlin (`384.15` or later, `3006.x`) with Entware installed:

- GT-AX11000
- GT-AXE11000
- GT-AX6000
- RT-AX86U
- RT-AX86U Pro
- RT-AX88U
- RT-AX88U Pro
- RT-AX58U
- RT-AX56U
- TUF-AX5400

Other aarch64 Merlin routers should also work.

</details>

## Features

- **AmneziaWG protocol** -- WireGuard with DPI obfuscation (Jc, Jmin, Jmax, S1-S4, H1-H4, I1-I5)
- **Userspace daemon** -- based on [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go), no kernel module needed
- **Web UI** -- ROG-styled addon page integrated into router admin panel (VPN > AmneziaWG)
- **Config import** -- upload `.conf` file exported from Amnezia VPN client
- **Per-device routing** -- assign VPN policy per device: `VPN All`, `VPN Geo`, `Direct`
- **GeoIP service routing** -- IP ranges for Telegram, Google, Netflix, Twitter, etc. via [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)
- **GeoSite domain routing** -- domain lists via [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) + dnsmasq ipset
- **Direct exceptions** -- bypass VPN for selected destination domains and IPv4/CIDR ranges
- **Custom domains & IPs** -- manual domain and CIDR entries
- **DNS interception** -- forces DNS through dnsmasq, blocks DoH/DoT for reliable geo routing
- **MSS clamping** -- automatic TCP MSS fix for tunnel traffic
- **Auto-update** -- daily cron for geo list refresh

## Requirements

- [Asuswrt-Merlin firmware](https://www.asuswrt-merlin.net/download) (`384.15` or later, `3006.x`)
- [Entware](https://github.com/Entware/Entware/wiki/Install-on-Asus-stock-firmware) installed (use [amtm](https://diversion.ch/amtm.html) to install)
- SSH access to the router
- AmneziaWG server (self-hosted) -- for quick server setup: [amneziawg-installer](https://github.com/bivlked/amneziawg-installer)

## Installation

### Quick install (one command)

```shell
curl -sfL https://raw.githubusercontent.com/r0otx/asuswrt-merlin-amneziawg/main/install-online.sh | sh
```

The script auto-detects router architecture, downloads the latest package from GitHub releases and installs it.

### From .ipk package

Copy the package to the router and install:

```shell
scp amneziawg_1.0.0-1_aarch64-3.10.ipk admin@<router-ip>:/tmp/
```

```shell
ssh admin@<router-ip>
opkg install /tmp/amneziawg_1.0.0-1_aarch64-3.10.ipk
```

### Manual installation

```shell
scp output/amneziawg-go output/awg admin@<router-ip>:/tmp/
scp addon/amneziawg.sh addon/amneziawg_page.asp admin@<router-ip>:/tmp/
scp install.sh admin@<router-ip>:/tmp/
ssh admin@<router-ip>
sh /tmp/install.sh
```

### Post-installation

1. Log out and log back in to the router web UI
2. Navigate to **VPN > AmneziaWG**
3. Click **Import Config** and upload your `.conf` file from Amnezia VPN client
4. Click **Apply**

## Usage

### Quick start

1. Export config from Amnezia VPN client (`.conf` file)
2. In router UI: **VPN > AmneziaWG > Import Config** -- upload the file
3. Click **Apply** -- tunnel starts automatically
4. Add devices in **Device Rules** section with desired policy

### Routing policies

| Policy | Description |
|--------|-------------|
| **VPN All** | All device traffic goes through VPN |
| **VPN Geo** | Only traffic to GeoIP/GeoSite destinations goes through VPN |
| **Direct** | Device bypasses VPN entirely |

### GeoIP Service Lists

Add service names (comma-separated) to route their IP ranges through VPN:

```
telegram,google,facebook,twitter,netflix,cloudflare
```

These are IP-based -- work without DNS, ideal for Telegram and other apps that connect by IP directly.

### GeoSite Service Lists

Add service names for domain-based routing via dnsmasq:

```
youtube,google,discord,netflix,spotify,instagram
```

Requires devices to use the router as DNS server. For iPhones: **Settings > Wi-Fi > (i) > DNS > Manual > router IP only**.

### Custom entries

- **Custom Domains** -- comma-separated domains (e.g. `example.com,service.org`)
- **Custom IPs** -- comma-separated IPs/CIDRs (e.g. `8.8.8.8,1.1.1.0/24`)

### Direct Exceptions

Use **Direct Domains** and **Direct IPs / Subnets** to bypass VPN for selected destinations while keeping the default policy as `VPN All`.

- Direct domains are resolved by dnsmasq and added to the `awg_direct` ipset.
- Direct IPv4 addresses and CIDR ranges are loaded into `awg_direct` directly.
- The direct ipset is evaluated before per-device and default VPN marking rules.
- Domain-based direct exceptions require clients to use the router as DNS. IPv6 direct exceptions are not applied while IPv6 leak protection is active.

## Building from source

### Prerequisites

- Docker Desktop
- Go 1.24+ (for amneziawg-go)
- GNU tar (`brew install gnu-tar` on macOS)

### Build amneziawg-go (userspace daemon)

```shell
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git
cd amneziawg-go

# ARM64 (aarch64-3.10) — GT-AX11000, RT-AX86U, RT-AX88U
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o ../output/amneziawg-go

# ARM32 (armv7-2.6) — RT-AC68U, RT-AC66U, older ARM routers
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=5 go build -ldflags="-s -w" -o ../output/amneziawg-go-arm5

# ARM32 (armv7-3.2) — RT-AX56U, RT-AX58U, newer HND routers
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -ldflags="-s -w" -o ../output/amneziawg-go-arm
```

### Build awg CLI tool (via Docker)

```shell
# ARM64 (aarch64) — main Dockerfile
./build.sh

# ARM32 (static musl, works on both armv7-2.6 and armv7-3.2)
DOCKER_BUILDKIT=1 docker build -f Dockerfile.arm32 --output=output .
```

### Build .ipk package

```shell
./build-ipk.sh
```

Output: `output/amneziawg_1.0.0-1_aarch64-3.10.ipk`

## CLI usage

```shell
# Start/stop/restart
/opt/etc/init.d/S99amneziawg start
/opt/etc/init.d/S99amneziawg stop
/opt/etc/init.d/S99amneziawg restart

# Show tunnel status
awg show

# Update geo lists
/jffs/addons/amneziawg/amneziawg.sh update_geo
```

## How to uninstall

```shell
/jffs/addons/amneziawg/amneziawg.sh uninstall
opkg remove amneziawg
```

## Architecture

```
Internet <-- awg0 (tunnel) <-- iptables mangle AWG chain <-- br0 (LAN devices)
                                        |
                                ipset awg_dst (GeoIP CIDRs + DNS-resolved IPs)
                                        |
                                fwmark 0x100 -> routing table 300 -> awg0
```

| Component | Role |
|-----------|------|
| **amneziawg-go** | Userspace WireGuard daemon with AmneziaWG extensions |
| **awg** | CLI tool for tunnel management (works with kernel and userspace) |
| **amneziawg.sh** | Backend: lifecycle, firewall, routing, geo lists, DNS interception |
| **amneziawg_page.asp** | Web UI addon page for Merlin |

## FAQ

**Q: Telegram doesn't work through VPN?**

A: Add `telegram` to GeoIP Service Lists. Telegram connects by IP, not DNS -- domain lists alone won't work.

**Q: Sites don't open on iPhone with VPN Geo policy?**

A: iPhone uses encrypted DNS (DoH) which bypasses the router's dnsmasq. Set DNS manually: Settings > Wi-Fi > (i) > DNS > Manual > router IP only.

**Q: Tunnel works for ping but not for websites?**

A: Restart the tunnel with a pause: `/jffs/addons/amneziawg/amneziawg.sh stop; sleep 5; /jffs/addons/amneziawg/amneziawg.sh start`

**Q: How to add a custom service by IP?**

A: Add CIDR ranges in Custom IPs field, e.g. `149.154.160.0/20,91.108.4.0/22` for Telegram.

## Credits

- [AmneziaWG](https://github.com/amnezia-vpn) -- protocol and implementations
- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) -- GeoIP service CIDR lists
- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) -- domain lists
- [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) -- router firmware
- [DanielLavrushin/asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) -- routing architecture reference

## Author

**r0otx** -- [github.com/r0otx](https://github.com/r0otx)

## Disclaimer

This project is a technical tool for network security and privacy. The author is not responsible for any use of this software that violates the laws of any jurisdiction. Users are solely responsible for compliance with applicable legislation.

## License

MIT License
