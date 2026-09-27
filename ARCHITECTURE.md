# Architecture

The production flow is:

```text
bootstrap
  -> host/runtime discovery
  -> CAPE root + service-role discovery
  -> CAPE Python validation
  -> libvirt/VM/network discovery
  -> pre-change inventory JSON
  -> deployment decision engine
       fresh -> deploy
       committed -> verify -> repair/upgrade if required
       interrupted/broken -> ownership-aware rollback -> rediscover
  -> transaction state + backup ledger
  -> isolated libvirt network
  -> checksum-pinned generalized INetSim VM
  -> QEMU Guest Agent configuration
  -> deterministic XFCE/LightDM + SPICE/Virtio validation
  -> Windows isolated NIC + fake-Internet configuration
  -> CAPE running snapshot
  -> rooter structured readiness probe
  -> CAPE/extension integration
  -> service restoration
  -> structural/service validation
  -> commit
```

## Discovery

CAPE root candidates are obtained from systemd WorkingDirectory/ExecStart and filesystem fallback. Service roles are inferred from unit names and ExecStart behavior. CAPE Python candidates are taken from running service executables, service ExecStart, CAPE `.venv`/`venv`, Poetry, and finally host Python; candidates must import Django and CAPE modules.

Libvirt networks, domains, NICs, addresses, routes, and active subnets are discovered at runtime. The isolated subnet and bridge are selected dynamically and recorded in state.

## Ownership and transactions

State lives under `/var/lib/cape-inetsim-autodeploy` with root-only permissions. Every created/modified resource is recorded in `resources.tsv`. CAPE files are backed up once per deployment before mutation. Rollback removes/restores only resources proven to belong to that deployment.

## Appliance

The release transports a gzip-compressed QCOW2 but the manifest records both transport and raw-image hashes. Build-time verification inspects the image offline. Host-time verification checks QGA, INetSim services, GUI session prerequisites, and SPICE/Virtio domain configuration.
