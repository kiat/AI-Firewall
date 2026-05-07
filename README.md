# AI-Firewall

A Linux LAN/WAN classroom firewall setup that allows only approved websites and blocks common Generative AI services.

## Requirements

- Ubuntu firewall host with two interfaces (LAN side + WAN side)
- Student devices should use DHCP from this firewall so DNS requests are enforced through `dnsmasq`

## Files

- `setup_system_settings.sh`: configures interfaces, IP forwarding, package dependencies, and base `dnsmasq` DHCP settings
- `setup_firewall.sh`: configures domain policy, `ipset`, and `iptables` firewall rules
- `whitelist.txt`: allow-list domains, one domain per line

## Usage

1. Edit interface names at the top of each script **or** set environment variables when running the scripts.
2. Update `whitelist.txt` with allowed domains (one per line). Use `example.com` to match both root and subdomains; `*.example.com` is also accepted and normalized.
3. Run both scripts as root:

```bash
sudo ./setup_system_settings.sh
sudo ./setup_firewall.sh
```

Optional environment-variable overrides:

```bash
sudo LAN_IF=enp3s0 WAN_IF=enp2s0 LAN_CIDR=10.10.10.1/24 DHCP_START=10.10.10.50 DHCP_END=10.10.10.200 ./setup_system_settings.sh
sudo LAN_IF=enp3s0 WAN_IF=enp2s0 WHITELIST_FILE=/path/to/whitelist.txt ./setup_firewall.sh
```
