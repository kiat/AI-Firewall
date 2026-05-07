#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
WAN_IF="${WAN_IF:-WAN}"
LAN_CIDR="${LAN_CIDR:-10.20.30.1/24}"
DHCP_START="${DHCP_START:-10.20.30.50}"
DHCP_END="${DHCP_END:-10.20.30.200}"
DHCP_LEASE="${DHCP_LEASE:-12h}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

for interface in "${LAN_IF}" "${WAN_IF}"; do
  if ! ip link show "${interface}" >/dev/null 2>&1; then
    echo "Network interface '${interface}' was not found. Set LAN_IF/WAN_IF to valid interface names." >&2
    exit 1
  fi
done

required_commands=(ip iptables ipset dnsmasq dhclient)
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

echo "[1/4] Configuring LAN/WAN interfaces"
ip link set "${LAN_IF}" up
ip link set "${WAN_IF}" up
ip addr flush dev "${LAN_IF}"
ip addr add "${LAN_CIDR}" dev "${LAN_IF}"

if ! ip route show default | grep -qw "dev ${WAN_IF}"; then
  if ip -4 addr show dev "${WAN_IF}" | grep -q "inet "; then
    echo "Info: No default route via ${WAN_IF}; using existing IP configuration. Verify WAN connectivity manually if needed."
  elif ! dhclient -1 -v "${WAN_IF}"; then
    echo "Warning: Unable to obtain DHCP lease on ${WAN_IF}. Continuing, but WAN internet may be unavailable." >&2
  fi
fi

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
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=option:router,${LAN_CIDR%/*}
dhcp-option=option:dns-server,${LAN_CIDR%/*}
log-queries
log-dhcp
DNSCONF

echo "[4/4] Restarting dnsmasq"
systemctl restart dnsmasq

cat <<MSG
System settings configured.
LAN interface: ${LAN_IF}
WAN interface: ${WAN_IF}
LAN network:   ${LAN_CIDR}
MSG
