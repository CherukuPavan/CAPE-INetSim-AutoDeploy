#!/usr/bin/env python3
import argparse, hashlib, json
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument("--artifact", required=True)
p.add_argument("--transport-artifact", required=True)
p.add_argument("--url", required=True)
p.add_argument("--output", required=True)
a=p.parse_args()

raw=Path(a.artifact)
transport=Path(a.transport_artifact)
if not raw.is_file() or not transport.is_file():
    raise SystemExit("artifact/transport file missing")

def sha256(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024), b""):
            h.update(chunk)
    return h.hexdigest()

data={
  "schema":1,
  "appliance_version":"1.0.0",
  "status":"published",
  "artifact_name":raw.name,
  "artifact_url":a.url,
  "sha256":sha256(raw),
  "format":"qcow2",
  "transport_name":transport.name,
  "transport_compression":"gzip" if transport.suffix==".gz" else "none",
  "transport_sha256":sha256(transport),
  "transport_size":transport.stat().st_size,
  "os":{"distribution":"Ubuntu","release":"24.04 LTS","architecture":"x86_64"},
  "inetsim":{
    "expected_major_version":"1.3.2",
    "dns_compatibility_patch":"netdns-loop-once",
    "unprivileged_port_start":53
  },
  "gui":{
    "desktop":"XFCE",
    "display_manager":"LightDM",
    "user":"capeinetsim",
    "spice":True,
    "virtio_video":True
  },
  "guest_management":{"qemu_guest_agent":True,"ssh_password_login_required":False},
  "networking":{
    "management":"dhcp",
    "isolated":"configured-at-deployment",
    "baked_in_fake_internet_subnet":False
  }
}
Path(a.output).write_text(json.dumps(data,indent=2,sort_keys=True)+"\n")
