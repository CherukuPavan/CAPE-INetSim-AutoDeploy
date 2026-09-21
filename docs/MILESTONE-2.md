# Milestone 2 — Transaction, State and Isolated Network

Milestone 2 adds the infrastructure required before AutoDeploy is allowed to change a CAPE host.

## Implemented

- Root-only persistent deployment state under `/var/lib/cape-inetsim-autodeploy`.
- Atomic state writes.
- Resource ownership ledger used by rollback.
- Exclusive deployment lock.
- Checksummed backup/restore primitives.
- Dynamically selected AutoDeploy bridge name.
- Dynamically selected private subnet from the discovery layer.
- Isolated libvirt network XML with **no `<forward>` element**, therefore no libvirt NAT/routing.
- Idempotent network creation: an existing network is accepted only when it is recorded as AutoDeploy-owned and its definition matches the stored plan.
- Rollback refuses to remove a network that AutoDeploy does not own.
- Read-only status command and dry-run-first rollback command.
- CI unit tests for state, backups and network XML safety.

## Resource names

The product-owned libvirt network uses the stable logical name:

`cape-inetsim-isolated`

The Linux bridge name is selected dynamically from `capeisim0` … `capeisim99` and is recorded in deployment state. The IP subnet remains dynamic; `192.168.200.0/24` is only the preferred first candidate when unused.

## Not enabled yet

The main `install` command does not expose mutating network creation yet. That is deliberate. We will enable mutation only after the generalized appliance lifecycle and rollback transaction boundaries are implemented and tested together.

The next milestone is the generalized Ubuntu INetSim appliance lifecycle: manifest, SHA-256 verification, import, identity generalization, dynamic network configuration, service verification, autostart and rollback.
