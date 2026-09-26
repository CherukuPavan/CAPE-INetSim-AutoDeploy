#!/usr/bin/env bash
set -Eeuo pipefail

MARKER="/etc/cape-inetsim-gui-v5"
GUI_USER="capeinetsim"
SESSION_NAME="xfce"
export DEBIAN_FRONTEND=noninteractive

APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

if ! command -v startxfce4 >/dev/null 2>&1 ||
   ! command -v xfce4-session >/dev/null 2>&1 ||
   ! systemctl list-unit-files lightdm.service >/dev/null 2>&1 ||
   [[ ! -f /usr/share/xsessions/xfce.desktop ]] ||
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

# The immutable image ships with locked account passwords. Deployment/repair may
# explicitly assign a local-console password after import.
passwd -l "$GUI_USER" >/dev/null 2>&1 || true
usermod -aG video "$GUI_USER" >/dev/null 2>&1 || true

install -d -m 0755 /etc/lightdm/lightdm.conf.d
rm -f /etc/lightdm/lightdm.conf.d/50-cape-inetsim-autologin.conf
rm -f /etc/lightdm/lightdm.conf.d/99-cape-inetsim-autologin.conf
rm -f /etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf
cat >/etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf <<EOF
[Seat:*]
user-session=$SESSION_NAME
allow-user-switching=true
allow-guest=false
greeter-hide-users=false
greeter-show-manual-login=true
EOF

# Force every interactive non-system account onto the known-good stock XFCE
# xsession. This prevents cloud-image users such as "ubuntu" from retaining a
# stale/default desktop selection that immediately returns to the greeter.
while IFS=: read -r user _ uid _ _ home shell; do
  [[ "$uid" =~ ^[0-9]+$ ]] || continue
  (( uid >= 1000 )) || continue
  [[ "$shell" != */nologin && "$shell" != */false ]] || continue
  [[ -d "$home" ]] || continue

  install -d -m 0755 /var/lib/AccountsService/users
  cat >"/var/lib/AccountsService/users/$user" <<EOF
[User]
Session=$SESSION_NAME
XSession=$SESSION_NAME
SystemAccount=false
EOF
  chmod 0600 "/var/lib/AccountsService/users/$user"

  cat >"$home/.dmrc" <<EOF
[Desktop]
Session=$SESSION_NAME
EOF
  chown "$user:$user" "$home/.dmrc"
  chmod 0600 "$home/.dmrc"

  rm -f "$home/.xsession" "$home/.xinitrc"
done </etc/passwd

install -d -o "$GUI_USER" -g "$GUI_USER" -m 0755 "/home/$GUI_USER/Desktop"
cat >"/home/$GUI_USER/Desktop/INetSim-Appliance.txt" <<'EOF'
CAPE INetSim Appliance

This desktop is for appliance visibility and administration only.
INetSim networking remains controlled by CAPE-INetSim-AutoDeploy.
EOF
chown "$GUI_USER:$GUI_USER" "/home/$GUI_USER/Desktop/INetSim-Appliance.txt"

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-cape-inetsim-no-password-auth.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

systemctl set-default graphical.target
systemctl enable lightdm.service >/dev/null 2>&1 || true
touch "$MARKER"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "CAPE_INETSIM_GUI_OK stock-xfce-console-v5"
