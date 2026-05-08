#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
LAN_CIDR="${LAN_CIDR:-10.20.30.1/24}"
# Netplan renderer: use 'NetworkManager' when NM manages wifi, or 'networkd' for headless/server setups.
NETPLAN_RENDERER="${NETPLAN_RENDERER:-NetworkManager}"
# DHCP pool: first address offset from the network base and total pool size.
DHCP_RANGE_OFFSET="${DHCP_RANGE_OFFSET:-10}"
DHCP_RANGE_SIZE="${DHCP_RANGE_SIZE:-90}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if ! ip link show "${LAN_IF}" >/dev/null 2>&1; then
  echo "Network interface '${LAN_IF}' was not found. Set LAN_IF to a valid interface name." >&2
  exit 1
fi

required_commands=(ip netplan dnsmasq)
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

# Derive DHCP range and netmask from LAN_CIDR using bash integer arithmetic.
LAN_IP="${LAN_CIDR%%/*}"
LAN_PREFIX="${LAN_CIDR##*/}"

_p="${LAN_PREFIX}"
_mask=$(( (0xFFFFFFFF << (32 - _p)) & 0xFFFFFFFF ))
IFS='.' read -r _o1 _o2 _o3 _o4 <<< "${LAN_IP}"
_ip_int=$(( (_o1 << 24) | (_o2 << 16) | (_o3 << 8) | _o4 ))
_net_int=$(( _ip_int & _mask ))
_start=$(( _net_int + DHCP_RANGE_OFFSET ))
_end=$(( _net_int + DHCP_RANGE_OFFSET + DHCP_RANGE_SIZE - 1 ))
DHCP_START="$(( (_start >> 24) & 0xFF )).$(( (_start >> 16) & 0xFF )).$(( (_start >> 8) & 0xFF )).$(( _start & 0xFF ))"
DHCP_END="$(( (_end >> 24) & 0xFF )).$(( (_end >> 16) & 0xFF )).$(( (_end >> 8) & 0xFF )).$(( _end & 0xFF ))"
NETMASK="$(( (_mask >> 24) & 0xFF )).$(( (_mask >> 16) & 0xFF )).$(( (_mask >> 8) & 0xFF )).$(( _mask & 0xFF ))"

echo "[1/4] Configuring LAN hotspot interface via netplan"
ip link set "${LAN_IF}" up

NETPLAN_CONF="/etc/netplan/01-hotspot.yaml"
mkdir -p /etc/netplan
cat > "${NETPLAN_CONF}" <<NETPLAN
network:
  version: 2
  renderer: ${NETPLAN_RENDERER}
  wifis:
    ${LAN_IF}:
      dhcp4: no
      addresses:
        - ${LAN_CIDR}
NETPLAN

netplan apply

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
dhcp-range=${DHCP_START},${DHCP_END},${NETMASK},12h
domain-needed
bogus-priv
server=8.8.8.8
server=1.1.1.1
log-queries
DNSCONF

echo "[4/4] Restarting dnsmasq"
systemctl restart dnsmasq

cat <<MSG
System settings configured.
LAN interface: ${LAN_IF}
LAN address:   ${LAN_CIDR}
DHCP range:    ${DHCP_START} - ${DHCP_END}  (netmask ${NETMASK})
WAN setup:     configure manually before running setup_firewall.sh
MSG
