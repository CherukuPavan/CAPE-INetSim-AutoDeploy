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
  -> isolated libvirt network with no NAT/default gateway
  -> persistent isolated-bridge containment guard
  -> generalized Ubuntu INetSim appliance
  -> preserve existing Windows analysis snapshot/network baseline unchanged
  -> register appliance as CAPE native route=inetsim backend
  -> route-aware packet capture (normal interface vs INetSim bridge)
  -> Network Analysis visibility only for explicit route=inetsim tasks
  -> CAPE-INetSim-VM-Extension v1.0.2
  -> structural + live validation
  -> commit or ownership-aware rollback
```

## Safety invariants

- CAPE's per-task route selection is authoritative: `internet` keeps the host's existing CAPE Internet routing, `inetsim` uses the dedicated Ubuntu INetSim appliance, and `none` uses CAPE's no-network/drop path.
- AutoDeploy does not permanently replace Windows DNS, remove its default gateway, attach a fake-network NIC, or otherwise force every task through INetSim.
- The dedicated INetSim bridge is never attached to a physical NIC and has no libvirt NAT/default forwarding.
- The host containment guard permits traffic onto the isolated bridge only when conntrack proves CAPE task-scoped DNAT to the configured INetSim server; direct/lateral forwarding remains blocked.
- Normal and Internet-routed tasks retain CAPE's ordinary analysis capture interface. Only explicit `route=inetsim` tasks switch capture to the isolated bridge.
- The INetSim visual is gated by the task's authoritative route as well as task-local captured evidence; Internet tasks must not be labelled as fake-Internet tasks.
- CAPE source is modified only after a known layout/anchor passes the compatibility gate; unknown layouts safe-stop before mutation.
- Busy CAPE systems are staged non-disruptively and cut over only after AutoDeploy atomically acquires CAPE machine maintenance ownership.
- Existing CAPE analysis baselines must be proven running-state snapshots. AutoDeploy preserves those snapshots instead of replacing their guest network configuration.
- Every mutable CAPE file is backed up before edit, and deployment-owned appliance/network/firewall/extension resources are journaled for rollback.
- No SSL43/SSL44/SSL45-specific values belong in product logic.
- `192.168.200.0/24` is only a preferred candidate; AutoDeploy selects another unused private subnet if it conflicts.
- The generalized appliance is a separately versioned, checksum-pinned artifact and contains no deployment-specific fake-Internet subnet.
- CAPE-INetSim-VM-Extension v1.0.2 runtime files are vendored with exact file hashes inside the AutoDeploy source bundle.

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
