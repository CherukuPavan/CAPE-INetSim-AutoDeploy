# CAPE-INetSim-AutoDeploy

Universal, reusable deployment automation for integrating a dedicated Ubuntu-VM INetSim appliance with an existing CAPEv2 + Windows analysis environment.

## Product goal

On a supported CAPE host that already has KVM/libvirt, a working CAPEv2 installation, and at least one working Windows analysis VM, the finished v1.0.0 product should support a one-command deployment experience with minimal operator interaction.

The installer must discover machine-specific values rather than hard-code hostnames, CAPE machine names, MAC addresses, management IPs, interface names, or snapshot names.

## Current milestone: read-only universal planner

The repository currently implements the first production layer only:

```bash
sudo ./install --plan
```

This discovers CAPE, libvirt, enabled analysis machines, the matching domain, current snapshot/control IP, Windows management options, busy state, used networks, and a safe candidate isolated subnet.

It **does not modify configuration**. Deployment mode is intentionally disabled until discovery/compatibility behavior is validated on multiple independent CAPE systems.

If more than one enabled CAPE analysis machine is present, select one explicitly for planning:

```bash
sudo ./install --plan --machine <cape-machine-or-label>
```

## Non-negotiable design rules

- No SSL43/SSL44/SSL45-specific logic.
- No hard-coded Windows VM names.
- Prefer `192.168.200.0/24` only when unused; otherwise choose a non-overlapping private subnet.
- Idempotent, transactional, version-aware and recoverable deployment.
- Never modify an unknown CAPE source layout blindly.
- Busy CAPE systems must be staged safely and cut over only at an idle point.
- A future deployment must provide status, verify, repair and rollback operations.
- The generalized INetSim appliance will be versioned separately and verified with SHA-256.

## Planned architecture

```text
install/bootstrap
  -> discover
  -> compatibility gate
  -> plan
  -> transaction + backup engine
  -> isolated libvirt network
  -> generalized Ubuntu INetSim appliance
  -> Windows secondary-NIC configuration
  -> running-state CAPE snapshot
  -> CAPE isolated capture integration
  -> Network Analysis visibility
  -> CAPE-INetSim-VM-Extension
  -> validation
  -> commit or rollback
```

## Safety

`--plan` is intentionally read-only with respect to machine configuration. It may read systemd/libvirt/CAPE files and create only ephemeral process-local temporary files.
