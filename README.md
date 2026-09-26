# CAPE-INetSim-AutoDeploy

Universal deployment automation for integrating a dedicated Ubuntu INetSim appliance with an existing CAPEv2 + Windows analysis environment.

## Product goal

The v1.0.0 target is one reusable command on a supported CAPE host:

```bash
curl -fsSL https://github.com/CherukuPavan/CAPE-INetSim-AutoDeploy-Releases/releases/download/v1.0.0/install | sudo bash
```

The target host already has KVM/libvirt, a working CAPEv2 installation, and one or more Windows analysis VMs enabled for CAPE KVM analysis. AutoDeploy discovers the complete active CAPE machine set and configures every enabled Windows-compatible analysis VM by default instead of hard-coding hostnames, CAPE machine names, snapshot names, MAC addresses, management IPs, bridges, interface names, or fake-Internet subnets.

## Current development status

The universal orchestrator is implemented on the development branch, including discovery, compatibility gating, transactional state, owned-resource rollback, busy-CAPE maintenance handling, isolated libvirt networking, an INetSim VM lifecycle, Windows control backends, CAPE capture/processing integration, the frozen Network Analysis extension, verification, repair, status, and rollback commands.

The generalized INetSim appliance now builds successfully in CI, passes the independent offline artifact verifier, and is packaged as a checksum-pinned gzip transport that fits GitHub's release-asset size limit. **The production appliance manifest is still deliberately unpublished**, so a real deployment stops before target-host mutation until the release candidate has passed controlled end-to-end CAPE host validation and the exact release URL/checksums are promoted.

Read-only planning is available now:

```bash
sudo ./install --plan
```

With no `--machine` override, planning and deployment cover every enabled Windows-compatible machine in CAPE's authoritative `[kvm] machines=` set. `--machine <cape-machine-or-label>` remains only an explicit single-VM troubleshooting/controlled override.

Operational entry points already implemented are:

```bash
sudo ./install --status
sudo ./install --verify
sudo ./install --repair
sudo ./install --collect
sudo ./install --acceptance --positive-task <id> --negative-task <id> --marker <unique-hostname>
sudo ./install --rollback
sudo ./install --rollback --apply
```

Do **not** treat the development branch as a production release until `appliance/manifest.json` is published with a versioned artifact URL and SHA-256.

`--collect` is the supported single-command read-only evidence collector. It writes one credential-redacted `.tar.gz` plus SHA-256 without changing CAPE, libvirt, Windows, networking, firewall, snapshots, or services.

`--acceptance` is a post-deployment read-only functional gate. It re-runs the structural verifier, then validates a controlled pair of completed `route=inetsim` tasks using a unique hostname marker. The positive task must contain the marker in task-local INetSim evidence and its pcap; the negative task must not contain the marker. Normal Windows background traffic may still reach INetSim in either task and is not treated as sample-induced evidence. This avoids host/image-specific domain blacklists while keeping the negative control meaningful.

## Architecture

```text
install/bootstrap
  -> universal discovery
  -> CAPE compatibility gate
  -> deterministic plan
  -> transaction + backup/ownership journal
  -> isolated libvirt network
  -> isolated-bridge input/forwarding firewall guard
  -> generalized Ubuntu INetSim appliance
  -> Windows isolated secondary NIC
  -> route-aware Windows/CAPE network safety gates
  -> deployment-owned safety + working + running snapshots
  -> route-aware CAPE packet-capture integration
  -> Network Analysis processing visibility
  -> CAPE-INetSim-VM-Extension v1.0.2
  -> structural + live validation
  -> commit or ownership-aware rollback
```

## Safety invariants

- Per-task routing is authoritative: `internet` uses CAPE's configured Internet path, `inetsim` uses the isolated fake-Internet appliance, and `none`/`drop` must not reach either path.
- The fake-Internet bridge is never attached to a physical NIC and never configured with libvirt NAT/forwarding.
- A deployment-owned nftables guard blocks forwarding from the isolated bridge as defense in depth.
- The dedicated `route=inetsim` Windows snapshot is validated with zero IPv4/IPv6 default routes, INetSim-only DNS, working CAPE ResultServer reachability, and failed public IPv4/IPv6 reachability. The separate normal-route snapshot preserves the pre-existing CAPE networking used by `internet`/`none`/`drop`.
- CAPE source is modified only after a known layout/anchor passes the compatibility gate; unknown layouts safe-stop before mutation.
- Busy CAPE systems are staged non-disruptively and cut over only after AutoDeploy atomically acquires CAPE machine maintenance ownership.
- Running qcow2 analysis disks are inspected read-only with QEMU shared-image semantics when their live QEMU process holds the normal image lock; AutoDeploy never runs qemu-img repair/conversion against a live analysis disk.
- Existing CAPE analysis baselines must be running-state snapshots. Saved VM memory may be either libvirt `internal` or `external`; both modes are accepted after domain identity and management-NIC validation.
- On modular libvirt hosts, an installed standard `clean-traffic` definition with an inactive `virtnwfilterd.socket` is detected as safely activatable; deployment enables/starts that socket before cutover, proves the filter through libvirt, records ownership, and restores the prior runtime state on rollback when safe.
- Every mutable CAPE file is backed up before edit. Libvirt resources, Windows NICs/snapshots, firewall resources, and extension state are deployment-owned and recorded before/after mutation so interrupted operations can be resumed or rolled back safely.
- No SSL43/SSL44/SSL45-specific values belong in product logic.
- `192.168.200.0/24` is only a preferred candidate; AutoDeploy selects another unused private subnet if it conflicts.
- The generalized appliance is a separately versioned, checksum-pinned artifact and contains no deployment-specific fake-Internet subnet.
- CAPE-INetSim-VM-Extension v1.0.1 runtime files are vendored with exact file hashes inside the AutoDeploy source bundle, so a random target host never needs credentials for the separate private extension development repository.

## Appliance build

The appliance builder starts from a checksum-pinned Ubuntu 24.04 cloud image, expands the guest root filesystem, provisions INetSim inside a temporary QEMU/NoCloud build VM, validates the required INetSim/Net::DNS compatibility behavior, removes build identity/state inside the guest, independently verifies the sealed QCOW2 offline, and emits SHA-256 evidence.

GitHub Actions builds, independently verifies, and release-packages the candidate. The release workflow is manual and binds a release to the exact successful appliance workflow run and exact source commit; it re-verifies the gzip transport, decompressed QCOW2, provenance, and artifact contents before producing a checksum-pinned release bundle. A failed build, verifier, package-size gate, provenance check, or checksum check cannot produce a publishable release.

## Release distribution

The production release is designed around immutable release assets rather than the mutable `main` branch. The one-command `install` release asset contains an embedded SHA-256 for the versioned source bundle; that source bundle contains the published appliance manifest, and the installer separately verifies both the compressed appliance transport SHA-256 and the decompressed raw QCOW2 SHA-256.

The development repository remains private. Runtime releases are promoted to the separate public `CherukuPavan/CAPE-INetSim-AutoDeploy-Releases` endpoint after exact-source, provenance, checksum, package-hygiene, and anonymous-download gates pass. The public runtime bundle intentionally excludes development history, workflows, internal notes, host inventories, and lab-specific evidence.

## Release gate

Before v1.0.0 can be called deployable, all of the following must be true:

1. Generalized QCOW2 build completes successfully and its contents are verified.
2. The artifact is published in versioned release/artifact storage and its exact SHA-256 is pinned in `appliance/manifest.json`.
3. The same release passes a controlled end-to-end deployment on one supported CAPE host.
4. The exact same release/command passes on a second independent CAPE host with different CAPE/libvirt/VM identifiers. The second host is treated as a blind/random supported installation: no host-specific scripts, identifiers, manual prerequisite fixes, or candidate changes are allowed between first-host and second-host validation. If the second host exposes a product defect, the candidate is invalidated, the fix must be generalized, and validation restarts from the first host.
5. Positive and negative Network Analysis/INetSim visibility checks pass without giving the Windows analysis VM real Internet access.
