#!/usr/bin/env bash
set -Eeuo pipefail

# Run inside the appliance build root. This creates a generalized simulator image;
# it intentionally does NOT bake in the target fake-Internet subnet/address.

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends inetsim qemu-guest-agent ca-certificates iproute2 netplan.io

INET_VER="$(dpkg-query -W -f='${Version}' inetsim)"
[[ "$INET_VER" == 1.3.2* ]] || { echo "Unexpected INetSim package: $INET_VER" >&2; exit 20; }
NETDNS_VER="$(perl -MNet::DNS -e 'print $Net::DNS::VERSION')"
[[ "$NETDNS_VER" == 1.44* ]] || { echo "Unexpected Net::DNS version: $NETDNS_VER" >&2; exit 21; }

DNS_PM=/usr/share/perl5/INetSim/DNS.pm
[[ -f "$DNS_PM.pre-netdns-fix" ]] || cp -a "$DNS_PM" "$DNS_PM.pre-netdns-fix"
if grep -qE '^[[:space:]]*\$server->main_loop;[[:space:]]*$' "$DNS_PM"; then
  sed -i 's|^[[:space:]]*\$server->main_loop;[[:space:]]*$|        while (1) { $server->loop_once(10); }|' "$DNS_PM"
elif ! grep -q 'loop_once(10)' "$DNS_PM"; then
  echo "Unsupported INetSim DNS.pm layout" >&2
  exit 22
fi

echo 'net.ipv4.ip_unprivileged_port_start=53' >/etc/sysctl.d/99-inetsim-lowports.conf
systemctl enable qemu-guest-agent.service
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

# This appliance is configured through QEMU Guest Agent, not cloud metadata.
# Disable cloud-init so it cannot overwrite deploy-time MAC-based networking.
touch /etc/cloud/cloud-init.disabled

# The deployment executes this through QEMU Guest Agent after both NICs exist.
install -m 0755 /usr/local/src/cape-inetsim-guest-configure /usr/local/sbin/cape-inetsim-guest-configure

# Do not bind/start simulator services during image construction. Deployment enables it.
systemctl disable inetsim.service >/dev/null 2>&1 || true

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
