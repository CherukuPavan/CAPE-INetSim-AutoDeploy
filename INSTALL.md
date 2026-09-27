# Installation

CAPE-INetSim-AutoDeploy is designed for an existing Linux CAPEv2 host using KVM/libvirt and at least one Windows analysis VM.

## One-command deployment

Use the immutable public release installer for the selected release tag:

```bash
curl -fsSL https://github.com/CherukuPavan/CAPE-INetSim-AutoDeploy-Releases/releases/download/<TAG>/install | sudo bash
```

The bootstrap downloads the checksum-pinned runtime bundle, verifies SHA-256, discovers the local CAPE/KVM layout, writes `/var/lib/cape-inetsim-autodeploy/autodeploy-inventory.json`, classifies the host as fresh/existing/broken, and then performs a transactional deployment.

No CAPE path, Linux username, Windows VM name, libvirt bridge, isolated subnet, INetSim IP, CAPE Python path, rooter service name, or rooter socket is required from the operator.

The appliance GUI account is intentionally fixed for this isolated lab appliance:

- user: `capeinetsim`
- password: `123`
- desktop: XFCE
- display manager: LightDM

Do not reuse this appliance credential on a general-purpose or Internet-facing machine.

## What deployment validates

Before commit, AutoDeploy verifies KVM/libvirt, CAPE discovery, CAPE Python imports, rooter service/socket/structured command response, the generalized appliance checksum and QEMU agent, isolated network selection, Windows CAPE management preservation, INetSim DNS/HTTP/HTTPS/SMTP/FTP listeners, XFCE/LightDM, SPICE/Virtio console support, CAPE configuration, ResultServer reachability, and ownership-backed rollback state.

## Commands

```bash
sudo ./install --plan
sudo ./install
sudo ./install --status
sudo ./install --verify
sudo ./install --repair
sudo ./install --rollback
sudo ./install --rollback --apply
```

`--rollback` is dry-run unless `--apply` is supplied. The installer never removes a resource unless the transaction ledger proves it was created by AutoDeploy.
