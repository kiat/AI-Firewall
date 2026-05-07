#!/usr/bin/env bash
set -euo pipefail

LAN_IF="${LAN_IF:-LAN}"
WAN_IF="${WAN_IF:-WAN}"
LAN_CIDR="${LAN_CIDR:-10.20.30.1/24}"
DHCP_START="${DHCP_START:-10.20.30.50}"
DHCP_END="${DHCP_END:-10.20.30.200}"
DHCP_LEASE="${DHCP_LEASE:-12h}"
ALLOWED_IPSET="allowed_sites"

ALLOWED_DOMAINS=(
  "canvas.instructure.com"
  "instructure.com"
  "python.org"
  "wikipedia.org"
)

BLOCKED_AI_DOMAINS=(
  "openai.com"
  "chatgpt.com"
  "claude.ai"
  "anthropic.com"
  "copilot.microsoft.com"
  "githubcopilot.com"
)

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

if ! command -v iptables >/dev/null 2>&1 || ! command -v ipset >/dev/null 2>&1 || ! command -v dnsmasq >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y iptables ipset dnsmasq
fi

echo "[1/6] Configuring LAN/WAN interfaces"
ip link set "${LAN_IF}" up
ip link set "${WAN_IF}" up
ip addr flush dev "${LAN_IF}"
ip addr add "${LAN_CIDR}" dev "${LAN_IF}"

if ! ip route show default | grep -q "dev ${WAN_IF}"; then
  if ! dhclient -v "${WAN_IF}"; then
    echo "Warning: Unable to obtain DHCP lease on ${WAN_IF}. WAN internet may be unavailable." >&2
  fi
fi

echo "[2/6] Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

echo "[3/6] Creating allow-list IP set"
ipset create "${ALLOWED_IPSET}" hash:ip family inet -exist
ipset flush "${ALLOWED_IPSET}"

echo "[4/6] Writing dnsmasq policy"
DNSMASQ_CONF="/etc/dnsmasq.d/ai-firewall.conf"
cat > "${DNSMASQ_CONF}" <<DNSCONF
interface=${LAN_IF}
bind-interfaces
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=option:router,${LAN_CIDR%/*}
dhcp-option=option:dns-server,${LAN_CIDR%/*}
log-queries
log-dhcp
DNSCONF

for domain in "${ALLOWED_DOMAINS[@]}"; do
  echo "ipset=/${domain}/${ALLOWED_IPSET}" >> "${DNSMASQ_CONF}"
done

for domain in "${BLOCKED_AI_DOMAINS[@]}"; do
  echo "address=/${domain}/" >> "${DNSMASQ_CONF}"
done

systemctl restart dnsmasq

echo "[5/6] Applying iptables firewall"
echo "Warning: this resets existing iptables rules on this host."
iptables -F
iptables -t nat -F
iptables -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i "${LAN_IF}" -p udp --dport 67:68 -j ACCEPT
iptables -A INPUT -i "${LAN_IF}" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "${LAN_IF}" -p tcp --dport 53 -j ACCEPT

iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i "${LAN_IF}" -o "${WAN_IF}" -m set --match-set "${ALLOWED_IPSET}" dst -j ACCEPT
iptables -A FORWARD -i "${LAN_IF}" -o "${WAN_IF}" -j DROP

iptables -t nat -A POSTROUTING -o "${WAN_IF}" -j MASQUERADE

echo "[6/6] Saving rules (if persistence tools exist)"
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
elif command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
fi

cat <<MSG
Firewall configured.
LAN interface: ${LAN_IF}
WAN interface: ${WAN_IF}
LAN network:   ${LAN_CIDR}
Allowed domains: ${ALLOWED_DOMAINS[*]}
Blocked AI domains: ${BLOCKED_AI_DOMAINS[*]}
MSG
