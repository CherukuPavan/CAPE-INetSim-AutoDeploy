#!/bin/sh
set -eu

# Run inside the appliance build root. This creates a generalized simulator
# image; it intentionally does NOT bake in the target fake-Internet
# subnet/address. Keep this script POSIX-sh compatible because virt-customize
# executes --run scripts through /bin/sh inside the guest.

export DEBIAN_FRONTEND=noninteractive

# Cloud images normally point /etc/resolv.conf at systemd-resolved's runtime
# stub. That daemon is not running inside virt-customize's chroot. When the
# builder supplies a temporary DNS proxy, use it only for package installation
# and restore the normal systemd-resolved symlink before sealing the image.
if [ -f /etc/cape-inetsim-build-dns ]; then
  BUILD_DNS="$(cat /etc/cape-inetsim-build-dns)"
  rm -f /etc/resolv.conf
  printf 'nameserver %s\noptions timeout:2 attempts:3\n' "$BUILD_DNS" >/etc/resolv.conf
fi

apt-get update
apt-get install -y --no-install-recommends inetsim qemu-guest-agent ca-certificates iproute2 netplan.io

INET_VER="$(dpkg-query -W -f='${Version}' inetsim)"
case "$INET_VER" in
  1.3.2*) ;;
  *) echo "Unexpected INetSim package: $INET_VER" >&2; exit 20 ;;
esac

NETDNS_VER="$(perl -MNet::DNS -e 'print $Net::DNS::VERSION')"
case "$NETDNS_VER" in
  1.44*) ;;
  *) echo "Unexpected Net::DNS version: $NETDNS_VER" >&2; exit 21 ;;
esac

DNS_PM=/usr/share/perl5/INetSim/DNS.pm
if [ ! -f "$DNS_PM.pre-netdns-fix" ]; then
  cp -a "$DNS_PM" "$DNS_PM.pre-netdns-fix"
fi
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

if [ -f /etc/cape-inetsim-build-dns ]; then
  rm -f /etc/cape-inetsim-build-dns /etc/resolv.conf
  ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
