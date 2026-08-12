# Find out the LAN and WAN interface names and set the variables. 
# use the commands 
# ip a 
# or if net-tools is installed "sudo apt install net-tools"
# ifconfig -a 

# manual ip setup 
# sudo ip addr add 10.10.0.1/24 dev eth0


# Update and Install packages. 

# sudo apt update

# sudo apt install -y \
# network-manager \
# dnsmasq \
# hostapd \
# nftables \
# tcpdump \
# ipset

sudo modprobe ip_set
sudo modprobe ip_set_hash_ip
sudo modprobe xt_set


#!/bin/bash
###############################################################################
# Ubuntu WiFi Router Setup Script
#
# Purpose:
# Configure a Linux Ubuntu machine as a WiFi router:
#
# Internet <--- wlp3s0
# |
# |
# Ubuntu
# |
# |
# Hotspot  <--- wlx984827c3f4db
#
# Features:
# - DHCP via dnsmasq
# - WiFi Access Point via hostapd
# - NAT via iptables
# - IP forwarding
#

# Assumptions:
# - wlp3s0 already connects to Internet
# - hostapd and dnsmasq are installed
# - hotspot adapter supports AP mode

#

###############################################################################

set -e

###############################################################################

# Configuration

###############################################################################

WAN_IF="wlp3s0"
LAN_IF="wlx984827c3f4db"

HOTSPOT_IP="10.10.0.1"
HOTSPOT_NETMASK="255.255.255.0"

DHCP_START="10.10.0.2"
DHCP_END="10.10.0.200"

SSID="CS-Test"
PASSWORD="StrongPassword123"

###############################################################################

# Verify root

###############################################################################

if [ "$EUID" -ne 0 ]; then
echo "Please run as root:"
echo "sudo $0"
exit 1
fi

echo "===================================================="
echo "Ubuntu WiFi Router Setup"
echo "===================================================="

###############################################################################

# Verify interfaces exist

###############################################################################

echo
echo "[1/10] Verifying interfaces..."

ip link show "$WAN_IF" >/dev/null 2>&1 || {
echo "ERROR: Interface $WAN_IF not found."
exit 1
}

ip link show "$LAN_IF" >/dev/null 2>&1 || {
echo "ERROR: Interface $LAN_IF not found."
exit 1
}

echo "Interfaces found."

###############################################################################

# Reset iptables

###############################################################################

echo
echo "[2/10] Resetting iptables..."

sudo iptables -F

sudo ipset flush
sudo ipset destroy allowed_sites --exist

sudo ipset create allowed_sites hash:ip

for ip in $(dig +short python.org); do
    sudo ipset add allowed_sites $ip
done

for ip in $(dig +short wikipedia.org); do
    sudo ipset add allowed_sites $ip
done

for ip in $(dig +short apache.org); do
    sudo ipset add allowed_sites $ip
done

for ip in $(dig +short utexas.edu); do
    sudo ipset add allowed_sites $ip
done

sudo ipset add allowed_sites 8.8.8.8




iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# iptables -P INPUT ACCEPT
# iptables -P OUTPUT ACCEPT
# iptables -P FORWARD ACCEPT

# Default Drop 
iptables -P FORWARD DROP

iptables -A FORWARD \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

    
# # use the list of allowed_sites. 
# iptables -A FORWARD \
#     -i "$WAN_IF" \
#     -m set --match-set allowed_sites dst \
#     -j ACCEPT


# iptables -A FORWARD \
#     -i "$WAN_IF" \
#     -p udp --dport 53 \
#     -d 10.10.0.1 \
#     -j ACCEPT

# iptables -A FORWARD \
#     -i "$WAN_IF" \
#     -p tcp --dport 53 \
#     -d 10.10.0.1 \
#     -j ACCEPT

iptables -A FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

iptables -A FORWARD \
    -m set \
    --match-set allowed_sites dst \
    -j ACCEPT
# Very important to do prerouting to not let clients bypass dns
iptables -t nat -A PREROUTING \
    -i wlx984827c3f4db \
    -p udp \
    --dport 53 \
    -j REDIRECT \
    --to-port 53

iptables -t nat -A PREROUTING \
    -i wlx984827c3f4db \
    -p tcp \
    --dport 53 \
    -j REDIRECT \
    --to-port 53

iptables -A FORWARD \
    -i "$WAN_IF" \
    -p udp --dport 53 \
    -j DROP

iptables -A FORWARD \
    -i "$WAN_IF" \
    -p tcp --dport 53 \
    -j DROP


echo "iptables reset completed."

###############################################################################

# Enable IP forwarding

###############################################################################

echo
echo "[3/10] Enabling IP forwarding..."

sysctl -w net.ipv4.ip_forward=1

if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

echo "IP forwarding enabled."

###############################################################################

# Configure hotspot interface

###############################################################################

echo
echo "[4/10] Configuring hotspot interface..."

ip link set "$LAN_IF" down || true

ip addr flush dev "$LAN_IF"

ip addr add ${HOTSPOT_IP}/24 dev "$LAN_IF"

ip link set "$LAN_IF" up

echo "Assigned ${HOTSPOT_IP}/24 to ${LAN_IF}"

###############################################################################

# Configure dnsmasq

###############################################################################

echo
echo "[5/10] Creating dnsmasq configuration..."

mkdir -p /etc/dnsmasq.d

cat > /etc/dnsmasq.d/router.conf <<EOF
interface=${LAN_IF}
bind-interfaces

dhcp-range=${DHCP_START},${DHCP_END},12h

dhcp-option=3,${HOTSPOT_IP}
dhcp-option=6,${HOTSPOT_IP}

server=8.8.8.8
server=1.1.1.1

ipset=/canvas.utexas.edu/allowed
ipset=/utexas.instructure.com/allowed
ipset=/login.utexas.edu/allowed
ipset=/utexas.edu/allowed
ipset=/canvas.utexas.edu/allowed


# Allow only these domains


server=/instruction.com/8.8.8.8
server=/utexas.edu/8.8.8.8

server=/canvas.utexas.edu/8.8.8.8
server=/utexas.instructure.com/8.8.8.8
server=/login.utexas.edu/8.8.8.8
server=/utexas.edu/8.8.8.8
server=/duosecurity.com/8.8.8.8
server=/canvaslms.com/8.8.8.8
server=/instructure.com/8.8.8.8
server=/utaustinesl.instructure.com/8.8.8.8

server=/cloudfront.net/8.8.8.8
server=/amazonaws.com/8.8.8.8
server=/s3.amazonaws.com/8.8.8.8
server=/utexas.instructure.com/8.8.8.8

server=/edstem.org/8.8.8.8
server=/us.edstem.org/8.8.8.8
server=/edcdn.net/8.8.8.8

server=/whatismyip.com/8.8.8.8



# Course Specific 
server=/wikipedia.org/8.8.8.8
server=/python.org/8.8.8.8
server=/scikit-learn.org/8.8.8.8

server=/apache.org/8.8.8.8


# Block everything else
address=/#/0.0.0.0

log-queries
log-dhcp
log-facility=/var/log/dnsmasq.log
EOF

echo "dnsmasq configuration written."

###############################################################################

# Configure hostapd

###############################################################################

echo
echo "[6/10] Creating hostapd configuration..."

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

echo "hostapd configuration written."

###############################################################################

# Configure NAT

###############################################################################

echo
echo "[7/10] Configuring NAT..."

iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

iptables -A FORWARD \
    -i "$WAN_IF" \
    -o "$LAN_IF" \
    -m state \
    --state RELATED,ESTABLISHED \
    -j ACCEPT

iptables -A FORWARD \
    -i "$LAN_IF" \
    -o "$WAN_IF" \
    -j ACCEPT


sudo iptables -I FORWARD -i "$LAN_IF" -o "$WAN_IF" -j LOG --log-prefix "HOTSPOT-TRAFFIC: "


# Make sure clients cannot bypass DNS
# Otherwise users can just use 8.8.8.8 manually and bypass your filter.


echo "NAT configured."

###############################################################################

# Save firewall

###############################################################################

echo
echo "[8/10] Saving firewall rules..."

if command -v netfilter-persistent >/dev/null 2>&1; then
netfilter-persistent save
fi

###############################################################################

# Restart services

###############################################################################

echo
echo "[9/10] Restarting services..."

systemctl restart dnsmasq || true

systemctl unmask hostapd || true
systemctl enable hostapd || true
systemctl restart hostapd || true

echo "Services restarted."






###############################################################################

# Diagnostics

###############################################################################

echo
echo "[10/10] Diagnostics"

echo
echo "WAN Interface:"
ip -4 addr show "$WAN_IF"

echo
echo "LAN Interface:"
ip -4 addr show "$LAN_IF"

echo
echo "Default Route:"
ip route | grep default || true

echo
echo "IP Forwarding:"
cat /proc/sys/net/ipv4/ip_forward

echo
echo "dnsmasq Status:"
systemctl --no-pager status dnsmasq | head -15

echo
echo "hostapd Status:"
systemctl --no-pager status hostapd | head -15

echo
echo "===================================================="
echo "Router setup complete."
echo
echo "SSID     : ${SSID}"
echo "Password : ${PASSWORD}"
echo
echo "Clients should receive:"
echo "  IPs     : ${DHCP_START} - ${DHCP_END}"
echo "  Gateway : ${HOTSPOT_IP}"
echo "  DNS     : ${HOTSPOT_IP}"
echo "===================================================="


# sudo ipset list allowed_sites

sudo ipset list

# check it with 
# sudo dmesg -w
# 

