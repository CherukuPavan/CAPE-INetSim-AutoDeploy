# CAPE-INetSim-AutoDeploy

Universal deployment automation for integrating a dedicated Ubuntu INetSim appliance with an existing CAPEv2 + Windows analysis environment.

## Product goal

The v1.0.0 target is one reusable command on a supported CAPE host:

```bash
curl -fsSL https://github.com/CherukuPavan/CAPE-INetSim-AutoDeploy/releases/download/v1.0.0/install | sudo bash
```

The target host already has KVM/libvirt, a working CAPEv2 installation, and at least one working Windows analysis VM. AutoDeploy discovers machine-specific values instead of hard-coding hostnames, CAPE machine names, snapshot names, MAC addresses, management IPs, bridges, interface names, or fake-Internet subnets.

## Current development status

The universal orchestrator is implemented on the development branch, including discovery, compatibility gating, transactional state, owned-resource rollback, busy-CAPE maintenance handling, isolated libvirt networking, an INetSim VM lifecycle, Windows control backends, CAPE capture/processing integration, the frozen Network Analysis extension, verification, repair, status, and rollback commands.

The generalized INetSim appliance now builds successfully in CI, passes the independent offline artifact verifier, and is packaged as a checksum-pinned gzip transport that fits GitHub's release-asset size limit. **The production appliance manifest is still deliberately unpublished**, so a real deployment stops before target-host mutation until the release candidate has passed controlled end-to-end CAPE host validation and the exact release URL/checksums are promoted.

Read-only planning is available now:

```bash
sudo ./install --plan
```

If multiple compatible CAPE analysis machines exist:

```bash
sudo ./install --plan --machine <cape-machine-or-label>
```

Operational entry points already implemented are:

```bash
sudo ./install --status
sudo ./install --verify
sudo ./install --repair
sudo ./install --collect
sudo ./install --acceptance
sudo ./install --acceptance --positive-task <id> --negative-task <id>
sudo ./install --rollback
sudo ./install --rollback --apply
```

Do **not** treat the development branch as a production release until `appliance/manifest.json` is published with a versioned artifact URL and SHA-256.

`--collect` is the supported single-command read-only evidence collector. It writes one credential-redacted `.tar.gz` plus SHA-256 without changing CAPE, libvirt, Windows, networking, firewall, snapshots, or services.

`--acceptance` is a post-deployment read-only functional gate. It re-runs the structural verifier, then validates real completed `route=none` task reports and pcaps: one positive task must contain traffic to the configured Ubuntu-VM INetSim server and classify as INetSim; one negative-control task must remain ordinary. Task IDs may be supplied explicitly, or the tool can select the newest locally provable pair.

## Architecture

```text
install/bootstrap
  -> universal discovery
  -> CAPE compatibility gate
  -> deterministic plan
  -> transaction + backup/ownership journal
  -> isolated libvirt network
  -> persistent host egress/input firewall guard
  -> generalized Ubuntu INetSim appliance
  -> Windows isolated secondary NIC
  -> Windows no-default-route / DNS / IPv6 safety gates
  -> deployment-owned safety + working + running snapshots
  -> CAPE isolated capture integration
  -> Network Analysis processing visibility
  -> CAPE-INetSim-VM-Extension v1.0.1
  -> structural + live validation
  -> commit or ownership-aware rollback
```

## Safety invariants

- The Windows malware-analysis guest must never receive a real/default Internet route.
- The fake-Internet bridge is never attached to a physical NIC and never configured with libvirt NAT/forwarding.
- A deployment-owned nftables guard blocks forwarding from the isolated bridge as defense in depth.
- Windows validation requires zero IPv4 default routes, zero IPv6 default routes, no enabled IPv6 bindings, no unexpected active third adapter, INetSim-only DNS, working CAPE ResultServer reachability, and failed public IPv4/IPv6 reachability.
- CAPE source is modified only after a known layout/anchor passes the compatibility gate; unknown layouts safe-stop before mutation.
- Busy CAPE systems are staged non-disruptively and cut over only after AutoDeploy atomically acquires CAPE machine maintenance ownership.
- Every mutable CAPE file is backed up before edit. Libvirt resources, Windows NICs/snapshots, firewall resources, and extension state are deployment-owned and recorded before/after mutation so interrupted operations can be resumed or rolled back safely.
- No SSL43/SSL44/SSL45-specific values belong in product logic.
- `192.168.200.0/24` is only a preferred candidate; AutoDeploy selects another unused private subnet if it conflicts.
- The generalized appliance is a separately versioned, checksum-pinned artifact and contains no deployment-specific fake-Internet subnet.

## Appliance build

The appliance builder starts from a checksum-pinned Ubuntu 24.04 cloud image, expands the guest root filesystem, provisions INetSim inside a temporary QEMU/NoCloud build VM, validates the required INetSim/Net::DNS compatibility behavior, removes build identity/state inside the guest, independently verifies the sealed QCOW2 offline, and emits SHA-256 evidence.

GitHub Actions builds, independently verifies, and release-packages the candidate. The release workflow is manual and binds a release to the exact successful appliance workflow run and exact source commit; it re-verifies the gzip transport, decompressed QCOW2, provenance, and artifact contents before producing a checksum-pinned release bundle. A failed build, verifier, package-size gate, provenance check, or checksum check cannot produce a publishable release.

## Release distribution

The production release is designed around immutable release assets rather than the mutable `main` branch. The one-command `install` release asset contains an embedded SHA-256 for the versioned source bundle; that source bundle contains the published appliance manifest, and the installer separately verifies both the compressed appliance transport SHA-256 and the decompressed raw QCOW2 SHA-256.

The repository is currently private. A stable `v1.0.0` release is intentionally blocked by the release workflow until the repository (or an equivalent release endpoint) is anonymously reachable, because the final one-command experience must not require GitHub credentials.

## Release gate

Before v1.0.0 can be called deployable, all of the following must be true:

1. Generalized QCOW2 build completes successfully and its contents are verified.
2. The artifact is published in versioned release/artifact storage and its exact SHA-256 is pinned in `appliance/manifest.json`.
3. The same release passes a controlled end-to-end deployment on one supported CAPE host.
4. The exact same release/command passes on a second independent CAPE host with different CAPE/libvirt/VM identifiers.
5. Positive and negative Network Analysis/INetSim visibility checks pass without giving the Windows analysis VM real Internet access.
