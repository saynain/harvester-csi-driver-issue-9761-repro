#!/bin/bash
#
# k8s-volume-diagnostic.sh
# Version: 2.0.0
#
# Diagnoses volume attachment issues between downstream RKE2 Kubernetes clusters
# and Harvester hyperconverged infrastructure. This script is designed for
# environments using SUSE Harvester with hotplug volumes via the Harvester CSI driver.
#
# Usage:
#   ./k8s-volume-diagnostic.sh -d <downstream-context> -H <harvester-context> -n <namespace>
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS SCRIPT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
#
# The script fetches all bound PersistentVolumes from the downstream cluster and
# analyzes each one through multiple layers of the stack: downstream Kubernetes,
# Harvester VMs/VMIs, and Longhorn storage.
#
# For each bound PV in the downstream cluster:
#
# 1. DOWNSTREAM PVC INFO
#    - Retrieves the bound PVC namespace, name, and access mode (RWO/RWX)
#
# 2. POD STATUS
#    - Lists all pods using the PVC
#    - Distinguishes between active pods (Running, Pending) and completed pods
#    - Flags: Multiple active pods on RWO volume
#
# 3. VOLUMEATTACHMENTS
#    - Lists all VolumeAttachments for the PV
#    - Compares VA node with active pod node
#    - Flags: VA/Pod node mismatch, multiple VAs on RWO, stale VA (no active pods)
#
# 4. HARVESTER PVC/PV MAPPING
#    - Maps downstream PV → Harvester PVC → Harvester PV (Longhorn volume)
#
# 5. VM/VMI SPEC
#    - Checks which VMs have the volume in spec.template.spec.volumes
#    - Checks which VMIs have the volume in spec.volumes
#    - Flags: Multiple VMs/VMIs, VM≠VMI mismatch, stale attachment (no active pods)
#
# 6. LONGHORN WORKLOADS STATUS
#    - Checks Longhorn volume's kubernetesStatus.workloadsStatus
#    - Shows hotplug pod attachments
#    - Verifies hp-volume pods actually exist (detects ghost entries)
#    - Note: Stale workloadsStatus with lastPodRefAt set is cosmetic (expected for
#      completed CronJobs) - Longhorn updates this lazily on next attachment
#
# 7. PENDING VOLUME REQUESTS
#    - Checks for stuck addVolumeRequests or removeVolumeRequests on VMs
#    - These indicate incomplete hotplug operations
#
# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE SEVERITY LEVELS
# ═══════════════════════════════════════════════════════════════════════════════
#
# CRITICAL (require immediate attention, may cause deadlocks):
#   - RWO volume with multiple VolumeAttachments
#   - RWO volume with multiple active pods
#   - Volume attached to multiple VMs/VMIs
#   - VA node doesn't match pod node (scheduling conflict)
#   - Stale VolumeAttachment (blocks new attachments)
#   - Stale VM/VMI attachment (blocks hotplug operations)
#   - Pending volumeRequests stuck on VM
#
# WARNING (operational issues, may need attention):
#   - VolumeAttachment exists but no active pods
#   - Ghost hp-volume pods in Longhorn (pod referenced but doesn't exist)
#   - Orphaned VolumeAttachments
#
# INFO (cosmetic, expected behavior):
#   - Stale Longhorn workloadsStatus after completed jobs (has lastPodRefAt)
#
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

# Script version
VERSION="2.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Symbols
OK="✅"
WARN="⚠️ "
ERROR="❌"
INFO="ℹ️ "

# Default values
DOWNSTREAM_CONTEXT=""
HARVESTER_CONTEXT=""
HARVESTER_NAMESPACE=""
VERBOSE=false
LOG_FILE=""
LOG_FILE_SPECIFIED=false

# Timing
START_TIME=""
START_TIMESTAMP=""

# Counters for summary
TOTAL_PVS=0
CURRENT_PV=0
PVS_WITH_ISSUES=0
UNBOUND_PVS=""
UNBOUND_PV_COUNT=0
ORPHANED_VAS=""
ORPHANED_VA_COUNT=0

# Issue tracking - using | as delimiter since it won't appear in PV names
# Format: "PV_NAME|SEVERITY|ISSUE_TEXT|NODE"
# Severity: CRITICAL, WARNING, INFO
declare -a ISSUES_FOUND=()

# Node impact tracking
# Format: "NODE|ISSUE_TYPE|PV_NAME"
declare -a NODE_IMPACTS=()

# Strip ANSI color codes from text
strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Log to file (without colors)
log_to_file() {
    if [[ -n "$LOG_FILE" ]]; then
        echo -e "$1" | strip_colors >> "$LOG_FILE"
    fi
}

# Output to stdout (with colors) and log file (without colors)
# In non-verbose mode, detailed output only goes to log file
output() {
    local message="$1"
    local detail_only="${2:-false}"
    
    log_to_file "$message"
    
    if [[ "$VERBOSE" == "true" || "$detail_only" == "false" ]]; then
        echo -e "$message"
    fi
}

# Output that always goes to stdout (for summary, headers, etc.)
output_always() {
    local message="$1"
    log_to_file "$message"
    echo -e "$message"
}

# Output only in verbose mode to stdout, but always to log
output_verbose() {
    local message="$1"
    log_to_file "$message"
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "$message"
    fi
}

# Show progress indicator (only in non-verbose mode)
show_progress() {
    local current="$1"
    local total="$2"
    local pv_name="$3"
    
    if [[ "$VERBOSE" == "false" ]]; then
        # Truncate PV name if too long
        local display_name="$pv_name"
        if [[ ${#pv_name} -gt 40 ]]; then
            display_name="${pv_name:0:37}..."
        fi
        printf "\r  [%d/%d] Analyzing %s...                    " "$current" "$total" "$display_name" >&2
    fi
}

# Clear progress line
clear_progress() {
    if [[ "$VERBOSE" == "false" ]]; then
        printf "\r                                                                              \r" >&2
    fi
}

usage() {
    cat << EOF
Usage: $0 -d <downstream-context> -H <harvester-context> -n <namespace> [options]

Diagnose volume attachment issues between downstream Kubernetes clusters
and Harvester infrastructure.

Required arguments:
  -d, --downstream       kubectl context for the downstream RKE2 cluster
  -H, --harvester        kubectl context for the Harvester management cluster
  -n, --namespace        Namespace in Harvester where the cluster VMs are located

Optional arguments:
  -v, --verbose          Show detailed per-PV analysis (default: summary only)
  --logfile <path>       Path to log file (default: ./volume-diagnostic-<context>-<timestamp>.log)
  -V, --version          Show version number
  -h, --help             Show this help message

Examples:
  $0 -d <downstream-context> -H <harvester-context> -n <namespace>
  $0 -d <downstream-context> -H <harvester-context> -n <namespace> -v
  $0 -d <downstream-context> -H <harvester-context> -n <namespace> --logfile /tmp/diag.log

Output:
  By default, only a summary is shown. Use -v for detailed per-PV analysis.
  A log file with full details is always created.

For detailed information about what this script checks, view the script header.
EOF
    exit 0
}

show_version() {
    echo "k8s-volume-diagnostic.sh version $VERSION"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--downstream)
            DOWNSTREAM_CONTEXT="$2"
            shift 2
            ;;
        -H|--harvester)
            HARVESTER_CONTEXT="$2"
            shift 2
            ;;
        -n|--namespace)
            HARVESTER_NAMESPACE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --logfile)
            LOG_FILE="$2"
            LOG_FILE_SPECIFIED=true
            shift 2
            ;;
        -V|--version)
            show_version
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$DOWNSTREAM_CONTEXT" || -z "$HARVESTER_CONTEXT" || -z "$HARVESTER_NAMESPACE" ]]; then
    echo "Error: Missing required arguments"
    echo ""
    usage
fi

# Use downstream context as cluster name for Harvester VM filtering
CLUSTER_NAME="$DOWNSTREAM_CONTEXT"

# Set up log file
setup_logging() {
    if [[ "$LOG_FILE_SPECIFIED" == "false" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="./volume-diagnostic-${DOWNSTREAM_CONTEXT}-${timestamp}.log"
    fi
    
    # Create/truncate log file
    : > "$LOG_FILE"
    
    # Log header
    log_to_file "═══════════════════════════════════════════════════════════════"
    log_to_file "Kubernetes Volume Diagnostic Tool v${VERSION}"
    log_to_file "═══════════════════════════════════════════════════════════════"
    log_to_file ""
    log_to_file "Start time: $START_TIMESTAMP"
    log_to_file "Downstream context: $DOWNSTREAM_CONTEXT"
    log_to_file "Harvester context: $HARVESTER_CONTEXT"
    log_to_file "Harvester namespace: $HARVESTER_NAMESPACE"
    log_to_file "Verbose mode: $VERBOSE"
    log_to_file ""
}

# Helper functions
downstream_kubectl() {
    kubectl --context="$DOWNSTREAM_CONTEXT" "$@"
}

harvester_kubectl() {
    kubectl --context="$HARVESTER_CONTEXT" "$@"
}

print_header() {
    output_always ""
    output_always "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    output_always "${BOLD}${BLUE}  $1${NC}"
    output_always "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_pv_header() {
    output_verbose ""
    output_verbose "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    output_verbose "${BOLD}${CYAN}│ PV: $1${NC}"
    output_verbose "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
}

print_ok() {
    output_verbose "  ${GREEN}${OK} $1${NC}"
}

print_warn() {
    output_verbose "  ${YELLOW}${WARN} $1${NC}"
}

print_error() {
    output_verbose "  ${RED}${ERROR} $1${NC}"
}

print_info() {
    output_verbose "  ${BLUE}${INFO} $1${NC}"
}

print_detail() {
    output_verbose "     $1"
}

# Add issue with severity level and optional node
# Usage: add_issue "pvc-xxx" "CRITICAL" "Issue description" ["node-name"]
add_issue() {
    local pv="$1"
    local severity="$2"
    local issue="$3"
    local node="${4:-}"
    
    ISSUES_FOUND+=("${pv}|${severity}|${issue}|${node}")
    
    # Track node impact for CRITICAL and WARNING issues
    if [[ -n "$node" && ("$severity" == "CRITICAL" || "$severity" == "WARNING") ]]; then
        NODE_IMPACTS+=("${node}|${severity}|${pv}")
    fi
}

# Validate contexts exist
validate_contexts() {
    print_header "Validating Contexts"

    echo -n "  Checking downstream context ($DOWNSTREAM_CONTEXT)... "
    log_to_file "  Checking downstream context ($DOWNSTREAM_CONTEXT)... "
    if downstream_kubectl cluster-info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        log_to_file "OK"
    else
        echo -e "${RED}FAILED${NC}"
        log_to_file "FAILED"
        echo "  Error: Cannot connect to downstream cluster with context: $DOWNSTREAM_CONTEXT"
        exit 1
    fi

    echo -n "  Checking Harvester context ($HARVESTER_CONTEXT)... "
    log_to_file "  Checking Harvester context ($HARVESTER_CONTEXT)... "
    if harvester_kubectl cluster-info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        log_to_file "OK"
    else
        echo -e "${RED}FAILED${NC}"
        log_to_file "FAILED"
        echo "  Error: Cannot connect to Harvester cluster with context: $HARVESTER_CONTEXT"
        exit 1
    fi

    echo -n "  Checking Harvester namespace ($HARVESTER_NAMESPACE)... "
    log_to_file "  Checking Harvester namespace ($HARVESTER_NAMESPACE)... "
    if harvester_kubectl get namespace "$HARVESTER_NAMESPACE" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        log_to_file "OK"
    else
        echo -e "${RED}FAILED${NC}"
        log_to_file "FAILED"
        echo "  Error: Namespace $HARVESTER_NAMESPACE does not exist in Harvester"
        exit 1
    fi
}

# Analyze a single PV completely
analyze_pv() {
    local pv="$1"
    local va_json="$2"
    local vm_json="$3"
    local vmi_json="$4"

    local pv_has_issues=false

    print_pv_header "$pv"

    # ─────────────────────────────────────────────────────────────
    # Step 1: Get PVC info from downstream PV
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}1. Downstream PVC Info${NC}"

    local pvc_namespace pvc_name access_mode
    pvc_namespace=$(downstream_kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || echo "")
    pvc_name=$(downstream_kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.name}' 2>/dev/null || echo "")
    access_mode=$(downstream_kubectl get pv "$pv" -o jsonpath='{.spec.accessModes[0]}' 2>/dev/null || echo "Unknown")

    if [[ -z "$pvc_namespace" || -z "$pvc_name" ]]; then
        print_error "PV has no claimRef (unbound or released)"
        add_issue "$pv" "CRITICAL" "No claimRef"
        pv_has_issues=true
        return
    fi

    print_detail "PVC: ${pvc_namespace}/${pvc_name}"
    print_detail "Access Mode: ${access_mode}"

    # ─────────────────────────────────────────────────────────────
    # Step 2: Check pod status using this PVC
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}2. Pod Status${NC}"

    local pod_info
    pod_info=$(downstream_kubectl get pods -n "$pvc_namespace" -o json 2>/dev/null | jq -r --arg pvc "$pvc_name" '
        .items[] |
        select(.spec.volumes[]?.persistentVolumeClaim?.claimName == $pvc) |
        "\(.metadata.name)\t\(.spec.nodeName // "unscheduled")\t\(.status.phase)"
    ')

    local pod_name="" pod_node="" pod_phase=""
    local pod_count=0
    local active_pod_count=0
    local active_pod_nodes=()

    if [[ -z "$pod_info" ]]; then
        print_info "No pod is currently using this PVC"
    else
        while IFS=$'\t' read -r p_name p_node p_phase; do
            ((pod_count++))

            # Check if pod is active (not Completed/Succeeded)
            local is_active=true
            if [[ "$p_phase" == "Succeeded" || "$p_phase" == "Completed" ]]; then
                is_active=false
                print_detail "Pod: ${p_name} (${p_phase} - inactive)"
                print_detail "  Node: ${p_node}"
            else
                ((active_pod_count++))
                active_pod_nodes+=("$p_node")
                print_detail "Pod: ${p_name}"
                print_detail "  Node: ${p_node}"
                print_detail "  Phase: ${p_phase}"

                # Store first active pod for comparison
                if [[ -z "$pod_name" ]]; then
                    pod_name="$p_name"
                    pod_node="$p_node"
                    pod_phase="$p_phase"
                fi
            fi

            # Check for problematic pod states
            if [[ "$p_phase" == "Pending" ]]; then
                print_warn "Pod is Pending - may be waiting for volume"
                pv_has_issues=true
            fi
        done <<< "$pod_info"

        # Only flag as issue if multiple ACTIVE pods on RWO
        if [[ $active_pod_count -gt 1 && "$access_mode" == "ReadWriteOnce" ]]; then
            print_error "Multiple active pods using RWO volume!"
            add_issue "$pv" "CRITICAL" "Multiple active pods on RWO" "$pod_node"
            pv_has_issues=true
        fi

        # Summary of pod counts
        if [[ $active_pod_count -eq 0 && $pod_count -gt 0 ]]; then
            print_info "No active pods (${pod_count} completed)"
        elif [[ $pod_count -gt $active_pod_count ]]; then
            local completed_count=$((pod_count - active_pod_count))
            print_detail "(${completed_count} completed pod(s) also reference this PVC)"
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # Step 3: Check VolumeAttachments
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}3. VolumeAttachments${NC}"

    local va_list
    va_list=$(echo "$va_json" | jq -r --arg pv "$pv" '
        .items[] |
        select(.spec.source.persistentVolumeName == $pv) |
        "\(.metadata.name)\t\(.spec.nodeName)\t\(.status.attached)"
    ')

    local va_count=0
    local va_attached_count=0
    local va_nodes=()

    if [[ -z "$va_list" ]]; then
        # No VA is only a problem if there ARE active pods
        if [[ $active_pod_count -gt 0 ]]; then
            print_warn "No VolumeAttachment found for this PV (but active pod exists!)"
            add_issue "$pv" "WARNING" "No VA but active pod exists" "$pod_node"
            pv_has_issues=true
        else
            print_ok "No VolumeAttachment (expected - no active pods)"
        fi
    else
        while IFS=$'\t' read -r va_name va_node va_attached; do
            ((va_count++))
            [[ "$va_attached" == "true" ]] && ((va_attached_count++))
            va_nodes+=("$va_node")

            local status_color="${GREEN}"
            [[ "$va_attached" != "true" ]] && status_color="${YELLOW}"

            print_detail "VA: ${va_name}"
            print_detail "  Node: ${va_node}"
            output_verbose "     Attached: ${status_color}${va_attached}${NC}"

            # Compare with active pod node
            if [[ -n "$pod_node" && "$pod_node" != "unscheduled" ]]; then
                if [[ "$va_node" != "$pod_node" ]]; then
                    print_error "VA node ($va_node) != Pod node ($pod_node)"
                    add_issue "$pv" "CRITICAL" "VA/Pod node mismatch: VA=$va_node, Pod=$pod_node" "$va_node"
                    pv_has_issues=true
                fi
            fi

            # Check for stale VA (attached but no active pod)
            if [[ $active_pod_count -eq 0 ]]; then
                print_error "Stale VolumeAttachment - no active pod but VA exists"
                add_issue "$pv" "CRITICAL" "Stale VA (no active pods)" "$va_node"
                pv_has_issues=true
            elif [[ "$va_attached" != "true" && -n "$pod_name" ]]; then
                print_warn "VA not attached but active pod exists"
                pv_has_issues=true
            fi

        done <<< "$va_list"

        # Check for multiple VAs on RWO volume
        if [[ $va_count -gt 1 && "$access_mode" == "ReadWriteOnce" ]]; then
            print_error "RWO volume has $va_count VolumeAttachments!"
            for va_node in "${va_nodes[@]}"; do
                add_issue "$pv" "CRITICAL" "RWO with $va_count VAs" "$va_node"
            done
            pv_has_issues=true
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # Step 4: Check Harvester PVC -> PV mapping
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}4. Harvester PVC/PV${NC}"

    local harvester_pv
    harvester_pv=$(harvester_kubectl get pvc -n "$HARVESTER_NAMESPACE" "$pv" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")

    if [[ -z "$harvester_pv" ]]; then
        print_warn "Harvester PVC not found for $pv"
        add_issue "$pv" "WARNING" "No Harvester PVC"
        pv_has_issues=true
    else
        print_detail "Harvester PVC: ${pv}"
        print_detail "Harvester PV (Longhorn): ${harvester_pv}"
    fi

    # ─────────────────────────────────────────────────────────────
    # Step 5: Check VM and VMI specs
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}5. VM/VMI Spec${NC}"

    local vms_with_volume vmis_with_volume
    vms_with_volume=$(echo "$vm_json" | jq -r --arg pvc "$pv" '
        .items[] |
        select(.spec.template.spec.volumes[]?.name == $pvc) |
        .metadata.name
    ')

    vmis_with_volume=$(echo "$vmi_json" | jq -r --arg pvc "$pv" '
        .items[] |
        select(.spec.volumes[]?.name == $pvc) |
        .metadata.name
    ')

    local vm_count=0 vmi_count=0
    local vm_list=() vmi_list=()

    if [[ -n "$vms_with_volume" ]]; then
        while IFS= read -r vm; do
            ((vm_count++))
            vm_list+=("$vm")
            print_detail "VM: ${vm}"
        done <<< "$vms_with_volume"
    else
        print_detail "VM: (none)"
    fi

    if [[ -n "$vmis_with_volume" ]]; then
        while IFS= read -r vmi; do
            ((vmi_count++))
            vmi_list+=("$vmi")
            print_detail "VMI: ${vmi}"
        done <<< "$vmis_with_volume"
    else
        print_detail "VMI: (none)"
    fi

    # Check for mismatches
    if [[ $vm_count -gt 1 ]]; then
        print_error "Multiple VMs have this volume in spec!"
        add_issue "$pv" "CRITICAL" "Multiple VMs: ${vm_list[*]}"
        pv_has_issues=true
    fi

    if [[ $vmi_count -gt 1 ]]; then
        print_error "Multiple VMIs have this volume in spec!"
        add_issue "$pv" "CRITICAL" "Multiple VMIs: ${vmi_list[*]}"
        pv_has_issues=true
    fi

    # VM/VMI mismatch
    if [[ $vm_count -ne $vmi_count ]]; then
        print_error "VM count ($vm_count) != VMI count ($vmi_count)"
        add_issue "$pv" "CRITICAL" "VM/VMI count mismatch ($vm_count vs $vmi_count)"
        pv_has_issues=true
    elif [[ $vm_count -eq 1 && $vmi_count -eq 1 ]]; then
        if [[ "${vm_list[0]}" != "${vmi_list[0]}" ]]; then
            print_error "VM (${vm_list[0]}) != VMI (${vmi_list[0]})"
            add_issue "$pv" "CRITICAL" "VM/VMI name mismatch"
            pv_has_issues=true
        fi
    fi

    # Check for stale VM/VMI attachments when no active pods
    if [[ $active_pod_count -eq 0 ]]; then
        if [[ $vm_count -gt 0 ]]; then
            print_error "Stale VM attachment - volume in VM spec but no active pods"
            add_issue "$pv" "CRITICAL" "Stale VM attachment: ${vm_list[*]}" "${vm_list[0]}"
            pv_has_issues=true
        fi
        if [[ $vmi_count -gt 0 ]]; then
            print_error "Stale VMI attachment - volume in VMI spec but no active pods"
            add_issue "$pv" "CRITICAL" "Stale VMI attachment: ${vmi_list[*]}" "${vmi_list[0]}"
            pv_has_issues=true
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # Step 6: Check Longhorn workloadsStatus
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}6. Longhorn Workloads Status${NC}"

    if [[ -n "$harvester_pv" ]]; then
        local longhorn_json
        longhorn_json=$(harvester_kubectl get volumes.longhorn.io -n longhorn-system "$harvester_pv" -o json 2>/dev/null || echo "{}")
        
        local longhorn_status
        longhorn_status=$(echo "$longhorn_json" | jq '.status.kubernetesStatus // null')

        if [[ "$longhorn_status" != "null" && -n "$longhorn_status" ]]; then
            # Extract all kubernetesStatus fields
            local last_pvc_ref_at last_pod_ref_at lh_pv_name lh_pv_status lh_pvc_name
            last_pvc_ref_at=$(echo "$longhorn_status" | jq -r '.lastPVCRefAt // ""')
            last_pod_ref_at=$(echo "$longhorn_status" | jq -r '.lastPodRefAt // ""')
            lh_pv_name=$(echo "$longhorn_status" | jq -r '.pvName // ""')
            lh_pv_status=$(echo "$longhorn_status" | jq -r '.pvStatus // ""')
            lh_pvc_name=$(echo "$longhorn_status" | jq -r '.pvcName // ""')
            
            # Display kubernetesStatus metadata
            print_detail "PV: ${lh_pv_name} (${lh_pv_status})"
            print_detail "PVC: ${lh_pvc_name}"
            if [[ -n "$last_pvc_ref_at" && "$last_pvc_ref_at" != "null" ]]; then
                print_detail "lastPVCRefAt: ${last_pvc_ref_at}"
            else
                print_detail "lastPVCRefAt: (none)"
            fi
            if [[ -n "$last_pod_ref_at" && "$last_pod_ref_at" != "null" ]]; then
                print_detail "lastPodRefAt: ${last_pod_ref_at}"
            else
                print_detail "lastPodRefAt: (none)"
            fi

            local workloads_status
            workloads_status=$(echo "$longhorn_status" | jq -r '.workloadsStatus // []')

            if [[ "$workloads_status" != "[]" && "$workloads_status" != "null" ]]; then
                local lh_vms=()
                local lh_workload_count=0
                local ghost_pods=()
                local ghost_virt_launchers=()
                
                # Arrays to store workload info for summary
                declare -A workload_pod_exists
                declare -A workload_virt_launcher_exists
                declare -A workload_pod_status
                declare -A workload_virt_launcher_name

                output_verbose ""
                print_detail "${BOLD}workloadsStatus:${NC}"

                while IFS= read -r workload_line; do
                    [[ -z "$workload_line" ]] && continue
                    ((lh_workload_count++))
                    local lh_pod lh_pod_status lh_workload lh_workload_type
                    lh_pod=$(echo "$workload_line" | jq -r '.podName')
                    lh_pod_status=$(echo "$workload_line" | jq -r '.podStatus')
                    lh_workload=$(echo "$workload_line" | jq -r '.workloadName')
                    lh_workload_type=$(echo "$workload_line" | jq -r '.workloadType')

                    # Extract VM name from virt-launcher-<vm-name>-<hash>
                    local lh_vm
                    lh_vm=$(echo "$lh_workload" | sed 's/virt-launcher-\(.*\)-[a-z0-9]*$/\1/')
                    lh_vms+=("$lh_vm")
                    
                    # Store workload info
                    workload_pod_status["$lh_pod"]="$lh_pod_status"
                    workload_virt_launcher_name["$lh_pod"]="$lh_workload"

                    # Check if hp-volume pod exists
                    local hp_pod_exists="true"
                    if [[ "$lh_pod" == hp-volume-* ]]; then
                        if ! harvester_kubectl get pod -n "$HARVESTER_NAMESPACE" "$lh_pod" &>/dev/null; then
                            hp_pod_exists="false"
                            ghost_pods+=("$lh_pod")
                        fi
                    fi
                    workload_pod_exists["$lh_pod"]="$hp_pod_exists"
                    
                    # Check if virt-launcher pod exists
                    local virt_launcher_exists="true"
                    if [[ "$lh_workload" == virt-launcher-* ]]; then
                        if ! harvester_kubectl get pod -n "$HARVESTER_NAMESPACE" "$lh_workload" &>/dev/null; then
                            virt_launcher_exists="false"
                            ghost_virt_launchers+=("$lh_workload")
                        fi
                    fi
                    workload_virt_launcher_exists["$lh_pod"]="$virt_launcher_exists"

                    # Display workload entry with all fields (clean, no indicators)
                    print_detail "  - podName: ${lh_pod}"
                    print_detail "    podStatus: ${lh_pod_status}"
                    print_detail "    workloadName: ${lh_workload}"
                    print_detail "    workloadType: ${lh_workload_type}"
                done < <(echo "$workloads_status" | jq -c '.[]')

                output_verbose ""

                # Check for stale Longhorn workloadsStatus when no active pods
                # This determines the severity of ghost pods as well
                local stale_is_expected=false
                if [[ $active_pod_count -eq 0 && $lh_workload_count -gt 0 ]]; then
                    # Check if this is expected (has lastPodRefAt) or problematic
                    if [[ -n "$last_pod_ref_at" && "$last_pod_ref_at" != "null" ]]; then
                        # This is expected behavior - Longhorn recorded when pod ended
                        stale_is_expected=true
                    fi
                fi

                # Determine if we have any ghost entries (hp-volume or virt-launcher)
                local has_ghost_entries=false
                if [[ ${#ghost_pods[@]} -gt 0 || ${#ghost_virt_launchers[@]} -gt 0 ]]; then
                    has_ghost_entries=true
                fi

                # Flag ghost entries - severity depends on whether stale status is expected
                if [[ "$has_ghost_entries" == "true" || ($active_pod_count -eq 0 && $lh_workload_count -gt 0) ]]; then
                    if [[ "$stale_is_expected" == "true" ]]; then
                        # Cosmetic - lastPodRefAt is set
                        print_info "Stale workloadsStatus with ghost entries"
                        
                        # Show details for each workload entry
                        for lh_pod in "${!workload_pod_exists[@]}"; do
                            local pod_exists="${workload_pod_exists[$lh_pod]}"
                            local vl_exists="${workload_virt_launcher_exists[$lh_pod]}"
                            local vl_name="${workload_virt_launcher_name[$lh_pod]}"
                            local pod_status="${workload_pod_status[$lh_pod]}"
                            
                            if [[ "$pod_exists" == "false" ]]; then
                                output_verbose "     Pod ${lh_pod} ${RED}(DOES NOT EXIST - ghost entry)${NC}"
                            else
                                output_verbose "     Pod ${lh_pod} ${GREEN}(exists, state: ${pod_status})${NC}"
                            fi
                            
                            # Get virt-launcher state if it exists
                            local vl_state=""
                            if [[ "$vl_exists" == "true" ]]; then
                                vl_state=$(harvester_kubectl get pod -n "$HARVESTER_NAMESPACE" "$vl_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                            fi
                            
                            if [[ "$vl_exists" == "false" ]]; then
                                output_verbose "     Pod ${vl_name} ${RED}(DOES NOT EXIST - ghost entry)${NC}"
                            else
                                output_verbose "     Pod ${vl_name} ${GREEN}(exists, state: ${vl_state})${NC}"
                            fi
                        done
                        
                        print_detail "lastPodRefAt is set (${last_pod_ref_at})"
                        output_verbose "     ${BLUE}This will most likely be cleaned up automatically on next volume attachment.${NC}"
                        output_verbose "     ${BLUE}Should not cause any further issues.${NC}"
                        add_issue "$pv" "INFO" "Stale workloadsStatus with ghost entries (cosmetic)"
                    else
                        # Potentially problematic - no lastPodRefAt
                        print_error "Stale workloadsStatus without lastPodRefAt"
                        
                        # Show details for each workload entry
                        for lh_pod in "${!workload_pod_exists[@]}"; do
                            local pod_exists="${workload_pod_exists[$lh_pod]}"
                            local vl_exists="${workload_virt_launcher_exists[$lh_pod]}"
                            local vl_name="${workload_virt_launcher_name[$lh_pod]}"
                            local pod_status="${workload_pod_status[$lh_pod]}"
                            
                            if [[ "$pod_exists" == "false" ]]; then
                                output_verbose "     Pod ${lh_pod} ${RED}(DOES NOT EXIST - ghost entry)${NC}"
                            else
                                output_verbose "     Pod ${lh_pod} ${GREEN}(exists, state: ${pod_status})${NC}"
                            fi
                            
                            # Get virt-launcher state if it exists
                            local vl_state=""
                            if [[ "$vl_exists" == "true" ]]; then
                                vl_state=$(harvester_kubectl get pod -n "$HARVESTER_NAMESPACE" "$vl_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                            fi
                            
                            if [[ "$vl_exists" == "false" ]]; then
                                output_verbose "     Pod ${vl_name} ${RED}(DOES NOT EXIST - ghost entry)${NC}"
                            else
                                output_verbose "     Pod ${vl_name} ${GREEN}(exists, state: ${vl_state})${NC}"
                            fi
                        done
                        
                        print_detail "lastPodRefAt is NOT set - Longhorn may not have recorded pod termination"
                        output_verbose "     ${YELLOW}This may require manual investigation.${NC}"
                        add_issue "$pv" "WARNING" "Stale workloadsStatus (no lastPodRefAt)"
                        pv_has_issues=true
                    fi
                fi

                # Compare Longhorn VMs with VM spec
                if [[ ${#lh_vms[@]} -gt 0 && $vm_count -eq 1 ]]; then
                    local lh_vm_match=false
                    for lh_vm in "${lh_vms[@]}"; do
                        if [[ "$lh_vm" == "${vm_list[0]}" ]]; then
                            lh_vm_match=true
                            break
                        fi
                    done
                    if [[ "$lh_vm_match" == "false" ]]; then
                        print_error "Longhorn workload VM doesn't match VM spec"
                        add_issue "$pv" "CRITICAL" "Longhorn/VM spec mismatch"
                        pv_has_issues=true
                    fi
                fi

                # Check for multiple Longhorn attachments
                if [[ ${#lh_vms[@]} -gt 1 ]]; then
                    # Get unique VMs
                    local unique_lh_vms
                    unique_lh_vms=$(printf '%s\n' "${lh_vms[@]}" | sort -u)
                    local unique_count
                    unique_count=$(echo "$unique_lh_vms" | wc -l)
                    if [[ $unique_count -gt 1 ]]; then
                        print_error "Longhorn shows volume attached to multiple VMs!"
                        add_issue "$pv" "CRITICAL" "Longhorn multi-VM attachment"
                        pv_has_issues=true
                    fi
                fi
            else
                # No workloadsStatus is expected when no active pods
                output_verbose ""
                print_detail "workloadsStatus: (empty)"
                if [[ $active_pod_count -eq 0 ]]; then
                    print_ok "No workloadsStatus (expected - no active pods)"
                else
                    print_detail "(no workloadsStatus - may not be hotplugged)"
                fi
            fi
        else
            print_warn "Could not retrieve Longhorn status"
        fi
    else
        print_detail "(skipped - no Harvester PV)"
    fi

    # ─────────────────────────────────────────────────────────────
    # Step 7: Check pending volumeRequests
    # ─────────────────────────────────────────────────────────────
    output_verbose "\n  ${BOLD}7. Pending Volume Requests${NC}"

    local add_requests remove_requests
    add_requests=$(echo "$vm_json" | jq -r --arg pvc "$pv" '
        .items[] |
        select(.status.volumeRequests[]?.addVolumeOptions?.name == $pvc) |
        .metadata.name
    ')

    remove_requests=$(echo "$vm_json" | jq -r --arg pvc "$pv" '
        .items[] |
        select(.status.volumeRequests[]?.removeVolumeOptions?.name == $pvc) |
        .metadata.name
    ')

    local has_pending=false

    if [[ -n "$add_requests" ]]; then
        has_pending=true
        while IFS= read -r vm; do
            print_warn "Pending addVolumeRequest on VM: ${vm}"
            add_issue "$pv" "CRITICAL" "Pending addVolumeRequest on $vm" "$vm"
            pv_has_issues=true
        done <<< "$add_requests"
    fi

    if [[ -n "$remove_requests" ]]; then
        has_pending=true
        while IFS= read -r vm; do
            print_warn "Pending removeVolumeRequest on VM: ${vm}"
            add_issue "$pv" "CRITICAL" "Pending removeVolumeRequest on $vm" "$vm"
            pv_has_issues=true
        done <<< "$remove_requests"
    fi

    if [[ "$has_pending" == "false" ]]; then
        print_ok "No pending volumeRequests"
    fi

    # ─────────────────────────────────────────────────────────────
    # Summary for this PV
    # ─────────────────────────────────────────────────────────────
    output_verbose ""
    if [[ "$pv_has_issues" == "true" ]]; then
        output_verbose "  ${RED}${BOLD}⚠ ISSUES DETECTED${NC}"
        ((PVS_WITH_ISSUES++))
    else
        output_verbose "  ${GREEN}${BOLD}✓ OK${NC}"
    fi
}

# Main analysis function
run_analysis() {
    print_header "Fetching Data"

    # Fetch all data upfront
    output_always "  Fetching PVs from downstream cluster..."
    local pv_json
    pv_json=$(downstream_kubectl get pv -o json)

    # Get bound PVs for analysis
    local pv_list
    pv_list=$(echo "$pv_json" | jq -r '.items[] | select(.status.phase == "Bound") | .metadata.name' | sort -u)

    TOTAL_PVS=$(echo "$pv_list" | grep -c . || echo "0")
    output_always "    Found $TOTAL_PVS bound PVs"

    # Check for unbound PVs and store for summary
    UNBOUND_PVS=$(echo "$pv_json" | jq -r '.items[] | select(.status.phase != "Bound") | "\(.metadata.name)\t\(.status.phase)"')
    UNBOUND_PV_COUNT=$(echo "$pv_json" | jq '[.items[] | select(.status.phase != "Bound")] | length')

    if [[ $UNBOUND_PV_COUNT -gt 0 ]]; then
        output_always "    Found ${YELLOW}$UNBOUND_PV_COUNT unbound PVs${NC} (will be listed in summary)"
    fi

    output_always "  Fetching VolumeAttachments from downstream cluster..."
    local va_json
    va_json=$(downstream_kubectl get volumeattachments -o json)

    local va_count
    va_count=$(echo "$va_json" | jq '.items | length')
    output_always "    Found $va_count VolumeAttachments"

    # Check for orphaned VolumeAttachments (pointing to non-existent PVs)
    output_always "  Checking for orphaned VolumeAttachments..."
    local all_pv_names
    all_pv_names=$(echo "$pv_json" | jq -r '.items[].metadata.name')

    local orphaned_vas=""
    ORPHANED_VA_COUNT=0

    while IFS=$'\t' read -r va_name va_pv va_node; do
        [[ -z "$va_name" ]] && continue
        # Check if the PV exists
        if ! echo "$all_pv_names" | grep -q "^${va_pv}$"; then
            ((ORPHANED_VA_COUNT++))
            orphaned_vas+="${va_name}|${va_pv}|${va_node}\n"
            add_issue "orphaned-va-${va_name}" "WARNING" "Orphaned VA → non-existent PV ${va_pv}" "$va_node"
        fi
    done < <(echo "$va_json" | jq -r '.items[] | "\(.metadata.name)\t\(.spec.source.persistentVolumeName)\t\(.spec.nodeName)"')

    ORPHANED_VAS="$orphaned_vas"

    if [[ $ORPHANED_VA_COUNT -gt 0 ]]; then
        output_always "    Found ${RED}$ORPHANED_VA_COUNT orphaned VolumeAttachments${NC} (will be listed in summary)"
        ((PVS_WITH_ISSUES += ORPHANED_VA_COUNT))
    else
        output_always "    No orphaned VolumeAttachments found"
    fi

    output_always "  Fetching VMs from Harvester (cluster: $CLUSTER_NAME)..."
    local vm_json
    vm_json=$(harvester_kubectl get vm -n "$HARVESTER_NAMESPACE" -l "guestcluster.harvesterhci.io/name=$CLUSTER_NAME" -o json)

    local vm_count
    vm_count=$(echo "$vm_json" | jq '.items | length')
    output_always "    Found $vm_count VMs for cluster $CLUSTER_NAME"

    output_always "  Fetching VMIs from Harvester (cluster: $CLUSTER_NAME)..."
    local vmi_json
    vmi_json=$(harvester_kubectl get vmi -n "$HARVESTER_NAMESPACE" -l "guestcluster.harvesterhci.io/name=$CLUSTER_NAME" -o json)

    local vmi_count
    vmi_count=$(echo "$vmi_json" | jq '.items | length')
    output_always "    Found $vmi_count VMIs for cluster $CLUSTER_NAME"

    print_header "Analyzing $TOTAL_PVS Bound Persistent Volumes"
    
    if [[ "$VERBOSE" == "false" ]]; then
        output_always "  ${DIM}(Use -v for detailed per-PV output)${NC}"
    fi

    # Analyze each PV
    CURRENT_PV=0
    while IFS= read -r pv; do
        [[ -z "$pv" ]] && continue
        ((CURRENT_PV++))
        show_progress "$CURRENT_PV" "$TOTAL_PVS" "$pv"
        analyze_pv "$pv" "$va_json" "$vm_json" "$vmi_json"
    done <<< "$pv_list"
    
    clear_progress
}

# Generate summary
generate_summary() {
    print_header "Summary"

    # Calculate duration
    local end_time end_timestamp duration
    end_time=$(date +%s)
    end_timestamp=$(date -Iseconds)
    duration=$((end_time - START_TIME))
    local duration_min=$((duration / 60))
    local duration_sec=$((duration % 60))

    output_always "\n  ${BOLD}Timing:${NC}"
    output_always "    Started:  $START_TIMESTAMP"
    output_always "    Finished: $end_timestamp"
    output_always "    Duration: ${duration_min}m ${duration_sec}s"

    output_always "\n  ${BOLD}Configuration:${NC}"
    output_always "    Downstream context: $DOWNSTREAM_CONTEXT"
    output_always "    Harvester context:  $HARVESTER_CONTEXT"
    output_always "    Harvester namespace: $HARVESTER_NAMESPACE"

    # Count issues by severity
    local critical_count=0
    local warning_count=0
    local info_count=0
    
    for issue in "${ISSUES_FOUND[@]}"; do
        local severity
        severity=$(echo "$issue" | cut -d'|' -f2)
        case "$severity" in
            CRITICAL) ((critical_count++)) ;;
            WARNING) ((warning_count++)) ;;
            INFO) ((info_count++)) ;;
        esac
    done

    output_always "\n  ${BOLD}Results:${NC}"
    output_always "    Bound PVs analyzed: $TOTAL_PVS"
    output_always "    PVs with issues: ${RED}${PVS_WITH_ISSUES}${NC}"
    output_always "    PVs OK: ${GREEN}$((TOTAL_PVS - PVS_WITH_ISSUES))${NC}"
    output_always ""
    output_always "    ${RED}Critical issues: ${critical_count}${NC}"
    output_always "    ${YELLOW}Warning issues: ${warning_count}${NC}"
    output_always "    ${BLUE}Info issues: ${info_count}${NC} ${DIM}(cosmetic/expected)${NC}"

    # ─────────────────────────────────────────────────────────────
    # Node Impact Analysis
    # ─────────────────────────────────────────────────────────────
    if [[ ${#NODE_IMPACTS[@]} -gt 0 ]]; then
        output_always "\n  ${BOLD}${MAGENTA}Node Impact Analysis:${NC}"
        output_always "  ${DIM}(Nodes with CRITICAL/WARNING issues - candidates for cordon/restart)${NC}"
        
        # Count issues per node
        declare -A node_critical_count
        declare -A node_warning_count
        declare -A node_pvs
        
        for impact in "${NODE_IMPACTS[@]}"; do
            local node severity pv_name
            node=$(echo "$impact" | cut -d'|' -f1)
            severity=$(echo "$impact" | cut -d'|' -f2)
            pv_name=$(echo "$impact" | cut -d'|' -f3)
            
            [[ -z "$node" ]] && continue
            
            # Initialize if needed
            [[ -z "${node_critical_count[$node]:-}" ]] && node_critical_count[$node]=0
            [[ -z "${node_warning_count[$node]:-}" ]] && node_warning_count[$node]=0
            
            case "$severity" in
                CRITICAL) ((node_critical_count[$node]++)) ;;
                WARNING) ((node_warning_count[$node]++)) ;;
            esac
            
            # Track PVs per node (avoid duplicates)
            if [[ -z "${node_pvs[$node]:-}" ]]; then
                node_pvs[$node]="$pv_name"
            elif [[ ! "${node_pvs[$node]}" =~ $pv_name ]]; then
                node_pvs[$node]="${node_pvs[$node]}, $pv_name"
            fi
        done
        
        # Sort nodes by critical count (descending), then warning count
        local sorted_nodes
        sorted_nodes=$(for node in "${!node_critical_count[@]}"; do
            echo "${node_critical_count[$node]}|${node_warning_count[$node]}|$node"
        done | sort -t'|' -k1,1nr -k2,2nr | cut -d'|' -f3)
        
        output_always ""
        output_always "    ${BOLD}$(printf '%-45s %8s %8s' 'Node' 'Critical' 'Warning')${NC}"
        output_always "    ─────────────────────────────────────────────────────────────"
        
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            local c_count="${node_critical_count[$node]}"
            local w_count="${node_warning_count[$node]}"
            
            # Color code based on severity
            local node_color="${NC}"
            if [[ $c_count -gt 0 ]]; then
                node_color="${RED}"
            elif [[ $w_count -gt 0 ]]; then
                node_color="${YELLOW}"
            fi
            
            output_always "    ${node_color}$(printf '%-45s %8d %8d' "$node" "$c_count" "$w_count")${NC}"
        done <<< "$sorted_nodes"
        
        # Show recommendation for most affected node
        local most_affected_node
        most_affected_node=$(echo "$sorted_nodes" | head -1)
        if [[ -n "$most_affected_node" && ${node_critical_count[$most_affected_node]} -gt 0 ]]; then
            output_always ""
            output_always "    ${YELLOW}Recommendation: Node '${most_affected_node}' has the most critical issues.${NC}"
        fi
    fi

    # ─────────────────────────────────────────────────────────────
    # Unbound PVs
    # ─────────────────────────────────────────────────────────────
    if [[ $UNBOUND_PV_COUNT -gt 0 ]]; then
        output_always "\n  ${BOLD}${YELLOW}Unbound PVs ($UNBOUND_PV_COUNT):${NC}"
        while IFS=$'\t' read -r pv_name pv_phase; do
            [[ -z "$pv_name" ]] && continue
            output_always "    ${YELLOW}•${NC} $pv_name (${pv_phase})"
        done <<< "$UNBOUND_PVS"
    fi

    # ─────────────────────────────────────────────────────────────
    # Orphaned VolumeAttachments
    # ─────────────────────────────────────────────────────────────
    if [[ $ORPHANED_VA_COUNT -gt 0 ]]; then
        output_always "\n  ${BOLD}${RED}Orphaned VolumeAttachments ($ORPHANED_VA_COUNT):${NC}"
        while IFS='|' read -r va_name va_pv va_node; do
            [[ -z "$va_name" ]] && continue
            output_always "    ${RED}•${NC} $va_name → PV: $va_pv (missing) on $va_node"
        done < <(echo -e "$ORPHANED_VAS")
    fi

    # ─────────────────────────────────────────────────────────────
    # Issues by PV (compact format)
    # ─────────────────────────────────────────────────────────────
    # Group issues by PV
    declare -A pv_issues_critical
    declare -A pv_issues_warning
    declare -A pv_issues_info
    
    for issue in "${ISSUES_FOUND[@]}"; do
        local pv severity text node
        pv=$(echo "$issue" | cut -d'|' -f1)
        severity=$(echo "$issue" | cut -d'|' -f2)
        text=$(echo "$issue" | cut -d'|' -f3)
        node=$(echo "$issue" | cut -d'|' -f4)
        
        # Add node info to text if present
        [[ -n "$node" ]] && text="${text} [${node}]"
        
        case "$severity" in
            CRITICAL)
                if [[ -z "${pv_issues_critical[$pv]:-}" ]]; then
                    pv_issues_critical[$pv]="$text"
                else
                    pv_issues_critical[$pv]="${pv_issues_critical[$pv]}; $text"
                fi
                ;;
            WARNING)
                if [[ -z "${pv_issues_warning[$pv]:-}" ]]; then
                    pv_issues_warning[$pv]="$text"
                else
                    pv_issues_warning[$pv]="${pv_issues_warning[$pv]}; $text"
                fi
                ;;
            INFO)
                if [[ -z "${pv_issues_info[$pv]:-}" ]]; then
                    pv_issues_info[$pv]="$text"
                else
                    pv_issues_info[$pv]="${pv_issues_info[$pv]}; $text"
                fi
                ;;
        esac
    done
    
    # Get unique PVs with issues, sorted
    local all_pvs_with_issues
    all_pvs_with_issues=$(printf '%s\n' "${!pv_issues_critical[@]}" "${!pv_issues_warning[@]}" "${!pv_issues_info[@]}" | sort -u)
    
    if [[ -n "$all_pvs_with_issues" ]]; then
        output_always "\n  ${BOLD}Issues by PV:${NC}"
        
        while IFS= read -r pv; do
            [[ -z "$pv" ]] && continue
            
            # Determine overall severity for this PV
            local pv_color="${BLUE}"
            local pv_marker="ℹ️ "
            if [[ -n "${pv_issues_critical[$pv]:-}" ]]; then
                pv_color="${RED}"
                pv_marker="❌"
            elif [[ -n "${pv_issues_warning[$pv]:-}" ]]; then
                pv_color="${YELLOW}"
                pv_marker="⚠️ "
            fi
            
            output_always "\n    ${pv_color}${pv_marker} ${pv}${NC}"
            
            # Print critical issues first
            if [[ -n "${pv_issues_critical[$pv]:-}" ]]; then
                output_always "       ${RED}CRITICAL:${NC} ${pv_issues_critical[$pv]}"
            fi
            
            # Then warning issues
            if [[ -n "${pv_issues_warning[$pv]:-}" ]]; then
                output_always "       ${YELLOW}WARNING:${NC} ${pv_issues_warning[$pv]}"
            fi
            
            # Info issues (cosmetic)
            if [[ -n "${pv_issues_info[$pv]:-}" ]]; then
                output_always "       ${BLUE}INFO:${NC} ${pv_issues_info[$pv]}"
            fi
        done <<< "$all_pvs_with_issues"
    fi

    output_always ""
    output_always "  ${DIM}────────────────────────────────────────────────────────────────${NC}"
    output_always "  Log file: ${LOG_FILE}"
    output_always ""
    output_always "  ${YELLOW}Note: This script does not provide cleanup commands for safety.${NC}"
    output_always "  ${YELLOW}Review the output carefully before taking any manual action.${NC}"
}

# Main execution
main() {
    # Record start time
    START_TIME=$(date +%s)
    START_TIMESTAMP=$(date -Iseconds)
    
    # Set up logging
    setup_logging
    
    output_always "${BOLD}Kubernetes Volume Diagnostic Tool${NC} v${VERSION}"
    output_always "Started: $START_TIMESTAMP"

    validate_contexts
    run_analysis
    generate_summary
}

# Run main
main
