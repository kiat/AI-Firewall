#!/usr/bin/env bash
set -euo pipefail

# You can edit these defaults here or override with environment variables.
LAN_IF="${LAN_IF:-LAN}"
WAN_IF="${WAN_IF:-WAN}"
WHITELIST_FILE="${WHITELIST_FILE:-$(dirname "$0")/whitelist.txt}"
BLOCKED_AI_DOMAINS_FILE="${BLOCKED_AI_DOMAINS_FILE:-$(dirname "$0")/blocked_ai_domains.txt}"
ALLOWED_IPSET="allowed_sites"

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

required_commands=(ip iptables ipset dnsmasq)
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

if [[ ! -f "${WHITELIST_FILE}" ]]; then
  echo "Whitelist file not found: ${WHITELIST_FILE}" >&2
  exit 1
fi

if [[ ! -f "${BLOCKED_AI_DOMAINS_FILE}" ]]; then
  echo "Blocked AI domains file not found: ${BLOCKED_AI_DOMAINS_FILE}" >&2
  exit 1
fi

echo "WARNING: This script will reset all existing iptables rules. A backup will be saved to /etc/iptables/ai-firewall.backup.v4."

load_domains_from_file() {
  local file_path="$1"
  local file_description="$2"
  local domain
  local original_domain

  while IFS= read -r domain || [[ -n "${domain}" ]]; do
    original_domain="${domain}"
    domain="$(echo "${domain}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "${domain}" ]] && continue
    [[ "${domain}" == \#* ]] && continue
    if [[ "${domain}" == \*.* ]]; then
      domain="${domain#*.}"
    fi
    [[ -z "${domain}" ]] && continue
    if ! [[ "${domain}" =~ ^([[:alnum:]-]+\.)+[[:alpha:]]{2,}$ ]]; then
      echo "Invalid domain entry in ${file_description}: '${original_domain}'" >&2
      exit 1
    fi
    echo "${domain}"
  done < "${file_path}"
}

mapfile -t ALLOWED_DOMAINS < <(
  load_domains_from_file "${WHITELIST_FILE}" "whitelist"
)

mapfile -t BLOCKED_AI_DOMAINS < <(
  load_domains_from_file "${BLOCKED_AI_DOMAINS_FILE}" "blocked AI domains file"
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
BLOCKED_COUNT="${#BLOCKED_AI_DOMAINS[@]}"
cat <<MSG
Firewall configured.
LAN interface: ${LAN_IF}
WAN interface: ${WAN_IF}
Whitelist file: ${WHITELIST_FILE}
Blocked AI domains file: ${BLOCKED_AI_DOMAINS_FILE}
Allowed domains loaded: ${ALLOWED_COUNT}
Blocked AI domains loaded: ${BLOCKED_COUNT}
MSG
