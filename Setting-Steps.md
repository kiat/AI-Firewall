# Ubuntu Linux WiFi Router + Hotspot + Firewall Setup

This guide explains how to configure an Ubuntu Linux machine with two WiFi adapters to work as:

- A WiFi router
- A hotspot access point
- A DHCP server
- A firewall
- A restricted Internet gateway

## Network Design

- `wlp3s0`
  - Connects to Internet
  - Gets IP via DHCP
  - Upstream WiFi connection

- `wlx984827c3f4db`
  - Creates WiFi hotspot
  - Provides local DHCP
  - Local subnet: `10.10.0.0/24`

---

# Architecture

```text
                Internet
                    |
            [ WiFi Network ]
                    |
              wlp3s0
          Ubuntu Router Box
      NAT + DHCP + Firewall
              wlx984827c3f4db
                    |
          Hotspot Clients
         10.10.0.0/24 network
```

---

# STEP 1 — Verify WiFi Adapter Supports AP Mode

Run:

```bash
iw list | grep -A 20 "Supported interface modes"
```

You must see:

```text
AP
```

If `AP` is missing, the WiFi card cannot create a hotspot.

---

# STEP 2 — Install Required Packages

```bash
sudo apt update

sudo apt install -y \
network-manager \
dnsmasq \
nftables \
tcpdump
```

Enable nftables:

```bash
sudo systemctl enable nftables
sudo systemctl start nftables
```

---

# STEP 3 — Create Hotspot Using NetworkManager

## Create Hotspot Connection

```bash
sudo nmcli connection add \
type wifi \
ifname wlx984827c3f4db \
con-name hotspot \
autoconnect yes \
ssid MyRestrictedWifi
```

---

## Configure Access Point Mode

```bash
sudo nmcli connection modify hotspot 802-11-wireless.mode ap
```

---

## Configure WPA2 Password

```bash
sudo nmcli connection modify hotspot wifi-sec.key-mgmt wpa-psk

sudo nmcli connection modify hotspot wifi-sec.psk "StrongPassword123"
```

---

## Configure Shared IPv4

```bash
sudo nmcli connection modify hotspot ipv4.method shared
```

---

## Configure Local Router Address

```bash
sudo nmcli connection modify hotspot ipv4.addresses 10.10.0.1/24
```

---

## Start Hotspot

```bash
sudo nmcli connection up hotspot
```

---

# STEP 4 — Verify Interfaces

Run:

```bash
ip addr
```

Expected:

```text
wlp3s0            -> Internet IP address
wlx984827c3f4db  -> 10.10.0.1
```

---

# STEP 5 — Enable IP Forwarding

## Temporary Enable

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

---

## Permanent Enable

Edit:

```bash
sudo nano /etc/sysctl.conf
```

Add:

```text
net.ipv4.ip_forward=1
```

Apply:

```bash
sudo sysctl -p
```

Verify:

```bash
cat /proc/sys/net/ipv4/ip_forward
```

Expected output:

```text
1
```

---

# STEP 6 — Verify Routing

Run:

```bash
ip route
```

Expected routes:

```text
default via ...
10.10.0.0/24 dev wlx984827c3f4db
```

---

# STEP 7 — Configure dnsmasq

Stop any running instance first:

```bash
sudo systemctl stop dnsmasq
```

---

## Edit Configuration

```bash
sudo nano /etc/dnsmasq.conf
```

Replace contents with:

```ini
interface=wlx984827c3f4db

dhcp-range=10.10.0.10,10.10.0.100,255.255.255.0,12h

server=1.1.1.1

address=/google.com/142.250.190.14
address=/wikipedia.org/208.80.154.224
address=/python.org/151.101.0.223
address=/github.com/140.82.113.4
```

---

## Start dnsmasq

```bash
sudo systemctl restart dnsmasq

sudo systemctl enable dnsmasq
```

---

# STEP 8 — Configure Firewall Using nftables

Edit:

```bash
sudo nano /etc/nftables.conf
```

Replace contents with:

```nft
flush ruleset

table inet filter {

    chain forward {

        type filter hook forward priority 0;

        policy drop;

        ct state established,related accept

        #
        # Allow DNS only to local router
        #

        ip saddr 10.10.0.0/24 ip daddr 10.10.0.1 udp dport 53 accept
        ip saddr 10.10.0.0/24 ip daddr 10.10.0.1 tcp dport 53 accept

        #
        # Allow selected websites only
        #

        ip saddr 10.10.0.0/24 ip daddr 142.250.190.14 tcp dport {80,443} accept
        ip saddr 10.10.0.0/24 ip daddr 208.80.154.224 tcp dport {80,443} accept
        ip saddr 10.10.0.0/24 ip daddr 151.101.0.223 tcp dport {80,443} accept
        ip saddr 10.10.0.0/24 ip daddr 140.82.113.4 tcp dport {80,443} accept

        #
        # Block all other forwarding traffic
        #
    }
}

table ip nat {

    chain postrouting {

        type nat hook postrouting priority 100;

        oifname "wlp3s0" masquerade
    }
}
```

---

# STEP 9 — Apply Firewall Rules

```bash
sudo nft -f /etc/nftables.conf
```

Verify:

```bash
sudo nft list ruleset
```

---

# STEP 10 — Connect Client Devices

Connect:
- phone
- laptop
- tablet

to:

```text
MyRestrictedWifi
```

Expected IP:

```text
10.10.0.x
```

---

# STEP 11 — Test Connectivity

## Test Router Access

```bash
ping 10.10.0.1
```

---

## Test Internet Access

```bash
ping 8.8.8.8
```

---

## Test DNS

```bash
ping google.com
```

---

# STEP 12 — Verify Website Filtering

## Allowed Website

```bash
curl https://wikipedia.org
```

Should work.

---

## Blocked Website

```bash
curl https://facebook.com
```

Should fail.

---

# STEP 13 — Monitor Traffic

## Monitor Hotspot Interface

```bash
sudo tcpdump -i wlx984827c3f4db
```

---

## Monitor Internet Interface

```bash
sudo tcpdump -i wlp3s0
```

If packets enter one interface and leave the other, routing works correctly.

---

# STEP 14 — View Connected Clients

```bash
iw dev wlx984827c3f4db station dump
```

---

# STEP 15 — Check NAT Rules

```bash
sudo nft list ruleset
```

---

# STEP 16 — Check DHCP Leases

```bash
cat /var/lib/misc/dnsmasq.leases
```

---

# STEP 17 — Check DNS Status

```bash
resolvectl status
```

---

# GNOME NetworkManager Alternative

You can also create the hotspot graphically:

```text
Settings -> WiFi -> Mobile Hotspot
```

However:

- GUI hotspot usually uses:
  - `10.42.0.0/24`
- less flexible
- harder to customize firewall rules

Using `nmcli` is recommended for stable router configurations.

---

# Important HTTPS Filtering Limitation

Modern HTTPS websites:

- use CDNs
- share IP addresses
- frequently change IPs

Therefore:

- IP filtering is imperfect
- domain filtering may not always work reliably

For advanced filtering consider:

- Squid proxy
- Pi-hole
- AdGuard Home
- Transparent proxy setup

---

# Useful Commands Summary

## Show Interfaces

```bash
ip addr
```

---

## Show Routes

```bash
ip route
```

---

## Show Firewall Rules

```bash
sudo nft list ruleset
```

---

## Show Connections

```bash
nmcli connection show
```

---

## Restart Hotspot

```bash
sudo nmcli connection down hotspot

sudo nmcli connection up hotspot
```

---

# Recommended Final Setup

Recommended architecture:

- `wlp3s0`
  - Internet connection

- `wlx984827c3f4db`
  - Hotspot access point

- `NetworkManager`
  - hotspot management

- `dnsmasq`
  - DHCP + DNS

- `nftables`
  - NAT + firewall

- optional:
  - Squid proxy
  - Pi-hole
  - AdGuard Home

This setup works well on Ubuntu 24.x and Ubuntu 25.x.
