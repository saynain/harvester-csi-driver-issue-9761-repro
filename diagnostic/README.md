# Kubernetes Volume Diagnostic Tool

A diagnostic script for analyzing volume attachment issues between downstream RKE2 Kubernetes clusters and Harvester hyperconverged infrastructure.

## Overview

This script diagnoses volume attachment problems in environments using SUSE Harvester with hotplug volumes via the Harvester CSI driver. It analyzes the entire volume stack from downstream Kubernetes through Harvester VMs to Longhorn storage.

**Related issue:** https://github.com/harvester/harvester/issues/9761

## Prerequisites

- **kubectl** - Kubernetes CLI tool
- **jq** - JSON processor (usually pre-installed on most systems)
- **Access to both clusters:**
  - Downstream RKE2 cluster (where workloads run)
  - Harvester management cluster
- **RBAC permissions** to read:
  - PersistentVolumes, PersistentVolumeClaims, Pods, VolumeAttachments (downstream)
  - VMs, VMIs, Namespaces (Harvester)
  - Longhorn volumes (Harvester)

## Installation

```bash
# Make the script executable
chmod +x k8s-volume-diagnostic.sh

# Optionally, add to PATH
cp k8s-volume-diagnostic.sh /usr/local/bin/
```

## Usage

```bash
./k8s-volume-diagnostic.sh -d <downstream-context> -H <harvester-context> -n <namespace> [options]
```

### Required Arguments

| Flag | Description |
|------|-------------|
| `-d, --downstream` | kubectl context for the downstream RKE2 cluster |
| `-H, --harvester` | kubectl context for the Harvester management cluster |
| `-n, --namespace` | Namespace in Harvester where the cluster VMs are located |

### Optional Arguments

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Show detailed per-PV analysis (default: summary only) |
| `--logfile <path>` | Custom log file path (default: `./volume-diagnostic-<context>-<timestamp>.log`) |
| `-V, --version` | Show version number |
| `-h, --help` | Show help message |

### Examples

```bash
# Basic usage - summary only
./k8s-volume-diagnostic.sh -d my-rke2-cluster -H harvester-mgmt -n my-namespace

# Verbose mode - show detailed per-PV analysis
./k8s-volume-diagnostic.sh -d my-rke2-cluster -H harvester-mgmt -n my-namespace -v

# Custom log file location
./k8s-volume-diagnostic.sh -d my-rke2-cluster -H harvester-mgmt -n my-namespace --logfile /tmp/diag.log
```

## What It Checks

For each bound PersistentVolume in the downstream cluster, the script analyzes:

### 1. Downstream PVC Info
- Retrieves the bound PVC namespace, name, and access mode (RWO/RWX)

### 2. Pod Status
- Lists all pods using the PVC
- Distinguishes between active pods (Running, Pending) and completed pods
- Flags multiple active pods on RWO volumes

### 3. VolumeAttachments
- Lists all VolumeAttachments for the PV
- Compares VA node with active pod node
- Detects VA/Pod node mismatches, multiple VAs on RWO, stale VAs

### 4. Harvester PVC/PV Mapping
- Maps downstream PV → Harvester PVC → Harvester PV (Longhorn volume)

### 5. VM/VMI Spec
- Checks which VMs have the volume in spec
- Checks which VMIs have the volume in spec
- Detects multiple VMs/VMIs, VM≠VMI mismatches, stale attachments

### 6. Longhorn Workloads Status
- Checks Longhorn volume's `kubernetesStatus.workloadsStatus`
- Shows hotplug pod attachments
- Verifies hp-volume pods actually exist (detects ghost entries)

### 7. Pending Volume Requests
- Checks for stuck `addVolumeRequests` or `removeVolumeRequests` on VMs
- These indicate incomplete hotplug operations

## Issue Severity Levels

### CRITICAL
Require immediate attention, may cause deadlocks:
- RWO volume with multiple VolumeAttachments
- RWO volume with multiple active pods
- Volume attached to multiple VMs/VMIs
- VA node doesn't match pod node
- Stale VolumeAttachment (blocks new attachments)
- Stale VM/VMI attachment (blocks hotplug operations)
- Pending volumeRequests stuck on VM

### WARNING
Operational issues that may need attention:
- VolumeAttachment exists but no active pods
- Ghost hp-volume pods in Longhorn
- Orphaned VolumeAttachments

### INFO
Cosmetic issues, expected behavior:
- Stale Longhorn workloadsStatus after completed jobs (has `lastPodRefAt`)

## Output Examples

### Healthy Cluster (No Issues)

```
Kubernetes Volume Diagnostic Tool v2.0.0
Started: 2026-01-07T14:30:00+01:00

═══════════════════════════════════════════════════════════════
  Validating Contexts
═══════════════════════════════════════════════════════════════
  Checking downstream context (my-rke2-cluster)... OK
  Checking Harvester context (harvester-mgmt)... OK
  Checking Harvester namespace (my-namespace)... OK

═══════════════════════════════════════════════════════════════
  Fetching Data
═══════════════════════════════════════════════════════════════
  Fetching PVs from downstream cluster...
    Found 40 bound PVs
  Fetching VolumeAttachments from downstream cluster...
    Found 12 VolumeAttachments
  Checking for orphaned VolumeAttachments...
    No orphaned VolumeAttachments found
  Fetching VMs from Harvester (cluster: my-rke2-cluster)...
    Found 3 VMs for cluster my-rke2-cluster
  Fetching VMIs from Harvester (cluster: my-rke2-cluster)...
    Found 3 VMIs for cluster my-rke2-cluster

═══════════════════════════════════════════════════════════════
  Analyzing 40 Bound Persistent Volumes
═══════════════════════════════════════════════════════════════
  (Use -v for detailed per-PV output)

═══════════════════════════════════════════════════════════════
  Summary
═══════════════════════════════════════════════════════════════

  Timing:
    Started:  2026-01-07T14:30:00+01:00
    Finished: 2026-01-07T14:32:15+01:00
    Duration: 2m 15s

  Configuration:
    Downstream context: my-rke2-cluster
    Harvester context:  harvester-mgmt
    Harvester namespace: my-namespace

  Results:
    Bound PVs analyzed: 40
    PVs with issues: 0
    PVs OK: 40

    Critical issues: 0
    Warning issues: 0
    Info issues: 3 (cosmetic/expected)

  ────────────────────────────────────────────────────────────────
  Log file: ./volume-diagnostic-my-rke2-cluster-20260107-143000.log

  Note: This script does not provide cleanup commands for safety.
  Review the output carefully before taking any manual action.
```

### Cluster with Issues

```
Kubernetes Volume Diagnostic Tool v2.0.0
Started: 2026-01-07T14:30:00+01:00

═══════════════════════════════════════════════════════════════
  Validating Contexts
═══════════════════════════════════════════════════════════════
  Checking downstream context (my-rke2-cluster)... OK
  Checking Harvester context (harvester-mgmt)... OK
  Checking Harvester namespace (my-namespace)... OK

═══════════════════════════════════════════════════════════════
  Fetching Data
═══════════════════════════════════════════════════════════════
  Fetching PVs from downstream cluster...
    Found 80 bound PVs
  Fetching VolumeAttachments from downstream cluster...
    Found 45 VolumeAttachments
  Checking for orphaned VolumeAttachments...
    Found 2 orphaned VolumeAttachments (will be listed in summary)
  Fetching VMs from Harvester (cluster: my-rke2-cluster)...
    Found 3 VMs for cluster my-rke2-cluster
  Fetching VMIs from Harvester (cluster: my-rke2-cluster)...
    Found 3 VMIs for cluster my-rke2-cluster

═══════════════════════════════════════════════════════════════
  Analyzing 80 Bound Persistent Volumes
═══════════════════════════════════════════════════════════════
  (Use -v for detailed per-PV output)

═══════════════════════════════════════════════════════════════
  Summary
═══════════════════════════════════════════════════════════════

  Timing:
    Started:  2026-01-07T14:30:00+01:00
    Finished: 2026-01-07T14:35:42+01:00
    Duration: 5m 42s

  Configuration:
    Downstream context: my-rke2-cluster
    Harvester context:  harvester-mgmt
    Harvester namespace: my-namespace

  Results:
    Bound PVs analyzed: 80
    PVs with issues: 8
    PVs OK: 72

    Critical issues: 5
    Warning issues: 4
    Info issues: 12 (cosmetic/expected)

  Node Impact Analysis:
  (Nodes with CRITICAL/WARNING issues - candidates for cordon/restart)

    Node                                          Critical  Warning
    ─────────────────────────────────────────────────────────────
    worker-node-01                                       3        1
    worker-node-02                                       2        0
    worker-node-03                                       0        3

    Recommendation: Node 'worker-node-01' has the most critical issues.
    Consider: kubectl cordon worker-node-01 && kubectl drain worker-node-01 --ignore-daemonsets --delete-emptydir-data

  Orphaned VolumeAttachments (2):
    • csi-abc123 → PV: pvc-old-volume (missing) on worker-node-01
    • csi-def456 → PV: pvc-deleted-pv (missing) on worker-node-02

  Issues by PV:

    ❌ pvc-12345678-abcd-1234-efgh-123456789abc
       CRITICAL: Stale VA (no active pods) [worker-node-01]
       CRITICAL: Stale VM attachment: my-rke2-cluster-worker-01 [my-rke2-cluster-worker-01]

    ❌ pvc-87654321-dcba-4321-hgfe-987654321cba
       CRITICAL: RWO with 2 VAs [worker-node-01 worker-node-02]

    ⚠️  pvc-11111111-2222-3333-4444-555555555555
       WARNING: Stale workloadsStatus (no lastPodRefAt)

    ℹ️  pvc-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
       INFO: Stale workloadsStatus with ghost entries (cosmetic)

  ────────────────────────────────────────────────────────────────
  Log file: ./volume-diagnostic-my-rke2-cluster-20260107-143000.log

  Note: This script does not provide cleanup commands for safety.
  Review the output carefully before taking any manual action.
```

### Verbose Mode Output (per-PV detail)

When running with `-v`, each PV shows detailed analysis:

```
┌─────────────────────────────────────────────────────────────┐
│ PV: pvc-12345678-abcd-1234-efgh-123456789abc
└─────────────────────────────────────────────────────────────┘

  1. Downstream PVC Info
     PVC: voltest-01/pg-test-1
     Access Mode: ReadWriteOnce

  2. Pod Status
     ℹ️  No pod is currently using this PVC

  3. VolumeAttachments
     VA: csi-1234567890abcdef
       Node: worker-node-01
       Attached: true
     ❌ Stale VolumeAttachment - no active pod but VA exists

  4. Harvester PVC/PV
     Harvester PVC: pvc-12345678-abcd-1234-efgh-123456789abc
     Harvester PV (Longhorn): pvc-12345678-abcd-1234-efgh-123456789abc

  5. VM/VMI Spec
     VM: my-rke2-cluster-worker-01
     VMI: my-rke2-cluster-worker-01
     ❌ Stale VM attachment - volume in VM spec but no active pods
     ❌ Stale VMI attachment - volume in VMI spec but no active pods

  6. Longhorn Workloads Status
     PV: pvc-12345678-abcd-1234-efgh-123456789abc (Bound)
     PVC: pvc-12345678-abcd-1234-efgh-123456789abc
     lastPVCRefAt: (none)
     lastPodRefAt: (none)

     workloadsStatus:
       - podName: hp-volume-abcd1234
         podStatus: Running
         workloadName: virt-launcher-my-rke2-cluster-worker-01-abc12
         workloadType: ReplicaSet

     ❌ Stale workloadsStatus without lastPodRefAt
     Pod hp-volume-abcd1234 (DOES NOT EXIST - ghost entry)
     Pod virt-launcher-my-rke2-cluster-worker-01-abc12 (exists, state: Running)
     lastPodRefAt is NOT set - Longhorn may not have recorded pod termination
     This may require manual investigation.

  7. Pending Volume Requests
     ✅ No pending volumeRequests

  ⚠ ISSUES DETECTED
```

## Log Files

A detailed log file is always created, regardless of verbosity mode. The log file contains:
- Full output without ANSI color codes
- Timestamp and configuration details
- Complete per-PV analysis (even when running in summary mode)

Default location: `./volume-diagnostic-<downstream-context>-<YYYYMMDD-HHMMSS>.log`

## Troubleshooting

### "Cannot connect to cluster"
Verify your kubectl contexts are configured correctly:
```bash
kubectl config get-contexts
kubectl --context=<context-name> cluster-info
```

### Script runs slowly
With many PVs, the script makes multiple API calls per PV. This is expected. Use the progress indicator to monitor progress, or check the log file for real-time output.

### Permission errors
Ensure your kubeconfig has appropriate RBAC permissions to read the required resources in both clusters.

## License

MIT License - See the main repository for details.
