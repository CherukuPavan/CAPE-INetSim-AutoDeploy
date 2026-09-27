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
sudo ./install --acceptance --positive-task <id> --negative-task <id> --drop-task <id> --marker <unique-hostname>
sudo ./install --rollback
sudo ./install --rollback --apply
```

Do **not** treat the development branch as a production release until `appliance/manifest.json` is published with a versioned artifact URL and SHA-256.

`--collect` is the supported single-command read-only evidence collector. It writes one credential-redacted `.tar.gz` plus SHA-256 without changing CAPE, libvirt, Windows, networking, firewall, snapshots, or services.

`--acceptance` is a post-deployment read-only functional gate. It re-runs the structural verifier, then validates three completed route controls using a unique hostname marker: `route=inetsim` positive, `route=internet` negative, and `route=drop` no-network. The positive task must contain the marker in task-local INetSim evidence and its pcap. The Internet task must contain neither the marker nor INetSim evidence. The No-network task must expose zero analyst-facing Network Analysis events; the raw pcap remains available for forensic inspection. This keeps routing semantics explicit without hiding raw capture evidence.

## Architecture

```text
install/bootstrap
  -> universal discovery
  -> CAPE compatibility gate
  -> deterministic plan
  -> transaction + backup/ownership journal
  -> isolated libvirt network
  -> isolated-bridge route-separation firewall guard
  -> generalized Ubuntu INetSim appliance
  -> preserve existing Windows analysis VM network/snapshot baseline
  -> CAPE-native per-task route selection (internet / inetsim / none-drop)
  -> host-routed isolated INetSim path with no Windows fake NIC/IP/DNS
  -> route-aware CAPE packet-capture integration
  -> Network Analysis processing visibility
  -> CAPE-INetSim-VM-Extension v1.0.2
  -> structural + live validation
  -> commit or ownership-aware rollback
```

## Safety invariants

- Route selection is task-scoped: route=internet preserves CAPE's normal Internet path, route=inetsim redirects only that task to the isolated Ubuntu INetSim appliance, and route=none/drop remains blocked.
- The fake-Internet bridge is never attached to a physical NIC and never configured with libvirt NAT/forwarding.
- A deployment-owned nftables guard blocks forwarding from the isolated bridge as defense in depth.
- AutoDeploy does not rewrite Windows IP, DNS, gateway, DHCP, NICs, IPv6 state, or snapshots. The guest's existing CAPE baseline remains authoritative.
- CAPE source is modified only after a known layout/anchor passes the compatibility gate; unknown layouts safe-stop before mutation.
- Busy CAPE systems are staged non-disruptively and cut over only after AutoDeploy atomically acquires CAPE machine maintenance ownership.
- Running qcow2 analysis disks are inspected read-only with QEMU shared-image semantics when their live QEMU process holds the normal image lock; AutoDeploy never runs qemu-img repair/conversion against a live analysis disk.
- If CAPE already specifies an analysis snapshot, AutoDeploy validates and preserves it exactly; hosts without a configured snapshot remain supported when the existing CAPE/libvirt baseline is otherwise safe.
- On modular libvirt hosts, an installed standard `clean-traffic` definition with an inactive `virtnwfilterd.socket` is detected as safely activatable; deployment enables/starts that socket before cutover, proves the filter through libvirt, records ownership, and restores the prior runtime state on rollback when safe.
- Every mutable CAPE file is backed up before edit. AutoDeploy-owned appliance/network/firewall resources and extension state are journaled before/after mutation so interrupted operations can be resumed or rolled back safely. Windows guest networking and snapshots are not deployment resources in the route-separated design.
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
5. Route-separation acceptance passes: a route=inetsim positive task reaches only the isolated fake-Internet endpoint, while a route=internet negative task contains no INetSim traffic. Real Internet is available only when CAPE explicitly selects the Internet route.


## Per-task route separation

AutoDeploy must not permanently rewrite a Windows analysis guest into fake-Internet mode. Windows keeps its original CAPE network baseline. The dedicated Ubuntu INetSim appliance remains isolated on the AutoDeploy bridge, and CAPE's native per-task routing selects the path:

- `internet`: normal CAPE Internet routing, with no INetSim attribution.
- `inetsim`: fake Internet through the isolated Ubuntu INetSim appliance.
- `none` / `drop`: no external network path.

The INetSim Network Analysis visual is route-gated and is never enabled for an authoritative `route=internet` task.

### Upgrade from route-global release candidates

Release candidates that permanently configured a Windows fake-Internet NIC/DNS baseline must not be upgraded in place. A committed older deployment is first rolled back with its exact immutable release so its ownership journal can restore the original CAPE files, Windows snapshot/hardware, and remove only resources created by that release. After the state reaches `rolled-back`, the route-separated release may be installed as a fresh transaction. The installer safe-stops if a different release is still committed.
