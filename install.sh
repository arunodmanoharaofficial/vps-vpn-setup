```bash
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VPS VPN Setup Installer (Debian/Ubuntu)
# - Enables BBR (or tries BBR2 and falls back safely)
# - Applies safe sysctl tuning for VPN traffic (50–100 clients)
# - Optionally configures DNS via systemd-resolved
# - Installs basic troubleshooting tools
# - Creates backups before changing anything
#
# Matches README commands:
#   --bbr --bbr2 --vpn-tuning --dns cloudflare|quad9|google --no-dns
# ============================================================

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install.sh [options]

Options:
  --bbr            Enable BBR (recommended)
  --bbr2           Try BBR2; falls back to BBR if unsupported
  --vpn-tuning     Apply safe VPN tuning sysctls
  --dns PROVIDER   Configure DNS via systemd-resolved:
                   cloudflare | quad9 | google
  --no-dns         Do not change DNS
  --dry-run        Print actions without writing files
  -h, --help       Show help

Examples:
  sudo bash install.sh --bbr --vpn-tuning --dns cloudflare
  sudo bash install.sh --bbr2 --vpn-tuning --dns cloudflare
  sudo bash install.sh --bbr --vpn-tuning --no-dns
EOF
}

# -------------------------
# Defaults
# -------------------------
ENABLE_BBR=false
TRY_BBR2=false
APPLY_VPN_TUNING=false
DNS_PROVIDER=""
SKIP_DNS=false
DRY_RUN=false

# If user runs with no flags, do a safe default:
# BBR + VPN tuning + no DNS changes (avoid surprises)
DEFAULT_IF_EMPTY=true

# -------------------------
# Parse args
# -------------------------
if [[ $# -gt 0 ]]; then
  DEFAULT_IF_EMPTY=false
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbr) ENABLE_BBR=true; shift ;;
    --bbr2) TRY_BBR2=true; shift ;;
    --vpn-tuning) APPLY_VPN_TUNING=true; shift ;;
    --dns) DNS_PROVIDER="${2:-}"; [[ -n "$DNS_PROVIDER" ]] || die "--dns requires a value"; shift 2 ;;
    --no-dns) SKIP_DNS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if $DEFAULT_IF_EMPTY; then
  ENABLE_BBR=true
  APPLY_VPN_TUNING=true
  SKIP_DNS=true
fi

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  run "mkdir -p '$(dirname "$path")'"
  if $DRY_RUN; then
    echo "[dry-run] write -> $path"
    echo "$content"
  else
    printf "%s\n" "$content" > "$path"
  fi
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (use sudo)."
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
  else
    die "Cannot detect OS (/etc/os-release missing)."
  fi
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) warn "This script is intended for Debian/Ubuntu (detected: ${ID:-unknown}). Continuing..." ;;
  esac
}

backup_files() {
  local ts backup_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/vps-vpn-setup-backup-$ts"
  run "mkdir -p '$backup_dir'"

  for f in \
    /etc/sysctl.d/99-bbr.conf \
    /etc/sysctl.d/99-vpn-tuning.conf \
    /etc/modules-load.d/bbr.conf \
    /etc/systemd/resolved.conf \
    /etc/systemd/resolved.conf.d/dns.conf \
    /etc/systemd/resolved.conf.d/99-dns.conf \
    /etc/resolv.conf
  do
    if [[ -e "$f" ]]; then
      run "cp -a '$f' '$backup_dir/'"
    fi
  done

  log "Backups saved to: $backup_dir"
}

install_tools() {
  log "Installing basic troubleshooting tools..."
  run "apt-get update -y"
  run "apt-get install -y --no-install-recommends curl ca-certificates dnsutils iputils-ping iproute2 procps jq"
}

apply_sysctl() {
  log "Applying sysctl settings..."
  run "sysctl --system >/dev/null || true"
}

apply_bbr() {
  log "Enabling BBR (v1) + fq..."

  # Persist module load
  write_file "/etc/modules-load.d/bbr.conf" "tcp_bbr"
  run "modprobe tcp_bbr || true"

  write_file "/etc/sysctl.d/99-bbr.conf" $'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n'
  apply_sysctl
}

apply_bbr2_or_fallback() {
  log "Trying to enable BBR2 (fallback to BBR if unsupported)..."

  # Try loading BBR2 module (many kernels won't have it)
  if run "modprobe tcp_bbr2"; then
    write_file "/etc/modules-load.d/bbr.conf" "tcp_bbr2"
    write_file "/etc/sysctl.d/99-bbr.conf" $'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr2\n'
    apply_sysctl
    log "BBR2 enabled ✅"
  else
    warn "BBR2 not available on this kernel. Falling back to BBR v1 ✅"
    apply_bbr
  fi
}

apply_vpn_tuning() {
  log "Applying VPN sysctl tuning..."

  # Matches your README table (balanced, safe)
  write_file "/etc/sysctl.d/99-vpn-tuning.conf" $'\
net.core.somaxconn=65535\n\
net.core.netdev_max_backlog=250000\n\
net.ipv4.tcp_max_syn_backlog=8192\n\
\n\
net.ipv4.tcp_fastopen=3\n\
net.ipv4.tcp_mtu_probing=1\n\
\n\
net.ipv4.tcp_fin_timeout=15\n\
net.ipv4.tcp_keepalive_time=600\n\
net.ipv4.tcp_keepalive_intvl=60\n\
net.ipv4.tcp_keepalive_probes=5\n\
\n\
net.netfilter.nf_conntrack_max=262144\n\
\n\
net.core.rmem_max=16777216\n\
net.core.wmem_max=16777216\n\
net.ipv4.tcp_rmem=4096 87380 16777216\n\
net.ipv4.tcp_wmem=4096 65536 16777216\n'

  apply_sysctl
}

dns_block_for() {
  case "$1" in
    cloudflare)
      echo -e "DNS=1.1.1.1 1.0.0.1\nFallbackDNS=9.9.9.9 149.112.112.112"
      ;;
    quad9)
      echo -e "DNS=9.9.9.9 149.112.112.112\nFallbackDNS=1.1.1.1 1.0.0.1"
      ;;
    google)
      echo -e "DNS=8.8.8.8 8.8.4.4\nFallbackDNS=1.1.1.1 1.0.0.1"
      ;;
    *)
      die "Unknown DNS provider: $1 (use cloudflare|quad9|google)"
      ;;
  esac
}

apply_dns() {
  [[ -n "$DNS_PROVIDER" ]] || die "--dns requires a provider (cloudflare|quad9|google)"
  log "Configuring DNS via systemd-resolved ($DNS_PROVIDER)..."

  if ! command -v resolvectl >/dev/null 2>&1; then
    warn "resolvectl not found; installing systemd-resolved..."
    run "apt-get update -y"
    run "apt-get install -y systemd-resolved"
  fi

  run "mkdir -p /etc/systemd/resolved.conf.d"

  local dns_lines
  dns_lines="$(dns_block_for "$DNS_PROVIDER")"

  write_file "/etc/systemd/resolved.conf.d/dns.conf" $"[Resolve]\n${dns_lines}\nDNSSEC=no\n"

  run "systemctl enable systemd-resolved >/dev/null 2>&1 || true"
  run "systemctl restart systemd-resolved || true"
  run "resolvectl flush-caches >/dev/null 2>&1 || true"

  # Some providers manage /etc/resolv.conf; warn if it isn't a symlink
  if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf is not a symlink. Your provider/network may still inject DNS on interfaces."
    warn "This is usually OK; systemd-resolved will still use the configured DNS as a global resolver."
  fi
}

verify() {
  log "Verification:"
  echo "Kernel: $(uname -r)"
  echo "Available CC: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  echo "CC active:    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  echo "qdisc:        $(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  echo "fastopen:     $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true)"
  echo "mtu_probing:  $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)"
  echo "backlog:      $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || true)"
  echo "somaxconn:    $(sysctl -n net.core.somaxconn 2>/dev/null || true)"
  echo "conntrack:    $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)"

  if command -v lsmod >/dev/null 2>&1; then
    echo "tcp_bbr loaded:  $(lsmod | grep -q '^tcp_bbr' && echo yes || echo no)"
    echo "tcp_bbr2 loaded: $(lsmod | grep -q '^tcp_bbr2' && echo yes || echo no)"
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    echo
    log "DNS (resolvectl status):"
    resolvectl status | sed -n '1,40p' || true
  fi
}

main() {
  need_root
  detect_os
  backup_files
  install_tools

  if $TRY_BBR2; then
    apply_bbr2_or_fallback
  elif $ENABLE_BBR; then
    apply_bbr
  fi

  if $APPLY_VPN_TUNING; then
    apply_vpn_tuning
  fi

  if $SKIP_DNS; then
    log "Skipping DNS changes (--no-dns)."
  elif [[ -n "$DNS_PROVIDER" ]]; then
    apply_dns
  fi

  verify

  echo
  log "Done ✅"
  warn "Firewall was NOT changed (safe)."
  warn "Reboot is optional. Settings persist via /etc/sysctl.d and /etc/modules-load.d."
}

main
```
