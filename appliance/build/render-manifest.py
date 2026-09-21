#!/usr/bin/env python3
import argparse,hashlib,json,pathlib,urllib.parse

p=argparse.ArgumentParser()
p.add_argument("--artifact",required=True)
p.add_argument("--url",required=True)
p.add_argument("--output",default="-")
a=p.parse_args()

artifact=pathlib.Path(a.artifact)
u=urllib.parse.urlparse(a.url)
if u.scheme!="https":
    raise SystemExit("artifact URL must be HTTPS")
h=hashlib.sha256()
with artifact.open("rb") as f:
    for chunk in iter(lambda:f.read(1024*1024),b""):
        h.update(chunk)

manifest={
  "schema":1,
  "appliance_version":"1.0.0",
  "status":"published",
  "artifact_name":artifact.name,
  "artifact_url":a.url,
  "sha256":h.hexdigest(),
  "format":"qcow2",
  "os":{"distribution":"Ubuntu","release":"24.04 LTS","architecture":"x86_64"},
  "inetsim":{
    "expected_major_version":"1.3.2",
    "dns_compatibility_patch":"netdns-loop-once",
    "unprivileged_port_start":53
  },
  "guest_management":{"qemu_guest_agent":True,"ssh_password_login_required":False},
  "networking":{"management":"dhcp-by-deployment-mac","isolated":"static-by-deployment-mac","baked_in_fake_internet_subnet":False}
}
text=json.dumps(manifest,indent=2)+"\n"
if a.output=="-":
    print(text,end="")
else:
    pathlib.Path(a.output).write_text(text)
