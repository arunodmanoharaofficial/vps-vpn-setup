#!/usr/bin/env bash
set -Eeuo pipefail

# VPS VPN Setup Installer
# - Enables BBR (or tries BBR2, falls back to BBR)
# - Applies safe sysctl tuning for VPN traffic
# - Optionally configures DNS via systemd-resolved
# - Optionally installs basic network tools (dig/ping/curl)
#
# Usage examples:
#   bash install.sh --bbr --vpn-tuning --dns cloudflare
#   bash install.sh --bbr2 --vpn-tuning --dns cloudflare
#   bash install.sh --bbr --vpn-tuning --no-dns

SCRIPT_NAME="$(basename "$0")"
BACKUP_DIR=""

log()  { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*" >&2; }
die()  { echo -e "❌ $*" >&2; exit 1; }

usage() {
  cat <<EOF
🚀 VPS VPN Setup - install.sh

Options:
  --bbr                 Enable BBR + fq
  --bbr2                Try BBR2 (fallback to BBR if not supported)
  --vpn-tuning           Apply safe sysctl tuning for VPN/NAT traffic
  --dns <provider|ips>   Configure DNS via systemd-resolved
                         Providers: cloudflare | quad9 | google
                         Or custom list: "1.1.1.1,1.0.0.1"
  --no-dns               Do not change DNS
  --no-tools             Skip installing curl/dig/ping tools
  -h, --help             Show this help

Examples:
  curl -fsSL https://raw.githubusercontent.com/arunodmanoharaofficial/vps-vpn-setup/main/install.sh | sudo bash -s -- --bbr --vpn-tuning --dns cloudflare
  sudo bash install.sh --bbr2 --vpn-tuning --dns cloudflare
  sudo bash install.sh --bbr --vpn-tuning --no-dns
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (use: sudo bash $SCRIPT_NAME ...)"
  fi
}

ensure_backup_dir() {
  if [[ -z "$BACKUP_DIR" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/root/vps-tuning-backup-${ts}"
    mkdir -p "$BACKUP_DIR"
    log "Backup folder: $BACKUP_DIR"
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    ensure_backup_dir
    cp -a "$f" "$BACKUP_DIR/"
    log "Backed up: $f"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  backup_file "$path"
  printf "%s\n" "$content" > "$path"
  chmod 0644 "$path"
  log "Wrote: $path"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------------------------
# Parse args
# -------------------------
DO_BBR=false
DO_BBR2=false
DO_VPN_TUNING=false
DNS_MODE=""
NO_DNS=false
INSTALL_TOOLS=true

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbr) DO_BBR=true; shift ;;
    --bbr2) DO_BBR2=true; shift ;;
    --vpn-tuning) DO_VPN_TUNING=true; shift ;;
    --dns)
      [[ $# -ge 2 ]] || die "--dns needs a value (cloudflare|quad9|google|ip,ip)"
      DNS_MODE="$2"
      shift 2
      ;;
    --no-dns) NO_DNS=true; shift ;;
    --no-tools) INSTALL_TOOLS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

require_root

# -------------------------
# Install basic tools (optional)
# -------------------------
if $INSTALL_TOOLS; then
  if has_cmd apt-get; then
    log "Installing basic tools (curl, dig, ping)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y ca-certificates curl iputils-ping bind9-dnsutils >/dev/null || warn "Tool install had warnings; continuing."
  else
    warn "apt-get not found; skipping tool install."
  fi
else
  log "Skipping tools install (--no-tools)."
fi

# -------------------------
# BBR / BBR2
# -------------------------
enable_bbr_like() {
  local want="$1"  # bbr or bbr2
  local module=""
  local algo="$want"

  if [[ "$want" == "bbr2" ]]; then
    module="tcp_bbr2"
  else
    module="tcp_bbr"
  fi

  # Try to load module (may fail if not built as module)
  if modprobe "$module" >/dev/null 2>&1; then
    log "Loaded module: $module"
  else
    warn "Could not load $module (may be unavailable or built-in)."
  fi

  # Check available congestion controls
  local avail=""
  if sysctl -n net.ipv4.tcp_available_congestion_control >/dev/null 2>&1; then
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control || true)"
  fi

  # If BBR2 requested but not available, fallback to BBR
  if [[ "$want" == "bbr2" ]]; then
    if [[ " $avail " != *" bbr2 "* ]]; then
      warn "BBR2 not available on this kernel. Falling back to BBR."
      algo="bbr"
      modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
  fi

  # Persist module load (best-effort)
  write_file "/etc/modules-load.d/bbr.conf" "tcp_bbr"

  # Apply sysctl for fq + chosen algo
  write_file "/etc/sysctl.d/99-bbr.conf" \
"[BBR]
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${algo}
"

  log "Applying sysctl..."
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system returned warnings."

  # Show status
  log "BBR status:"
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
}

if $DO_BBR2; then
  log "Enabling BBR2 (fallback to BBR if unsupported)..."
  enable_bbr_like "bbr2"
elif $DO_BBR; then
  log "Enabling BBR..."
  enable_bbr_like "bbr"
fi

# -------------------------
# VPN sysctl tuning
# -------------------------
if $DO_VPN_TUNING; then
  log "Applying VPN sysctl tuning..."

  # Safe, practical defaults for 50–100 clients on typical VPS
  # (Not ultra-aggressive; avoids risky kernel changes)
  write_file "/etc/sysctl.d/99-vpn-tuning.conf" \
"[VPN Tuning]
# Faster handshakes / better burst handling
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=8192

# TCP behavior improvements
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15

# Keepalives to reduce stuck sessions
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5

# Conntrack for NAT-heavy usage (many VPN clients)
net.netfilter.nf_conntrack_max=262144

# Socket buffers (moderate increase)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
"

  log "Applying sysctl..."
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system returned warnings."
  log "VPN tuning applied."
fi

# -------------------------
# DNS (systemd-resolved)
# -------------------------
configure_dns() {
  local mode="$1"
  local dns=""
  local fallback=""

  case "$mode" in
    cloudflare)
      dns="1.1.1.1 1.0.0.1"
      fallback="9.9.9.9 149.112.112.112"
      ;;
    quad9)
      dns="9.9.9.9 149.112.112.112"
      fallback="1.1.1.1 1.0.0.1"
      ;;
    google)
      dns="8.8.8.8 8.8.4.4"
      fallback="1.1.1.1 1.0.0.1"
      ;;
    *)
      # Custom list: allow commas/spaces
      dns="${mode//,/ }"
      fallback="9.9.9.9 149.112.112.112"
      ;;
  esac

  if ! has_cmd systemctl || ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
    warn "systemd-resolved not detected. Skipping DNS config."
    return 0
  fi

  mkdir -p /etc/systemd/resolved.conf.d

  write_file "/etc/systemd/resolved.conf.d/dns.conf" \
"[Resolve]
DNS=${dns}
FallbackDNS=${fallback}
DNSSEC=no
"

  log "Restarting systemd-resolved..."
  systemctl restart systemd-resolved || warn "Failed to restart systemd-resolved."

  if has_cmd resolvectl; then
    resolvectl flush-caches >/dev/null 2>&1 || true
    log "DNS status (resolvectl):"
    resolvectl status | sed -n '1,25p' || true
  else
    warn "resolvectl not found; can't display DNS status."
  fi
}

if $NO_DNS; then
  log "DNS changes skipped (--no-dns)."
elif [[ -n "$DNS_MODE" ]]; then
  log "Configuring DNS: $DNS_MODE"
  configure_dns "$DNS_MODE"
fi

# -------------------------
# Final tips
# -------------------------
echo
log "Done 🎉"
echo "Quick verify commands:"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  sysctl net.core.default_qdisc"
echo "  sysctl net.ipv4.tcp_available_congestion_control"
echo "  lsmod | egrep 'tcp_bbr|tcp_bbr2' || true"
echo "  resolvectl status | sed -n '1,25p' || true"
echo
