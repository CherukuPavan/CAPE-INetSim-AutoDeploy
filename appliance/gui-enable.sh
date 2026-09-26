#!/usr/bin/env bash
set -Eeuo pipefail

MARKER="/etc/cape-inetsim-gui-v6"
GUI_USER="capeinetsim"
SESSION_NAME="xubuntu"
export DEBIAN_FRONTEND=noninteractive

APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# Use Ubuntu's supported Xubuntu minimal desktop metapackage rather than a
# hand-maintained subset of XFCE packages. This prevents missing session/runtime
# dependencies from surfacing only after a real LightDM login.
if ! dpkg-query -W -f='${Status}' xubuntu-desktop-minimal 2>/dev/null | grep -Fq 'install ok installed' ||
   [[ ! -f /usr/share/xsessions/xubuntu.desktop ]] ||
   [[ ! -f /usr/lib/xorg/modules/drivers/modesetting_drv.so ]]; then
  timeout 300 apt-get "${APT_OPTS[@]}" update
  timeout 1500 apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    xubuntu-desktop-minimal xserver-xorg-core spice-vdagent
fi

# The appliance owns one visible GUI identity only. The cloud-image bootstrap
# account is not needed after cloud-init is disabled/generalized.
if ! id "$GUI_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -c "CAPE INetSim" "$GUI_USER"
else
  usermod -s /bin/bash -c "CAPE INetSim" "$GUI_USER"
fi
usermod -aG sudo,video "$GUI_USER" >/dev/null 2>&1 || true

if id ubuntu >/dev/null 2>&1; then
  usermod -L -s /usr/sbin/nologin ubuntu >/dev/null 2>&1 || true
  install -d -m 0755 /var/lib/AccountsService/users
  cat >/var/lib/AccountsService/users/ubuntu <<'EOF'
[User]
SystemAccount=true
EOF
  chmod 0600 /var/lib/AccountsService/users/ubuntu
fi

# Keep the immutable image credential-free. Deployment/repair assigns the local
# console password after import. Root and the GUI account remain inaccessible
# by password in the published QCOW2.
passwd -l root >/dev/null 2>&1 || true
passwd -l "$GUI_USER" >/dev/null 2>&1 || true

# Repair ownership/state that can otherwise cause a successful authentication
# to bounce straight back to LightDM.
install -d -o "$GUI_USER" -g "$GUI_USER" -m 0750 "/home/$GUI_USER"
rm -f "/home/$GUI_USER/.Xauthority" "/home/$GUI_USER/.ICEauthority"
rm -rf "/home/$GUI_USER/.cache/sessions" "/home/$GUI_USER/.dbus"
chown -R "$GUI_USER:$GUI_USER" "/home/$GUI_USER"
chmod 1777 /tmp

install -d -m 0755 /etc/lightdm/lightdm.conf.d
rm -f /etc/lightdm/lightdm.conf.d/50-cape-inetsim-autologin.conf
rm -f /etc/lightdm/lightdm.conf.d/99-cape-inetsim-autologin.conf
rm -f /etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf
cat >/etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf <<EOF
[Seat:*]
user-session=$SESSION_NAME
allow-user-switching=false
allow-guest=false
greeter-hide-users=false
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

GUI user: capeinetsim
Default local-console password after AutoDeploy: 123

INetSim networking remains controlled by CAPE-INetSim-AutoDeploy.
EOF
chown "$GUI_USER:$GUI_USER" "/home/$GUI_USER/Desktop/INetSim-Appliance.txt"

# The deliberately simple lab-console password is never accepted over SSH.
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

echo "CAPE_INETSIM_GUI_OK xubuntu-v6"
