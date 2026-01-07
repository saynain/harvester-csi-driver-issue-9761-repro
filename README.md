# Harvester CSI Driver Issue #9761 - Reproduction & Analysis

This repository contains reproduction steps, diagnostic tools, and evidence for a race condition bug in the Harvester CSI driver that causes volume attachment deadlocks under high attach/detach workload.

**GitHub Issue:** https://github.com/harvester/harvester/issues/9761

## The Problem

When running workloads that frequently attach and detach volumes (such as backup CronJobs), the Harvester CSI driver can enter a race condition that causes:

- Pods stuck in `ContainerCreating` state waiting for volume mount
- Multiple VolumeAttachments pointing to the same RWO PersistentVolume
- Stale volume attachments in VM/VMI specs that block new hotplug operations
- Ghost entries in Longhorn's `workloadsStatus` referencing non-existent pods

Once triggered, the condition often requires manual intervention to resolve, as the volume becomes effectively deadlocked.

## Environment

This bug was reproduced in the following environment:

| Component | Version |
|-----------|---------|
| Harvester | v1.6.0 |
| Longhorn | v1.9.1 |
| RKE2 | v1.33.5 |
| CNPG Operator | v1.27.1 |

The test setup creates 40 namespaces, each with:
- A single-instance PostgreSQL cluster (CNPG) with 1Gi persistent storage
- A CronJob that mounts a separate 1Gi volume every 10 minutes

This results in 80 total volumes with high-frequency attach/detach operations.

> **Note:** The "backup" CronJob in the reproduction setup does not perform actual database backups. It simulates backup-like workloads by mounting a PVC and writing test data, creating the attach/detach pattern that triggers the race condition.

## Repository Structure

```
├── diagnostic/              # Volume diagnostic tool
│   ├── k8s-volume-diagnostic.sh
│   └── README.md
│
├── reproduction/            # Test environment setup
│   ├── setup.sh            # Main setup script
│   ├── templates/          # Kubernetes manifests
│   ├── scripts/            # Helper scripts
│   ├── cnpg-1.27.1.yaml   # CNPG operator
│   └── README.md
│
└── evidence/               # Logs and state dumps from failure
    ├── logs/              # CSI controller logs and events
    └── dumps/             # Kubernetes resource state captures
```

## Quick Start

### Reproduce the Issue

```bash
cd reproduction

# Deploy test environment (40 namespaces with postgres + backup CronJobs)
./setup.sh --count 40

# Wait for PostgreSQL clusters to be ready
kubectl get clusters.postgresql.cnpg.io -A -w

# Start the stress test
./scripts/enable-cronjobs.sh
```

See [reproduction/README.md](reproduction/README.md) for detailed instructions.

### Diagnose Volume Issues

```bash
cd diagnostic

# Run diagnostic (summary mode)
./k8s-volume-diagnostic.sh -d <downstream-context> -H <harvester-context> -n <harvester-namespace>

# Run with verbose output
./k8s-volume-diagnostic.sh -d <downstream-context> -H <harvester-context> -n <harvester-namespace> -v
```

See [diagnostic/README.md](diagnostic/README.md) for detailed usage.

## Evidence

The `evidence/` directory contains logs and resource dumps captured during a reproduction of the issue:

- **logs/** - CSI controller logs and Kubernetes events from the failure timeframe
- **dumps/** - PV, VolumeAttachment, VM, VMI, and Longhorn volume state

These can be used to analyze the race condition sequence and identify the root cause.

## Findings

### Summary

Under high attach/detach load (40 namespaces x 2 volumes each = 80 volumes, with CronJobs triggering every 10 minutes), the Harvester CSI driver exhibits a race condition that leads to:

1. **Conflicting operations** - Multiple ControllerPublish/ControllerUnpublish requests for the same volume processed concurrently
2. **Stale VolumeAttachments** - VAs remain attached after pods complete, blocking new attachments
3. **VM/VMI state desync** - Volume exists in VMI spec but not in VM spec (or vice versa)
4. **Deadlocked volumes** - Subsequent pods hang indefinitely in `ContainerCreating`

### Threshold

- **20 namespaces (40 volumes):** No issues observed
- **40 namespaces (80 volumes):** Race condition triggered within ~1 hour of CronJob activity

### Key Error Messages

From VolumeAttachment status:
```
Unable to add volume [pvc-xxx] because volume with that name already exists
```

```
Unable to remove volume [pvc-xxx] because it does not exist
```

From CSI controller logs:
```
Operation cannot be fulfilled on virtualmachine.kubevirt.io "node-name": 
add volume request for volume [pvc-xxx] already exists
```

```
Operation cannot be fulfilled on virtualmachine.kubevirt.io "node-name":
remove volume request for volume [pvc-xxx] already exists and is still being processed
```

### Observed Sequence

1. High volume of CronJob completions trigger simultaneous detach requests
2. CSI driver issues `ControllerUnpublish` for multiple volumes in parallel
3. Some requests fail with "operation already in progress" errors
4. Failed detach leaves stale VolumeAttachment with finalizer
5. Next pod scheduling attempts attach to new node
6. Attach fails because volume "already exists" on previous node
7. Volume becomes stuck - neither attachable nor detachable

### Root Cause Hypothesis

The CSI driver lacks proper serialization for hotplug volume operations on the same VM. When multiple volumes are attached/detached in rapid succession, concurrent modifications to the VM's volume list cause optimistic locking conflicts, leaving resources in inconsistent states.

## Related Links

- [GitHub Issue #9761](https://github.com/harvester/harvester/issues/9761)
- [Harvester CSI Driver Repository](https://github.com/harvester/harvester-csi-driver)
- [Harvester Documentation](https://docs.harvesterhci.io/)

## License

MIT License - feel free to use and adapt the diagnostic script and reproduction setup.
