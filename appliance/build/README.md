# Appliance build pipeline

The appliance is a release artifact, not a target-host build.

For v1.0.0 the builder must use a frozen Ubuntu 24.04 LTS x86_64 base, install INetSim and QEMU Guest Agent, run `image-rootfs-prepare.sh`, place `guest-configure.sh` at `/usr/local/src/cape-inetsim-guest-configure`, and then generalize the image before publication.

Before release, run `virt-sysprep` on the powered-off image to remove machine identity, SSH host keys, DHCP state and other host-specific material. Do not remove the guest configuration helper or the INetSim DNS compatibility backup.

The finished QCOW2 is published outside normal Git history. Update `appliance/manifest.json` with the HTTPS artifact URL and exact SHA-256, change `status` to `published`, and tag the repository release. Deployment refuses unpublished or checksum-mismatched artifacts.

The image contains no fixed `192.168.200.0/24` assumption. The isolated NIC address and INetSim bind/default DNS address are configured at deployment through QEMU Guest Agent, using the subnet selected by the host planner.
