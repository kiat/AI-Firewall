#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
LAN_CIDR="${LAN_CIDR:-10.20.30.1/24}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if ! ip link show "${LAN_IF}" >/dev/null 2>&1; then
  echo "Network interface '${LAN_IF}' was not found. Set LAN_IF to a valid interface name." >&2
  exit 1
fi

required_commands=(ip dnsmasq)
missing_commands=()

for command_name in "${required_commands[@]}"; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    missing_commands+=("${command_name}")
  fi
done

if [[ "${#missing_commands[@]}" -gt 0 ]]; then
  echo "Missing required commands: ${missing_commands[*]}. Run ./check_ubuntu_packages.sh first." >&2
  exit 1
fi

echo "[1/4] Configuring LAN interface"
ip link set "${LAN_IF}" up
ip addr flush dev "${LAN_IF}"
ip addr add "${LAN_CIDR}" dev "${LAN_IF}"

echo "[2/4] Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

echo "[3/4] Writing base dnsmasq config"
DNSMASQ_BASE_CONF_PATH="/etc/dnsmasq.d/ai-firewall-base.conf"
cat > "${DNSMASQ_BASE_CONF_PATH}" <<DNSCONF
interface=${LAN_IF}
bind-interfaces
log-queries
DNSCONF

echo "[4/4] Restarting dnsmasq"
systemctl restart dnsmasq

cat <<MSG
System settings configured.
LAN interface: ${LAN_IF}
LAN network:   ${LAN_CIDR}
WAN setup:     configure manually before running setup_firewall.sh
MSG
