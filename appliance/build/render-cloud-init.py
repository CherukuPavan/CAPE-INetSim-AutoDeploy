#!/usr/bin/env python3
import argparse, base64, pathlib

p=argparse.ArgumentParser(description="Render NoCloud user-data for the generalized INetSim appliance build")
p.add_argument("--guest-configure", required=True)
p.add_argument("--prepare", required=True)
p.add_argument("--output", required=True)
a=p.parse_args()

def b64(path):
    return base64.b64encode(pathlib.Path(path).read_bytes()).decode("ascii")

wrapper=b"""#!/bin/bash
set +e
set -o pipefail
/root/cape-inetsim-image-rootfs-prepare 2>&1 | tee /var/log/cape-inetsim-image-build.log /dev/console
rc=${PIPESTATUS[0]}
mkdir -p /var/lib
if [ "$rc" -eq 0 ]; then
  touch /var/lib/cape-inetsim-build-ok
else
  printf '%s\n' "$rc" >/var/lib/cape-inetsim-build-failed
fi
sync
poweroff -f
"""
wrapper_b64=base64.b64encode(wrapper).decode("ascii")

doc=f"""#cloud-config
ssh_pwauth: false
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
write_files:
  - path: /usr/local/src/cape-inetsim-guest-configure
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: {b64(a.guest_configure)}
  - path: /root/cape-inetsim-image-rootfs-prepare
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: {b64(a.prepare)}
  - path: /root/cape-inetsim-build-wrapper
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: {wrapper_b64}
runcmd:
  - [ /root/cape-inetsim-build-wrapper ]
"""
pathlib.Path(a.output).write_text(doc)
