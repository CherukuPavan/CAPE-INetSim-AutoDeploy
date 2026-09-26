#!/usr/bin/env bash
set -Eeuo pipefail

MARKER="/etc/cape-inetsim-gui-v3"
GUI_USER="capeinetsim"
SESSION_NAME="cape-inetsim-xfce"
export DEBIAN_FRONTEND=noninteractive

APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

if ! command -v xfce4-session >/dev/null 2>&1 ||
   ! command -v dbus-run-session >/dev/null 2>&1 ||
   ! systemctl list-unit-files lightdm.service >/dev/null 2>&1 ||
   [[ ! -f /usr/lib/xorg/modules/drivers/qxl_drv.so ]] ||
   [[ ! -f /usr/share/dbus-1/system-services/org.freedesktop.Accounts.service ]]; then
  timeout 300 apt-get "${APT_OPTS[@]}" update
  timeout 1200 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    xfce4 xfce4-terminal xfce4-session xfce4-panel xfdesktop4 xfwm4 \
    lightdm lightdm-gtk-greeter accountsservice \
    xserver-xorg xserver-xorg-video-qxl x11-xserver-utils \
    dbus-x11 dbus-user-session libglib2.0-bin upower spice-vdagent
fi

if ! id "$GUI_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$GUI_USER"
fi

# No account password is used by the appliance. Keep interactive password
# authentication locked; LightDM uses its standard autologin path only.
passwd -l "$GUI_USER" >/dev/null 2>&1 || true
usermod -aG video "$GUI_USER" >/dev/null 2>&1 || true
groupadd -f autologin
groupadd -f nopasswdlogin
usermod -aG autologin,nopasswdlogin "$GUI_USER" >/dev/null 2>&1 || true

# Use a dedicated session entry instead of relying on distro session-wrapper
# behavior. The wrapper gives XFCE an explicit D-Bus session and preserves a
# local diagnostic log if the desktop ever exits.
cat >/usr/local/bin/cape-inetsim-xfce-session <<'EOF'
#!/bin/sh
LOG="$HOME/.cape-inetsim-xfce-session.log"
exec >>"$LOG" 2>&1
echo "=== CAPE INetSim XFCE session start: $(date -Is) ==="
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export DESKTOP_SESSION=cape-inetsim-xfce
exec /usr/bin/dbus-run-session -- /usr/bin/xfce4-session
EOF
chmod 0755 /usr/local/bin/cape-inetsim-xfce-session

cat >/usr/share/xsessions/$SESSION_NAME.desktop <<EOF
[Desktop Entry]
Name=CAPE INetSim XFCE
Comment=CAPE INetSim appliance desktop
Exec=/usr/local/bin/cape-inetsim-xfce-session
TryExec=/usr/local/bin/cape-inetsim-xfce-session
Type=Application
DesktopNames=XFCE
EOF
chmod 0644 /usr/share/xsessions/$SESSION_NAME.desktop

install -d -m 0755 /etc/lightdm/lightdm.conf.d
rm -f /etc/lightdm/lightdm.conf.d/50-cape-inetsim-autologin.conf
cat >/etc/lightdm/lightdm.conf.d/99-cape-inetsim-autologin.conf <<EOF
[Seat:*]
autologin-user=$GUI_USER
autologin-user-timeout=0
autologin-session=$SESSION_NAME
user-session=$SESSION_NAME
pam-autologin-service=lightdm-autologin
allow-user-switching=false
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=false
EOF

install -d -m 0755 /var/lib/AccountsService/users
cat >"/var/lib/AccountsService/users/$GUI_USER" <<EOF
[User]
Session=$SESSION_NAME
XSession=$SESSION_NAME
SystemAccount=false
EOF
chmod 0600 "/var/lib/AccountsService/users/$GUI_USER"

cat >"/home/$GUI_USER/.dmrc" <<EOF
[Desktop]
Session=$SESSION_NAME
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
systemctl enable lightdm.service >/dev/null 2>&1 || true
touch "$MARKER"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "CAPE_INETSIM_GUI_OK autologin-v3"
