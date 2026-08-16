#!/bin/bash

###############################################################################
# Ubuntu Controlled WiFi Router
###############################################################################
#
# WAN:
#     wlp3s0
#
# LAN / Hotspot:
#     wlx984827c3f4db
#
# LAN Network:
#     10.10.0.0/24
#
# Router:
#     10.10.0.1
#
# DHCP:
#     10.10.0.2 - 10.10.0.200
#
###############################################################################
#
# WHITELIST:
# Current folder should include the white-list.txt file. 
#     ./white-list.txt
#
# Example:
#
#     canvas.utexas.edu
#     utexas.edu
#     python.org
#     wikipedia.org
#
###############################################################################
#
# FIREWALL POLICY:
#
# Allowed destination IP:
#
#     LAN -> Internet
#
# Non-allowed HTTP:
#
#     LAN -> Internet:80
#          |
#          +----> Router:80
#
# Non-allowed HTTPS:
#
#     LAN -> Internet:443
#          |
#          +----> Router:443
#
###############################################################################

###############################################################################
# IMPORTANT
#
# Run this script with BASH:
#
#     sudo bash myrouter.sh
#
# or:
#
#     chmod +x myrouter.sh
#     sudo ./myrouter.sh
#
###############################################################################

set -e

###############################################################################
# CONFIGURATION
###############################################################################

WAN_IF="wlp3s0"
LAN_IF="wlx984827c3f4db"

HOTSPOT_IP="10.10.0.1"
HOTSPOT_CIDR="10.10.0.0/24"

DHCP_START="10.10.0.2"
DHCP_END="10.10.0.200"

SSID="CS-Tests"
PASSWORD="CS4UT2026"

IPSET_NAME="allowed_sites"

DNS1="8.8.8.8"
DNS2="1.1.1.1"

###############################################################################
# FILE LOCATIONS
###############################################################################

CONFIG_DIR="."

WHITE_LIST_FILE="${CONFIG_DIR}/white-list.txt"

DNSMASQ_CONFIG="/etc/dnsmasq.d/cs-router.conf"

###############################################################################
# CHECK ROOT
###############################################################################

if [ "$EUID" -ne 0 ]; then

    echo
    echo "ERROR: This script must be run as root."
    echo
    echo "Run:"
    echo
    echo "    sudo ./myrouter.sh"
    echo

    exit 1

fi

###############################################################################
# CHECK THAT BASH IS BEING USED
###############################################################################

if [ -z "$BASH_VERSION" ]; then

    echo
    echo "ERROR: This script must be run using Bash."
    echo
    echo "Use:"
    echo
    echo "    sudo bash myrouter.sh"
    echo

    exit 1

fi

###############################################################################
# START
###############################################################################

echo
echo "============================================================"
echo "        Ubuntu Controlled WiFi Router"
echo "============================================================"
echo

###############################################################################
# 1. CHECK WHITE-LIST
###############################################################################

echo "[1/12] Checking white-list..."

mkdir -p "$CONFIG_DIR"

if [ ! -f "$WHITE_LIST_FILE" ]; then

    echo
    echo "ERROR: White-list file does not exist:"
    echo
    echo "    $WHITE_LIST_FILE"
    echo
    echo "Create it with:"
    echo
    echo "    sudo mkdir -p $CONFIG_DIR"
    echo "    sudo nano $WHITE_LIST_FILE"
    echo
    echo "Example:"
    echo
    echo "    canvas.utexas.edu"
    echo "    utexas.edu"
    echo "    python.org"
    echo "    wikipedia.org"
    echo

    exit 1

fi

###############################################################################
# DISPLAY WHITE-LIST
###############################################################################

echo
echo "Allowed domains:"
echo "------------------------------------------------------------"

grep -Ev '^[[:space:]]*(#|$)' "$WHITE_LIST_FILE" \
    | sed 's/[[:space:]]*$//' \
    | sort -u || true

echo "------------------------------------------------------------"

###############################################################################
# 2. VERIFY NETWORK INTERFACES
###############################################################################

echo
echo "[2/12] Verifying network interfaces..."

if ! ip link show "$WAN_IF" >/dev/null 2>&1; then

    echo
    echo "ERROR: WAN interface '$WAN_IF' does not exist."
    echo

    exit 1

fi

if ! ip link show "$LAN_IF" >/dev/null 2>&1; then

    echo
    echo "ERROR: LAN interface '$LAN_IF' does not exist."
    echo

    exit 1

fi

echo
echo "WAN interface:"
echo "    $WAN_IF"

echo
echo "LAN interface:"
echo "    $LAN_IF"

###############################################################################
# 3. RESET FIREWALL / IPSET / NFTABLES
###############################################################################

echo
echo "[3/12] Resetting firewall and IP sets..."

###############################################################################
# Flush iptables
###############################################################################

echo
echo "Flushing iptables..."

iptables -F
iptables -X

iptables -t nat -F
iptables -t mangle -F

###############################################################################
# Reset default policies
###############################################################################

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

###############################################################################
# Flush existing ipsets
###############################################################################

echo
echo "Flushing existing ipsets..."

ipset flush 2>/dev/null || true

###############################################################################
# Flush nftables
#
# WARNING:
#
# This removes ALL nftables rules on the machine.
#
###############################################################################

echo
echo "Flushing nftables..."

nft flush ruleset 2>/dev/null || true

###############################################################################
# Destroy old allowed_sites
###############################################################################

echo
echo "Destroying old allowed_sites set..."

ipset destroy "$IPSET_NAME" 2>/dev/null || true

echo
echo "Firewall reset completed."

###############################################################################
# 4. INSTALL REQUIRED PACKAGES
###############################################################################

echo
echo "[4/12] Installing required packages..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    dnsmasq \
    hostapd \
    iptables \
    ipset \
    nftables \
    tcpdump \
    curl

###############################################################################
# 5. LOAD KERNEL MODULES
###############################################################################

echo
echo "[5/12] Loading kernel modules..."

modprobe ip_set || true
modprobe ip_set_hash_ip || true
modprobe xt_set || true
modprobe nf_nat || true
modprobe nf_conntrack || true

###############################################################################
# CREATE NEW ALLOWED IPSET
###############################################################################

echo
echo "Creating new ipset: $IPSET_NAME"

ipset create "$IPSET_NAME" \
    hash:ip \
    family inet \
    hashsize 4096 \
    maxelem 65536 \
    timeout 3600

echo
echo "Created:"
echo "    $IPSET_NAME"

###############################################################################
# 6. ENABLE IPV4 FORWARDING
###############################################################################

echo
echo "[6/12] Enabling IPv4 forwarding..."

sysctl -w net.ipv4.ip_forward=1

if grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf 2>/dev/null; then

    sed -i \
        's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' \
        /etc/sysctl.conf

else

    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

fi

###############################################################################
# DISABLE IPV6 FORWARDING
###############################################################################

echo
echo "Disabling IPv6 forwarding..."

sysctl -w net.ipv6.conf.all.forwarding=0
sysctl -w net.ipv6.conf.default.forwarding=0

if grep -q '^net.ipv6.conf.all.forwarding=' /etc/sysctl.conf 2>/dev/null; then

    sed -i \
        's/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=0/' \
        /etc/sysctl.conf

else

    echo 'net.ipv6.conf.all.forwarding=0' >> /etc/sysctl.conf

fi

if grep -q '^net.ipv6.conf.default.forwarding=' /etc/sysctl.conf 2>/dev/null; then

    sed -i \
        's/^net.ipv6.conf.default.forwarding=.*/net.ipv6.conf.default.forwarding=0/' \
        /etc/sysctl.conf

else

    echo 'net.ipv6.conf.default.forwarding=0' >> /etc/sysctl.conf

fi

###############################################################################
# 7. CONFIGURE LAN INTERFACE
###############################################################################

echo
echo "[7/12] Configuring LAN interface..."

ip link set "$LAN_IF" down || true

ip addr flush dev "$LAN_IF"

ip addr add "${HOTSPOT_IP}/24" dev "$LAN_IF"

ip link set "$LAN_IF" up

echo
echo "LAN configuration:"
echo "------------------------------------------------------------"

ip -4 addr show "$LAN_IF"

###############################################################################
# 8. CREATE DNSMASQ CONFIGURATION
###############################################################################

echo
echo "[8/12] Creating dnsmasq configuration..."

mkdir -p /etc/dnsmasq.d

###############################################################################
# Remove previous router configuration
###############################################################################

rm -f "$DNSMASQ_CONFIG"

###############################################################################
# Create base dnsmasq configuration
###############################################################################

cat > "$DNSMASQ_CONFIG" <<EOF
###############################################################################
# Controlled Router dnsmasq configuration
###############################################################################

interface=${LAN_IF}

bind-interfaces

###############################################################################
# DHCP
###############################################################################

dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h

###############################################################################
# Gateway
###############################################################################

dhcp-option=3,${HOTSPOT_IP}

###############################################################################
# DNS server provided to clients
###############################################################################

dhcp-option=6,${HOTSPOT_IP}

###############################################################################
# Upstream DNS
###############################################################################

server=${DNS1}
server=${DNS2}

###############################################################################
# Allowed domains
###############################################################################

EOF

###############################################################################
# CREATE TEMPORARY CLEAN WHITE-LIST
#
# This replaces the Bash process-substitution that caused your error.
###############################################################################

CLEAN_LIST=$(mktemp)

trap 'rm -f "$CLEAN_LIST"' EXIT

grep -Ev '^[[:space:]]*(#|$)' "$WHITE_LIST_FILE" \
    | sed 's/[[:space:]]*$//' \
    | sed 's/^[[:space:]]*//' \
    | sort -u \
    > "$CLEAN_LIST"

###############################################################################
# READ WHITE-LIST
###############################################################################

DOMAIN_COUNT=0

while IFS= read -r DOMAIN
do

    ###########################################################################
    # Skip empty lines
    ###########################################################################

    if [ -z "$DOMAIN" ]; then
        continue
    fi

    ###########################################################################
    # Validate domain
    ###########################################################################

    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then

        echo
        echo "WARNING: Invalid domain skipped:"
        echo "    $DOMAIN"

        continue

    fi

    ###########################################################################
    # Add domain to dnsmasq ipset
    ###########################################################################

    echo "ipset=/${DOMAIN}/${IPSET_NAME}" >> "$DNSMASQ_CONFIG"

    DOMAIN_COUNT=$((DOMAIN_COUNT + 1))

done < "$CLEAN_LIST"

###############################################################################
# DNSMASQ LOGGING
###############################################################################

cat >> "$DNSMASQ_CONFIG" <<EOF

###############################################################################
# Logging
###############################################################################

log-queries
log-dhcp
log-facility=/var/log/dnsmasq.log

EOF

###############################################################################
# DISPLAY GENERATED DNSMASQ RULES
###############################################################################

echo
echo "Generated dnsmasq whitelist:"
echo "------------------------------------------------------------"

grep "^ipset=" "$DNSMASQ_CONFIG" || true

echo "------------------------------------------------------------"

echo
echo "Number of allowed domains: $DOMAIN_COUNT"

###############################################################################
# TEST DNSMASQ CONFIGURATION
###############################################################################

echo
echo "Testing dnsmasq configuration..."

dnsmasq --test

###############################################################################
# 9. CONFIGURE HOSTAPD
###############################################################################

echo
echo "[9/12] Configuring hostapd..."

cat > /etc/hostapd/hostapd.conf <<EOF
interface=${LAN_IF}

driver=nl80211

ssid=${SSID}

hw_mode=g

channel=6

wmm_enabled=1

auth_algs=1

wpa=2

wpa_key_mgmt=WPA-PSK

wpa_passphrase=${PASSWORD}

rsn_pairwise=CCMP
EOF

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

###############################################################################
# 10. CONFIGURE IPTABLES
###############################################################################

echo
echo "[10/12] Configuring iptables..."

###############################################################################
# DEFAULT POLICIES
###############################################################################

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD DROP

###############################################################################
# LOOPBACK
###############################################################################

iptables -A INPUT \
    -i lo \
    -j ACCEPT

###############################################################################
# ESTABLISHED / RELATED INPUT
###############################################################################

iptables -A INPUT \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

###############################################################################
# ESTABLISHED / RELATED OUTPUT
###############################################################################

iptables -A OUTPUT \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

###############################################################################
# ESTABLISHED / RELATED FORWARD
###############################################################################

iptables -A FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

###############################################################################
# DHCP
###############################################################################

iptables -A INPUT \
    -i "$LAN_IF" \
    -p udp \
    --dport 67 \
    -j ACCEPT

###############################################################################
# DNS TO ROUTER
###############################################################################

iptables -A INPUT \
    -i "$LAN_IF" \
    -p udp \
    --dport 53 \
    -j ACCEPT

iptables -A INPUT \
    -i "$LAN_IF" \
    -p tcp \
    --dport 53 \
    -j ACCEPT

###############################################################################
# ROUTER HTTP
###############################################################################

iptables -A INPUT \
    -i "$LAN_IF" \
    -p tcp \
    --dport 80 \
    -j ACCEPT

###############################################################################
# ROUTER HTTPS
###############################################################################

iptables -A INPUT \
    -i "$LAN_IF" \
    -p tcp \
    --dport 443 \
    -j ACCEPT

###############################################################################
# FORCE ALL LAN DNS TO ROUTER
###############################################################################

iptables -t nat -A PREROUTING \
    -i "$LAN_IF" \
    -p udp \
    --dport 53 \
    -j REDIRECT \
    --to-ports 53

iptables -t nat -A PREROUTING \
    -i "$LAN_IF" \
    -p tcp \
    --dport 53 \
    -j REDIRECT \
    --to-ports 53

###############################################################################
# BLOCK DIRECT EXTERNAL DNS
###############################################################################

iptables -A FORWARD \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -p udp \
    --dport 53 \
    -j REJECT

iptables -A FORWARD \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -p tcp \
    --dport 53 \
    -j REJECT

###############################################################################
# NON-ALLOWED HTTP
#
# Destination is NOT in allowed_sites.
#
# Client -> Internet:80
#
# becomes:
#
# Client -> Router:80
###############################################################################

iptables -t nat -A PREROUTING \
    -i "$LAN_IF" \
    -p tcp \
    --dport 80 \
    -m set ! --match-set "$IPSET_NAME" dst \
    -j REDIRECT \
    --to-ports 80

###############################################################################
# NON-ALLOWED HTTPS
#
# Destination is NOT in allowed_sites.
#
# Client -> Internet:443
#
# becomes:
#
# Client -> Router:443
###############################################################################

iptables -t nat -A PREROUTING \
    -i "$LAN_IF" \
    -p tcp \
    --dport 443 \
    -m set ! --match-set "$IPSET_NAME" dst \
    -j REDIRECT \
    --to-ports 443

###############################################################################
# ALLOW WHITELISTED DESTINATION IPs
###############################################################################

iptables -A FORWARD \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -m set \
    --match-set "$IPSET_NAME" dst \
    -j ACCEPT

###############################################################################
# NAT / MASQUERADE
###############################################################################

iptables -t nat -A POSTROUTING \
    -o "$WAN_IF" \
    -j MASQUERADE

###############################################################################
# RETURN TRAFFIC
###############################################################################

iptables -A FORWARD \
    -i "$WAN_IF" \
    -o "$LAN_IF" \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

###############################################################################
# LOG BLOCKED FORWARD TRAFFIC
###############################################################################

iptables -A FORWARD \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -m limit \
    --limit 5/min \
    --limit-burst 10 \
    -j LOG \
    --log-prefix "ROUTER-BLOCKED: " \
    --log-level 4

###############################################################################
# 11. RESTART SERVICES
###############################################################################

echo
echo "[11/12] Restarting services..."

###############################################################################
# DNSMASQ
###############################################################################

systemctl enable dnsmasq

systemctl restart dnsmasq

###############################################################################
# HOSTAPD
###############################################################################

systemctl unmask hostapd || true

systemctl enable hostapd

systemctl restart hostapd

###############################################################################
# 12. SAVE FIREWALL AND DIAGNOSTICS
###############################################################################

echo
echo "[12/12] Saving firewall configuration..."

if command -v netfilter-persistent >/dev/null 2>&1; then

    netfilter-persistent save

fi

###############################################################################
# DIAGNOSTICS
###############################################################################

echo
echo
echo "============================================================"
echo "              ROUTER SETUP COMPLETE"
echo "============================================================"

echo
echo "------------------------------------------------------------"
echo "Configuration"
echo "------------------------------------------------------------"

echo
echo "WAN:"
echo "    $WAN_IF"

echo
echo "LAN:"
echo "    $LAN_IF"

echo
echo "Router IP:"
echo "    $HOTSPOT_IP"

echo
echo "LAN Network:"
echo "    $HOTSPOT_CIDR"

echo
echo "DHCP Range:"
echo "    $DHCP_START - $DHCP_END"

echo
echo "SSID:"
echo "    $SSID"

echo
echo "Whitelist:"
echo "    $WHITE_LIST_FILE"

###############################################################################
# IPV4 FORWARDING
###############################################################################

echo
echo "------------------------------------------------------------"
echo "IPv4 Forwarding"
echo "------------------------------------------------------------"

cat /proc/sys/net/ipv4/ip_forward

###############################################################################
# IPV6 FORWARDING
###############################################################################

echo
echo "------------------------------------------------------------"
echo "IPv6 Forwarding"
echo "------------------------------------------------------------"

cat /proc/sys/net/ipv6/conf/all/forwarding

###############################################################################
# DEFAULT ROUTE
###############################################################################

echo
echo "------------------------------------------------------------"
echo "Default Route"
echo "------------------------------------------------------------"

ip route | grep default || true

###############################################################################
# IPSET
###############################################################################

echo
echo "------------------------------------------------------------"
echo "Allowed IP Set"
echo "------------------------------------------------------------"

ipset list "$IPSET_NAME" || true

###############################################################################
# NAT PREROUTING
###############################################################################

echo
echo "------------------------------------------------------------"
echo "NAT PREROUTING"
echo "------------------------------------------------------------"

iptables -t nat -L PREROUTING -n -v --line-numbers

###############################################################################
# FORWARD
###############################################################################

echo
echo "------------------------------------------------------------"
echo "FORWARD"
echo "------------------------------------------------------------"

iptables -L FORWARD -n -v --line-numbers

###############################################################################
# NAT POSTROUTING
###############################################################################

echo
echo "------------------------------------------------------------"
echo "NAT POSTROUTING"
echo "------------------------------------------------------------"

iptables -t nat -L POSTROUTING -n -v --line-numbers

###############################################################################
# DNSMASQ STATUS
###############################################################################

echo
echo "------------------------------------------------------------"
echo "DNSMASQ STATUS"
echo "------------------------------------------------------------"

systemctl --no-pager --full status dnsmasq | head -20 || true

###############################################################################
# HOSTAPD STATUS
###############################################################################

echo
echo "------------------------------------------------------------"
echo "HOSTAPD STATUS"
echo "------------------------------------------------------------"

systemctl --no-pager --full status hostapd | head -20 || true

###############################################################################
# FINAL
###############################################################################

echo
echo "============================================================"
echo "                    ROUTER READY"
echo "============================================================"

echo
echo "SSID:"
echo "    $SSID"

echo
echo "Password:"
echo "    $PASSWORD"

echo
echo "Gateway:"
echo "    $HOTSPOT_IP"

echo
echo "DNS:"
echo "    $HOTSPOT_IP"

echo
echo "Whitelist:"
echo "    $WHITE_LIST_FILE"

echo
echo "Policy:"
echo
echo "    Allowed IPs        -> Internet"
echo "    Blocked HTTP :80   -> Router :80"
echo "    Blocked HTTPS:443  -> Router :443"
echo "    External DNS       -> Blocked"
echo "    IPv6 forwarding    -> Disabled"

echo
echo "============================================================"