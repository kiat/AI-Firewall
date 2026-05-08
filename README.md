# AI-Firewall
This project is a simple Linux LAN/WAN Firewall scripts for classrooms. It can be used in a classroom setting to allow approved websites and block common Generative AI services during computer based assessements in a classroom settings. 



## What these scripts do

- `check_ubuntu_packages.sh`
  - Checks for required Ubuntu packages and installs missing ones.
  - Re-runs itself with `sudo` if needed.
- `setup_system_settings.sh`
  - Validates LAN/WAN interfaces exist.
  - Brings interfaces up, sets LAN IP/CIDR, attempts WAN DHCP when needed.
  - Enables IPv4 forwarding.
  - Writes base DHCP/DNS config to `/etc/dnsmasq.d/ai-firewall-base.conf`.
- `setup_firewall.sh`
  - Validates LAN/WAN interfaces and input files.
  - Loads allow-list domains into `ipset` via `dnsmasq`.
  - Blocks listed AI domains by writing null-address records in `dnsmasq`.
  - Resets and applies `iptables` rules (backs up current rules first).
  - Writes policy to `/etc/dnsmasq.d/ai-firewall-policy.conf`.
- `whitelist.txt`
  - Allowed domains/IPs, one entry per line (domain, IPv4, or IPv4 CIDR).
- `blocked_ai_domains.txt`
  - Blocked AI domains, one domain per line.

## Fresh Ubuntu setup (recommended order)

1. On the firewall host, clone this repo and enter it.
2. Identify your interface names:

```bash
ip -br link
```

3. Review domain policy files:
   - Edit `whitelist.txt` for allowed domains.
   - Edit `blocked_ai_domains.txt` for blocked AI domains.
   - `*.example.com` is accepted and normalized to `example.com`.
4. Install/check required packages:

```bash
./check_ubuntu_packages.sh
```

5. Run system setup with your real interfaces and LAN settings:

```bash
sudo LAN_IF=enp3s0 WAN_IF=enp2s0 LAN_CIDR=10.20.30.1/24 DHCP_START=10.20.30.50 DHCP_END=10.20.30.200 DHCP_LEASE=12h ./setup_system_settings.sh
```

6. Apply firewall policy:

```bash
sudo LAN_IF=enp3s0 WAN_IF=enp2s0 ./setup_firewall.sh
```

7. Point student devices to this firewall for DHCP/DNS (or set DNS manually to the firewall LAN IP) so filtering is enforced.

## Important notes

- Run setup scripts as root (`sudo`).
- Default interface placeholders are `LAN` and `WAN`; you must override them unless your system uses those exact names.
- `setup_firewall.sh` flushes existing `iptables` rules and saves a backup at `/etc/iptables/ai-firewall.backup.v4`.
- Both setup scripts expect `dnsmasq` to be managed by `systemctl`.

## Note for Instructors Using Canvas or Blackboard LMS

If you use **Canvas** or **Blackboard** (or a similar LMS) to administer in-class assessments such as quizzes or tests, configure the quiz to accept connections **only from the IP address of the AI-Firewall router machine** (the host where you installed this system).

This ensures that students must route their traffic through the firewall to reach the quiz, so the AI-blocking and domain-allow-listing policies are enforced for the entire assessment window.

**Steps (Canvas example):**

1. Open the quiz editor and go to the **Details** tab.
2. Locate the **IP Address Filter** (or *Allowed IPs*) setting.
3. Enter the **WAN IP address of the firewall router** — for example `128.83.120.168` — as the only allowed address. If your institution uses load balancers or proxies, you may need to add those IPs as well, or use CIDR notation (e.g. `10.20.30.0/24`). Consult your network administrator if you are unsure.
4. Save the quiz.

Students connecting from outside the filtered network will be denied access to the quiz, ensuring all their traffic is subject to the firewall's AI-blocking and domain-allow-listing policies.

> **Blackboard:** Go to *Test Options → IP Address Restrictions* and add the same firewall LAN IP.

![Canvas Quiz IP Filtering](ip-filters-2-4.png)
