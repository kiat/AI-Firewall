#!/usr/bin/env bash
set -euo pipefail

REQUIRED_PACKAGES=(
  iproute2
  iptables
  ipset
  dnsmasq
  isc-dhcp-client
)

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
  echo "This script requires Ubuntu or another apt-based distribution." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install missing packages. Re-run this script as root." >&2
    exit 1
  fi

  echo "Re-running with sudo to check and install required Ubuntu packages..."
  exec sudo --preserve-env=DEBIAN_FRONTEND "$0" "$@"
fi

missing_packages=()

echo "Checking required Ubuntu packages..."
for package_name in "${REQUIRED_PACKAGES[@]}"; do
  if dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q '^install ok installed$'; then
    echo "  - ${package_name}: installed"
  else
    echo "  - ${package_name}: missing"
    missing_packages+=("${package_name}")
  fi
done

if [[ "${#missing_packages[@]}" -eq 0 ]]; then
  echo "All required Ubuntu packages are already installed."
  exit 0
fi

echo "Installing missing packages: ${missing_packages[*]}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
apt-get update
apt-get install -y "${missing_packages[@]}"

echo "Required Ubuntu packages are installed."
