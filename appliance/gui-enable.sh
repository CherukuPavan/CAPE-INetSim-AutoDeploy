#!/usr/bin/env bash
set -Eeuo pipefail

# Deterministic local GUI for the isolated INetSim appliance.
# This account is intentionally fixed for the disposable lab appliance only.
GUI_USER="capeinetsim"
GUI_PASSWORD="123"
GUI_HOME="/home/$GUI_USER"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
  spice-vdagent qemu-guest-agent dbus-x11 x11-xserver-utils

if ! id "$GUI_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$GUI_USER"
fi
printf '%s:%s\n' "$GUI_USER" "$GUI_PASSWORD" | chpasswd
usermod -aG video,render "$GUI_USER" 2>/dev/null || true

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/60-cape-inetsim.conf <<EOF
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
autologin-user=$GUI_USER
autologin-user-timeout=0
EOF

cat >"$GUI_HOME/.xsession" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chown "$GUI_USER:$GUI_USER" "$GUI_HOME/.xsession"
chmod 0755 "$GUI_HOME/.xsession"

install -d -m 0755 /var/lib/AccountsService/users
cat >/var/lib/AccountsService/users/"$GUI_USER" <<EOF
[User]
Session=xfce
XSession=xfce
SystemAccount=false
EOF
chmod 0600 /var/lib/AccountsService/users/"$GUI_USER"

# Disable automatic graphical login for any other account created by an older image.
for f in /var/lib/AccountsService/users/*; do
  [[ -e "$f" && "$(basename "$f")" != "$GUI_USER" ]] || continue
  sed -i -E 's/^(Session|XSession)=.*/\1=/' "$f" 2>/dev/null || true
done

systemctl enable qemu-guest-agent.service
systemctl enable lightdm.service
systemctl set-default graphical.target

# Validate the pieces needed to avoid login loops before the image is accepted.
id "$GUI_USER" >/dev/null
getent passwd "$GUI_USER" | grep -Fq "$GUI_HOME:/bin/bash"
command -v startxfce4 >/dev/null
test -f /usr/share/xsessions/xfce.desktop
lightdm --version >/dev/null 2>&1
command -v spice-vdagent >/dev/null
test -x /usr/sbin/lightdm || command -v lightdm >/dev/null
test -s /etc/lightdm/lightdm.conf.d/60-cape-inetsim.conf

echo "INETSIM_GUI_READY user=$GUI_USER session=xfce"
