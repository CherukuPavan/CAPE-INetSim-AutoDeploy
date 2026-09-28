# Recovery

Recovery is ownership-aware and must preserve a usable CAPE host.

## Automatic path

Run the normal installer again. It first inventories the machine and reads prior AutoDeploy state.

- Fresh state: deploy normally.
- Committed state: verify; if unhealthy, repair/upgrade.
- Interrupted or rollback-incomplete state: restore AutoDeploy-owned changes, rediscover the machine, then redeploy.
- Invalid/untrusted state: stop rather than guessing ownership.

## Manual verification

```bash
sudo ./install --status
sudo ./install --verify
```

## Repair

```bash
sudo ./install --repair
```

Repair reuses recorded ownership, never invents a missing Windows baseline snapshot, refreshes the appliance/network only when ledger ownership is proven, validates rooter readiness, acquires CAPE maintenance before CAPE file changes, and restores service state afterward.

## Rollback

Preview:

```bash
sudo ./install --rollback
```

Apply:

```bash
sudo ./install --rollback --apply
```

Rollback restores backed-up CAPE files, Windows pre-deployment snapshot/hardware, maintenance locks and original service states, then removes the AutoDeploy-owned INetSim domain/disk and isolated network. If any rollback step fails, state is marked `rollback-incomplete` so a later installer run can retry safely.
