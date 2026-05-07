# AI-Firewall

A Linux LAN/WAN classroom firewall setup that allows only approved websites (Canvas/Instructure, Python.org, Wikipedia) and blocks common Generative AI services (ChatGPT, Claude, Copilot).

## Usage

Run on Ubuntu as root on a machine with two interfaces:

- `LAN`: connected to student devices
- `WAN`: connected to public internet

```bash
sudo ./setup_firewall.sh
```

Optional overrides:

```bash
sudo LAN_IF=enp3s0 WAN_IF=enp2s0 LAN_CIDR=10.10.10.1/24 DHCP_START=10.10.10.50 DHCP_END=10.10.10.200 ./setup_firewall.sh
```

## What the script configures

- Enables IPv4 forwarding
- Configures LAN IP and DHCP/DNS service through `dnsmasq`
- Uses DNS policy to block known GenAI domains (`openai.com`, `chatgpt.com`, `claude.ai`, `anthropic.com`, `copilot.microsoft.com`, `githubcopilot.com`)
- Builds an allow-list using `ipset` for:
  - `canvas.instructure.com`
  - `instructure.com`
  - `python.org`
  - `wikipedia.org`
- Applies `iptables` forwarding and NAT rules so LAN clients can reach only allow-listed destinations

Notes:
- Students must use DHCP from this firewall so their DNS resolver is the firewall (`dnsmasq`).
- Allow-listed IPs are populated from DNS queries; after startup, the first DNS resolution for each allowed site seeds `ipset`.
- Optional warm-up (on the firewall host): `getent ahostsv4 canvas.instructure.com instructure.com python.org wikipedia.org`
