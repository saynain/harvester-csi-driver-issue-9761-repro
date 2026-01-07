# Harvester CSI Driver Race Condition - Reproduction Setup

This directory contains everything needed to reproduce a race condition in the
Harvester CSI driver that causes volume attachment deadlocks under high
attach/detach workload.

**Related issue:** https://github.com/harvester/harvester/issues/9761

## Overview

The test creates multiple namespaces, each containing:
- A single-instance PostgreSQL cluster (via CNPG operator) with persistent storage
- A CronJob that periodically attaches a separate volume to simulate backup operations

When many CronJobs trigger simultaneously, the high-frequency volume attach/detach
operations expose a race condition in the Harvester CSI driver, causing volumes
to become stuck.

## Prerequisites

- **Downstream RKE2 cluster** running on Harvester v1.4.0+ (tested on v1.6.0)
- **kubectl** configured to access the downstream cluster
- **Storage class** using Harvester CSI driver (default name: `default`)
- **Sufficient cluster resources:**
  - ~256-512Mi RAM per namespace (40 namespaces = 10-20Gi total)
  - ~2Gi storage per namespace (40 namespaces = 80Gi total)

## Quick Start

```bash
# Deploy with defaults (40 namespaces, 'default' storage class)
./setup.sh

# Wait for PostgreSQL clusters to be ready
kubectl get clusters -A -w

# Start the stress test
./scripts/enable-cronjobs.sh
```

## Setup Options

```bash
# Deploy fewer namespaces (for smaller clusters)
./setup.sh --count 20

# Use a different storage class
./setup.sh --storage-class harvester-longhorn

# Preview what would be deployed without applying
./setup.sh --dry-run

# Show all options
./setup.sh --help
```

## How It Works

1. **CNPG Operator** is installed (if not already present)
2. **N namespaces** are created (voltest-01 through voltest-N)
3. Each namespace receives:
   - A PostgreSQL `Cluster` resource (1 instance, 1Gi storage)
   - A `Secret` with database credentials
   - A `CronJob` that mounts a separate 1Gi PVC every 10 minutes
4. When enabled, the CronJobs create high-frequency attach/detach load
5. Under sufficient load, the CSI driver race condition manifests

## Monitoring the Test

### Watch for stuck pods
```bash
kubectl get pods -A | grep -E '(Pending|ContainerCreating)'
```

### Monitor VolumeAttachments
```bash
kubectl get volumeattachments -w
```

### Check CronJob status
```bash
kubectl get cronjobs -A -l app=backup-simulator
kubectl get jobs -A --sort-by=.metadata.creationTimestamp | tail -20
```

### Run the diagnostic script
```bash
../diagnostic/k8s-volume-diagnostic.sh \
  --downstream-context <your-downstream-context> \
  --harvester-context <your-harvester-context> \
  --harvester-namespace <namespace-where-vm-runs>
```

## Adjusting the Test

### Change CronJob frequency
Edit `templates/backup-cronjob.yaml`:
```yaml
spec:
  schedule: "*/10 * * * *"  # Change to */5 for more aggressive testing
```

### Change storage size
Edit `templates/postgres-cluster.yaml` and `templates/backup-cronjob.yaml`:
```yaml
storage:
  size: 1Gi  # Increase if needed
```

### Temporarily pause the test
```bash
./scripts/disable-cronjobs.sh
```

### Resume the test
```bash
./scripts/enable-cronjobs.sh
```

## Scaling

To change the number of namespaces after initial deployment:

```bash
# First cleanup existing deployment
./setup.sh --cleanup

# Then redeploy with new count
./setup.sh --count 60
```

## Cleanup

### Remove all test resources
```bash
./setup.sh --cleanup
```

### Manual cleanup
```bash
# Delete all test namespaces (by label)
kubectl delete ns -l app.kubernetes.io/name=volume-stress-test

# Optionally remove CNPG operator
kubectl delete --server-side -f cnpg-1.27.1.yaml
```

## Expected Failure Symptoms

When the race condition occurs, you may observe:

1. **Pods stuck in `ContainerCreating`** - waiting for volume mount
2. **Multiple VolumeAttachments** for the same PersistentVolume
3. **CSI driver errors** in harvester-csi-driver-controllers logs:
   - "volume already attached to node X"
   - "failed to attach volume"
4. **Longhorn volume conflicts** - volume showing attachment to multiple nodes
5. **Stale hotplug entries** in VM/VMI specs

## File Structure

```
reproduction/
├── README.md                 # This file
├── setup.sh                  # Main setup/cleanup script
├── cnpg-1.27.1.yaml         # CloudNative-PG operator manifest
├── templates/
│   ├── postgres-cluster.yaml # PostgreSQL cluster template
│   ├── secrets.yaml          # Database credentials template
│   └── backup-cronjob.yaml   # Backup simulator CronJob template
├── scripts/
│   ├── enable-cronjobs.sh    # Enable (unsuspend) all CronJobs
│   └── disable-cronjobs.sh   # Disable (suspend) all CronJobs
└── generated/                # Created by setup.sh (gitignored)
    └── ...
```

## Troubleshooting

### CronJobs not triggering
Ensure they are not suspended:
```bash
kubectl get cronjobs -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend
```

### PostgreSQL clusters not becoming ready
Check CNPG operator logs:
```bash
kubectl logs -n cnpg-system deployment/cnpg-controller-manager
```

### Storage class issues
Verify the storage class exists and is the default:
```bash
kubectl get storageclass
```
