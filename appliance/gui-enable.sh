#!/usr/bin/env bash
set -Eeuo pipefail

MARKER="/etc/cape-inetsim-gui-v1"
GUI_USER="capeinetsim"
export DEBIAN_FRONTEND=noninteractive

if [[ -f "$MARKER" ]] &&
   command -v startxfce4 >/dev/null 2>&1 &&
   systemctl list-unit-files lightdm.service >/dev/null 2>&1; then
  systemctl enable lightdm.service >/dev/null 2>&1 || true
  systemctl set-default graphical.target >/dev/null 2>&1 || true
  echo "CAPE_INETSIM_GUI_OK already-present"
  exit 0
fi

APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

timeout 300 apt-get "${APT_OPTS[@]}" update
timeout 1200 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
  xfce4 xfce4-terminal lightdm xserver-xorg dbus-x11 spice-vdagent

if ! id "$GUI_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$GUI_USER"
fi
passwd -l "$GUI_USER" >/dev/null 2>&1 || true
usermod -aG video "$GUI_USER" >/dev/null 2>&1 || true

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-cape-inetsim-autologin.conf <<EOF
[Seat:*]
autologin-user=$GUI_USER
autologin-user-timeout=0
user-session=xfce
EOF

install -d -o "$GUI_USER" -g "$GUI_USER" -m 0755 "/home/$GUI_USER/Desktop"
cat >"/home/$GUI_USER/Desktop/INetSim-Appliance.txt" <<'EOF'
CAPE INetSim Appliance

This desktop is for appliance visibility and administration only.
INetSim networking remains controlled by CAPE-INetSim-AutoDeploy.
EOF
chown "$GUI_USER:$GUI_USER" "/home/$GUI_USER/Desktop/INetSim-Appliance.txt"

systemctl set-default graphical.target
systemctl enable lightdm.service >/dev/null
touch "$MARKER"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "CAPE_INETSIM_GUI_OK installed"
