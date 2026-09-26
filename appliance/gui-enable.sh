#!/usr/bin/env bash
set -Eeuo pipefail

MARKER="/etc/cape-inetsim-gui-v2"
GUI_USER="capeinetsim"
export DEBIAN_FRONTEND=noninteractive

APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

if ! command -v startxfce4 >/dev/null 2>&1 ||
   ! systemctl list-unit-files lightdm.service >/dev/null 2>&1 ||
   [[ ! -f /usr/lib/xorg/modules/drivers/qxl_drv.so ]] ||
   [[ ! -f /usr/share/dbus-1/system-services/org.freedesktop.Accounts.service ]]; then
  timeout 300 apt-get "${APT_OPTS[@]}" update
  timeout 1200 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    xfce4 xfce4-terminal lightdm lightdm-gtk-greeter accountsservice \
    xserver-xorg xserver-xorg-video-qxl dbus-x11 spice-vdagent
fi

if ! id "$GUI_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$GUI_USER"
fi

# The appliance does not use interactive passwords. Keep password
# authentication disabled and enter the dedicated GUI account only through
# LightDM autologin.
passwd -l "$GUI_USER" >/dev/null 2>&1 || true
usermod -aG video "$GUI_USER" >/dev/null 2>&1 || true

groupadd -f autologin
groupadd -f nopasswdlogin
usermod -aG autologin,nopasswdlogin "$GUI_USER" >/dev/null 2>&1 || true

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/99-cape-inetsim-autologin.conf <<EOF
[Seat:*]
autologin-user=$GUI_USER
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
pam-autologin-service=lightdm-autologin
allow-user-switching=false
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=false
EOF

install -d -m 0755 /var/lib/AccountsService/users
cat >"/var/lib/AccountsService/users/$GUI_USER" <<EOF
[User]
Session=xfce
XSession=xfce
SystemAccount=false
EOF
chmod 0600 "/var/lib/AccountsService/users/$GUI_USER"

cat >"/home/$GUI_USER/.dmrc" <<EOF
[Desktop]
Session=xfce
EOF
chown "$GUI_USER:$GUI_USER" "/home/$GUI_USER/.dmrc"
chmod 0600 "/home/$GUI_USER/.dmrc"

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

echo "CAPE_INETSIM_GUI_OK autologin-v2"
