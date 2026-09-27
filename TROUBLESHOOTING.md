# Troubleshooting

Start with:

```bash
sudo ./install --status
sudo ./install --verify
```

The machine inventory is stored at:

```text
/var/lib/cape-inetsim-autodeploy/autodeploy-inventory.json
```

## Existing or interrupted installation

Running the normal deployment command is the preferred recovery path. The decision engine classifies state as fresh, committed, interrupted, rollback-incomplete, or invalid. A committed deployment is verified first; if unhealthy, safe repair is attempted. An interrupted AutoDeploy-owned deployment is rolled back before rediscovery and fresh deployment.

## GUI/login problems

The accepted appliance must contain user `capeinetsim`, XFCE, LightDM, `xfce.desktop`, `spice-vdagent`, QEMU Guest Agent, and SPICE/Virtio domain devices. Deployment refuses the appliance if these checks fail.

## Rooter problems

AutoDeploy discovers the rooter systemd unit and socket instead of assuming `cape-rooter.service` or `/tmp/cuckoo-rooter`. Verification starts the discovered service when required, waits for the Unix socket, imports CAPE with the discovered CAPE Python interpreter, and performs a structured `nic_available(lo)` probe.

## Slow/interrupted appliance download

The release manifest contains separate compressed-transport and raw-QCOW2 SHA-256 values. Downloads use retry/resume, validate the compressed bytes, run gzip integrity validation, decompress, then validate the raw QCOW2 checksum and format. A partial or corrupt file is never imported.

## Safe recovery

If verification still fails, use `sudo ./install --rollback` to see the ownership-scoped rollback plan. Apply it only with `sudo ./install --rollback --apply`.
