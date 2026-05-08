#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
WAN_IF="${WAN_IF:-WAN}"
LAN_CIDR="${LAN_CIDR:-10.20.30.1/24}"
# Netplan renderer: use 'NetworkManager' when NM manages wifi, or 'networkd' for headless/server setups.
NETPLAN_RENDERER="${NETPLAN_RENDERER:-NetworkManager}"
# DHCP pool: first address offset from the network base and total pool size.
DHCP_RANGE_OFFSET="${DHCP_RANGE_OFFSET:-10}"
DHCP_RANGE_SIZE="${DHCP_RANGE_SIZE:-90}"
HOSTAPD_DRIVER="${HOSTAPD_DRIVER:-nl80211}"
HOTSPOT_SSID="${HOTSPOT_SSID:-MyFilteredHotspot}"
HOTSPOT_HW_MODE="${HOTSPOT_HW_MODE:-g}"
HOTSPOT_CHANNEL="${HOTSPOT_CHANNEL:-6}"
HOTSPOT_WPA_PASSPHRASE="${HOTSPOT_WPA_PASSPHRASE:-StrongPassword123}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if ! ip link show "${LAN_IF}" >/dev/null 2>&1; then
  echo "Network interface '${LAN_IF}' was not found. Set LAN_IF to a valid interface name." >&2
  exit 1
fi

if ! ip link show "${WAN_IF}" >/dev/null 2>&1; then
  echo "Network interface '${WAN_IF}' was not found. Set WAN_IF to a valid interface name." >&2
  exit 1
fi

required_commands=(ip netplan dnsmasq hostapd nft sysctl)
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

if (( ${#HOTSPOT_WPA_PASSPHRASE} < 8 || ${#HOTSPOT_WPA_PASSPHRASE} > 63 )); then
  echo "HOTSPOT_WPA_PASSPHRASE must be between 8 and 63 characters." >&2
  exit 1
fi

echo "[1/6] Configuring LAN hotspot interface via netplan"
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

echo "[2/6] Configuring hostapd hotspot"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
mkdir -p /etc/hostapd
cat > "${HOSTAPD_CONF}" <<HOSTAPD
interface=${LAN_IF}
driver=${HOSTAPD_DRIVER}
ssid=${HOTSPOT_SSID}
hw_mode=${HOTSPOT_HW_MODE}
channel=${HOTSPOT_CHANNEL}
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
HOSTAPD

HOSTAPD_DEFAULT_CONF="/etc/default/hostapd"
if [[ -f "${HOSTAPD_DEFAULT_CONF}" ]]; then
  if grep -q '^DAEMON_CONF=' "${HOSTAPD_DEFAULT_CONF}"; then
    sed -i 's|^DAEMON_CONF=.*$|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' "${HOSTAPD_DEFAULT_CONF}"
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> "${HOSTAPD_DEFAULT_CONF}"
  fi
else
  cat > "${HOSTAPD_DEFAULT_CONF}" <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
fi
systemctl enable --now hostapd

echo "[3/6] Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -p >/dev/null

echo "[4/6] Writing base dnsmasq config"
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

echo "[5/6] Applying nftables NAT/forwarding"
if ! nft list table ip nat >/dev/null 2>&1; then
  nft add table ip nat
fi
if ! nft list chain ip nat postrouting >/dev/null 2>&1; then
  nft add chain ip nat postrouting '{ type nat hook postrouting priority 100 ; }'
fi
nft flush chain ip nat postrouting
nft add rule ip nat postrouting oifname "${WAN_IF}" masquerade

if ! nft list table ip filter >/dev/null 2>&1; then
  nft add table ip filter
fi
if ! nft list chain ip filter forward >/dev/null 2>&1; then
  nft add chain ip filter forward '{ type filter hook forward priority 0 ; policy drop ; }'
fi
nft flush chain ip filter forward
nft add rule ip filter forward iifname "${LAN_IF}" oifname "${WAN_IF}" accept
nft add rule ip filter forward iifname "${WAN_IF}" oifname "${LAN_IF}" ct state related,established accept

echo "[6/7] Persisting nftables rules"
nft list ruleset > /etc/nftables.conf
systemctl enable nftables >/dev/null

echo "[7/7] Restarting dnsmasq"
systemctl restart dnsmasq

cat <<MSG
System settings configured.
LAN interface: ${LAN_IF}
LAN address:   ${LAN_CIDR}
DHCP range:    ${DHCP_START} - ${DHCP_END}  (netmask ${NETMASK})
Hotspot SSID:  ${HOTSPOT_SSID}
WAN interface: ${WAN_IF}
MSG
