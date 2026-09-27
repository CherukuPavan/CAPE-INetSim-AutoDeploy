# CAPE-INetSim-AutoDeploy

Universal deployment automation for integrating a dedicated Ubuntu/XFCE INetSim appliance with an existing CAPEv2 + KVM/libvirt + Windows analysis environment.

## Goal

Unknown CAPE host. Unknown CAPE path. Unknown Linux user. Unknown Windows VM names. Unknown libvirt/network layout. One deployment command with transactional rollback and no manual file editing.

The installer discovers the environment, writes a complete pre-change inventory, classifies fresh/existing/broken AutoDeploy state, validates CAPE Python and rooter readiness, chooses non-conflicting network resources, deploys the checksum-pinned appliance, preserves CAPE management connectivity, and commits only after validation.

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

## Production properties

- No fixed `/opt/CAPEv2`, `/home/cape`, `virbr0`, Windows domain name, bridge, isolated subnet, INetSim IP, CAPE Python path, rooter unit, or rooter socket.
- Pre-change inventory: `/var/lib/cape-inetsim-autodeploy/autodeploy-inventory.json`.
- Fresh/existing/broken decision engine with ownership-aware recovery.
- CAPE Python discovery from running services, ExecStart, virtualenv, Poetry, and host fallback with import validation.
- Rooter service/socket discovery and a structured CAPE rooter command probe.
- Dynamic libvirt network/subnet/bridge selection.
- Separate SHA-256 validation for compressed appliance transport and decompressed QCOW2.
- Deterministic appliance GUI: XFCE + LightDM + SPICE/Virtio; lab user `capeinetsim`, password `123`.
- INetSim validation for DNS, HTTP, HTTPS, SMTP, and FTP.
- Transaction state, backup ledger, safe repair, and rollback.

See `INSTALL.md`, `ARCHITECTURE.md`, `TROUBLESHOOTING.md`, and `RECOVERY.md`.
