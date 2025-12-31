# 🚀 VPS VPN Setup

This repository contains an installer script and tuning recommendations for setting up a Debian 13 (or Ubuntu) VPS to run a VPN server for up to 50–100 clients using 3x‑ui/Xray (VLESS/Trojan/VMess) while maintaining stability and good performance.

## 📦 Contents

- **install.sh** – 🔧 a single script that enables BBR congestion control, applies safe sysctl tuning for VPN traffic, and optionally configures DNS on the server via `systemd‑resolved`.
- **README.md** – 📖 this guide explaining how to use the script, what each tuning does, and why it benefits a busy VPN server.

## 💻 Usage

You can run the installer directly from GitHub using `curl` or `wget`. These examples assume you want to enable BBR, apply the VPN tuning, and set Cloudflare DNS (1.1.1.1 / 1.0.0.1) with Quad9 fallback (9.9.9.9 / 149.112.112.112). Replace `arunodmanoharaofficial` with your GitHub username if you fork this repo.

```bash
# Run the installer with BBR + VPN tuning + Cloudflare DNS
curl -fsSL https://raw.githubusercontent.com/arunodmanoharaofficial/vps-vpn-setup/main/install.sh \
  | sudo bash -s -- --bbr --vpn-tuning --dns cloudflare

# If you want to try enabling BBR2 (falls back to BBR if unsupported)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/arunodmanoharaofficial/vps-vpn-setup/main/install.sh) \
  --bbr2 --vpn-tuning --dns cloudflare

# Skip DNS changes (leave your provider's DNS settings)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/arunodmanoharaofficial/vps-vpn-setup/main/install.sh) \
  --bbr --vpn-tuning --no-dns
```

The script is idempotent: you can run it multiple times without causing duplicate settings. DNS settings are applied via a drop‑in for `systemd‑resolved`; sysctl files live in `/etc/sysctl.d`.

## 🪒 What the script does

The installer script performs these actions:

### 1. ⚡️ Enables BBR (or BBR2 if available)

- Loads the `tcp_bbr` (or `tcp_bbr2`) kernel module and ensures it will load on boot.
- Sets the default queue discipline to `fq` (fair queuing) and the congestion control to `bbr`.
- On kernels compiled with BBR2 support, you can opt into `--bbr2`, otherwise it defaults to BBR.

**Why:** BBR helps maintain high throughput while keeping latency low under load. For a VPN server with many concurrent TCP connections, BBR improves responsiveness, especially when the network path is congested.

### 2. 🛠️ Applies sysctl tuning for VPN traffic

Adds a file `/etc/sysctl.d/99-vpn-tuning.conf` with sensible values to improve connection stability and handle bursts of traffic:

| Setting | Purpose |
| --- | --- |
| `net.core.somaxconn=65535` | Increase the maximum length of the pending connections queue. |
| `net.core.netdev_max_backlog=250000` | Raise the backlog for received packets before kernel drops them. |
| `net.ipv4.tcp_max_syn_backlog=8192` | Allow more pending TCP SYN connections during handshake. |
| `net.ipv4.tcp_fastopen=3` | Enable TCP Fast Open (client and server) for quicker connection setup. |
| `net.ipv4.tcp_mtu_probing=1` | Detect proper MTU to avoid fragmentation and black holes. |
| `net.ipv4.tcp_fin_timeout=15` | Close finished TCP sockets more quickly to free resources. |
| `net.ipv4.tcp_keepalive_time=600` | Interval (seconds) for sending TCP keepalive probes. |
| `net.ipv4.tcp_keepalive_intvl=60` | Time between individual keepalive probes. |
| `net.ipv4.tcp_keepalive_probes=5` | Number of probes sent before assuming the connection is dead. |
| `net.netfilter.nf_conntrack_max=262144` | Increase the number of tracked connections (useful when NATing many clients). |
| `net.core.rmem_max`/`net.core.wmem_max` | Raise socket buffer limits for better throughput under load. |
| `net.ipv4.tcp_rmem`/`tcp_wmem` | Default/min/max sizes for TCP read/write buffers. |

**Why:** These values help prevent packet loss and connection drops when many users connect simultaneously. They avoid running out of connection tracking entries and improve NAT performance.

### 3. 🌐 Configures DNS (optional)

If you supply `--dns cloudflare`, `--dns quad9`, `--dns google`, or a custom provider, the script writes a drop‑in file under `/etc/systemd/resolved.conf.d`. This sets `DNS` and `FallbackDNS` servers for `systemd‑resolved`. You can also skip DNS changes with `--no-dns`.

**Why:** Using a fast, privacy‑oriented DNS provider (like Cloudflare or Quad9) can reduce DNS lookup latency for your VPN clients and avoid ISP DNS hijacking.

### 4. 🥮 Installs basic network troubleshooting tools

The script optionally installs `curl`, `bind9-dnsutils` (provides `dig`), and `iputils-ping` so you can verify connectivity and DNS from the server.

### 5. 🗂️ Creates backups of existing config

Before modifying sysctl files or DNS settings, the script makes a backup directory (e.g. `/root/vps-tuning-backup-YYYYmmdd-hhmmss`) with copies of modified files so you can restore previous settings if needed.

## 🎯 Benefits of this setup

- 🚀 **Improved throughput and stability:** BBR congestion control with fair queuing delivers better performance under load and reduces latency spikes.
- 🔒 **More resilient connections:** sysctl tuning optimizes socket buffers, backlog queues, and connection tracking, preventing drops when many clients connect.
- 🔄 **Cleaner connection teardown:** lower `tcp_fin_timeout` and tuned keepalives free up resources more quickly, helpful for busy VPN servers.
- 🌍 **Optional DNS hardening:** using Cloudflare or Quad9 ensures faster, more secure DNS resolution for your server and clients.
- ♻️ **Idempotent and reversible:** you can rerun the script safely; backups allow reverting if you need to undo changes.

## 👋 License

No license is included by default. You may distribute or modify this script under your own terms.

🎉 Enjoy your optimized VPN server!
