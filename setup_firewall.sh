#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
WAN_IF="${WAN_IF:-WAN}"
WHITELIST_FILE="${WHITELIST_FILE:-$(dirname "$0")/whitelist.txt}"
ALLOWED_IPSET="allowed_sites"
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
  echo "Missing required packages. Run ./setup_system_settings.sh first." >&2
  exit 1
fi

if [[ ! -f "${WHITELIST_FILE}" ]]; then
  echo "Whitelist file not found: ${WHITELIST_FILE}" >&2
  exit 1
fi

echo "WARNING: This script will reset all existing iptables rules. A backup will be saved to /etc/iptables/ai-firewall.backup.v4."

mapfile -t ALLOWED_DOMAINS < <(
  while IFS= read -r domain || [[ -n "${domain}" ]]; do
    original_domain="${domain}"
    domain="$(echo "${domain}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "${domain}" ]] && continue
    [[ "${domain}" == \#* ]] && continue
    if [[ "${domain}" == \*.* ]]; then
      domain="${domain#*.}"
    fi
    [[ -z "${domain}" ]] && continue
    # Accept domains with dot-separated labels and a 2+ character alphabetic TLD.
    if ! [[ "${domain}" =~ ^([[:alnum:]-]+\.)+[[:alpha:]]{2,}$ ]]; then
      echo "Invalid domain entry in whitelist: '${original_domain}'" >&2
      exit 1
    fi
    echo "${domain}"
  done < "${WHITELIST_FILE}"
)

echo "[1/4] Creating allow-list ipset"
ipset create "${ALLOWED_IPSET}" hash:ip family inet -exist
ipset flush "${ALLOWED_IPSET}"

echo "[2/4] Writing dnsmasq policy from whitelist file"
DNSMASQ_POLICY_CONF_PATH="/etc/dnsmasq.d/ai-firewall-policy.conf"
{
  echo "# Managed by setup_firewall.sh"
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "ipset=/${domain}/${ALLOWED_IPSET}"
  done

  for domain in "${BLOCKED_AI_DOMAINS[@]}"; do
    echo "address=/${domain}/"
  done
} > "${DNSMASQ_POLICY_CONF_PATH}"

systemctl restart dnsmasq

echo "[3/4] Applying iptables firewall"
mkdir -p /etc/iptables
iptables-save > /etc/iptables/ai-firewall.backup.v4
iptables -F
iptables -t nat -F
iptables -X

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
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
iptables -P INPUT DROP
iptables -P FORWARD DROP

echo "[4/4] Saving firewall rules"
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
elif command -v iptables-save >/dev/null 2>&1; then
  iptables-save > /etc/iptables/rules.v4
fi

ALLOWED_COUNT="${#ALLOWED_DOMAINS[@]}"
cat <<MSG
Firewall configured.
LAN interface: ${LAN_IF}
WAN interface: ${WAN_IF}
Whitelist file: ${WHITELIST_FILE}
Allowed domains loaded: ${ALLOWED_COUNT}
Blocked AI domains: ${BLOCKED_AI_DOMAINS[*]}
MSG
