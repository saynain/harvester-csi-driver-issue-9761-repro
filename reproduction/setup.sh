#!/bin/bash
#
# setup.sh - Deploy volume stress test environment for Harvester CSI race condition
#
# This script sets up a test environment to reproduce a race condition in the
# Harvester CSI driver that causes volume attachment deadlocks under high
# attach/detach workload.
#
# Usage:
#   ./setup.sh [OPTIONS]
#
# Options:
#   --count N           Number of test namespaces (default: 40)
#   --storage-class SC  Storage class name (default: default)
#   --cleanup           Remove all test resources
#   --dry-run           Show what would be created without applying
#   --help              Show this help message
#
# Examples:
#   ./setup.sh                              # Deploy 40 namespaces with defaults
#   ./setup.sh --count 20                   # Deploy 20 namespaces
#   ./setup.sh --storage-class harvester    # Use 'harvester' storage class
#   ./setup.sh --cleanup                    # Remove everything

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="$SCRIPT_DIR/generated"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# Default values
NAMESPACE_COUNT=40
STORAGE_CLASS="default"
DRY_RUN=false
CLEANUP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Symbols
CHECK="${GREEN}OK${NC}"
WARN="${YELLOW}!!${NC}"
ERROR="${RED}ERR${NC}"
INFO="${BLUE}--${NC}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy a volume stress test environment to reproduce Harvester CSI driver
race conditions.

Options:
    --count N           Number of test namespaces to create (default: 40)
    --storage-class SC  Storage class to use for volumes (default: default)
    --cleanup           Remove all test resources and exit
    --dry-run           Generate files but don't apply to cluster
    --help              Show this help message

Examples:
    $(basename "$0")                              # Deploy 40 namespaces
    $(basename "$0") --count 20                   # Deploy 20 namespaces
    $(basename "$0") --storage-class harvester    # Use 'harvester' storage class
    $(basename "$0") --cleanup                    # Remove all test resources

Scaling:
    To change namespace count, first run --cleanup, then re-run with new --count.

EOF
    exit 0
}

log_info() {
    echo -e "[$INFO] $1"
}

log_ok() {
    echo -e "[$CHECK] $1"
}

log_warn() {
    echo -e "[$WARN] $1"
}

log_error() {
    echo -e "[$ERROR] $1"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --count)
                NAMESPACE_COUNT="$2"
                if ! [[ "$NAMESPACE_COUNT" =~ ^[0-9]+$ ]] || [[ "$NAMESPACE_COUNT" -lt 1 ]]; then
                    log_error "Invalid count: $NAMESPACE_COUNT (must be a positive integer)"
                    exit 1
                fi
                shift 2
                ;;
            --storage-class)
                STORAGE_CLASS="$2"
                shift 2
                ;;
            --cleanup)
                CLEANUP=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    log_ok "kubectl found"
    
    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    log_ok "Cluster connection verified"
    
    # Check if storage class exists
    if ! kubectl get storageclass "$STORAGE_CLASS" &> /dev/null; then
        log_warn "Storage class '$STORAGE_CLASS' not found. Deployment may fail."
    else
        log_ok "Storage class '$STORAGE_CLASS' exists"
    fi
}

# Cleanup function
do_cleanup() {
    log_info "Cleaning up test resources..."
    
    # Delete namespaces by label
    local namespaces
    namespaces=$(kubectl get ns -l app.kubernetes.io/name=volume-stress-test -o name 2>/dev/null || true)
    
    if [[ -n "$namespaces" ]]; then
        log_info "Deleting test namespaces..."
        kubectl delete ns -l app.kubernetes.io/name=volume-stress-test --wait=false
        log_ok "Namespace deletion initiated (may take a few minutes to complete)"
    else
        log_info "No test namespaces found"
    fi
    
    # Remove generated directory
    if [[ -d "$GENERATED_DIR" ]]; then
        rm -rf "$GENERATED_DIR"
        log_ok "Removed generated/ directory"
    fi
    
    echo ""
    log_info "Cleanup complete. Note: CNPG operator was NOT removed."
    log_info "To remove CNPG operator: kubectl delete -f cnpg-1.27.1.yaml"
    exit 0
}

# Install CNPG operator if not present
install_cnpg() {
    log_info "Checking CNPG operator..."
    
    if kubectl get deployment cnpg-controller-manager -n cnpg-system &> /dev/null; then
        log_warn "CNPG operator already installed, skipping installation"
        return 0
    fi
    
    log_info "Installing CNPG operator..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would apply: cnpg-1.27.1.yaml"
    else
        kubectl apply --server-side -f "$SCRIPT_DIR/cnpg-1.27.1.yaml"
        log_info "Waiting for CNPG operator to be ready..."
        kubectl wait --for=condition=available deployment/cnpg-controller-manager \
            -n cnpg-system --timeout=120s
        log_ok "CNPG operator installed and ready"
    fi
}

# Generate namespace manifests
generate_manifests() {
    log_info "Generating manifests for $NAMESPACE_COUNT namespaces..."
    
    # Clean existing generated directory
    if [[ -d "$GENERATED_DIR" ]]; then
        rm -rf "$GENERATED_DIR"
    fi
    mkdir -p "$GENERATED_DIR/namespaces"
    
    # Read templates
    local postgres_template secrets_template backup_cronjob_template
    postgres_template=$(cat "$TEMPLATES_DIR/postgres-cluster.yaml")
    secrets_template=$(cat "$TEMPLATES_DIR/secrets.yaml")
    backup_cronjob_template=$(cat "$TEMPLATES_DIR/backup-cronjob.yaml")
    
    # Substitute storage class in templates
    postgres_template="${postgres_template//storageClass: default/storageClass: $STORAGE_CLASS}"
    backup_cronjob_template="${backup_cronjob_template//storageClassName: default/storageClassName: $STORAGE_CLASS}"
    
    # Generate root kustomization.yaml
    {
        echo "apiVersion: kustomize.config.k8s.io/v1beta1"
        echo "kind: Kustomization"
        echo ""
        echo "resources:"
    } > "$GENERATED_DIR/kustomization.yaml"
    
    # Generate each namespace
    for i in $(seq -w 1 "$NAMESPACE_COUNT"); do
        local ns_name="voltest-$i"
        local ns_dir="$GENERATED_DIR/namespaces/$ns_name"
        mkdir -p "$ns_dir"
        
        # Namespace manifest
        cat > "$ns_dir/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns_name
  labels:
    app.kubernetes.io/name: volume-stress-test
    app.kubernetes.io/component: test-namespace
EOF
        
        # Secrets manifest
        echo "$secrets_template" > "$ns_dir/secrets.yaml"
        
        # Postgres cluster manifest
        echo "$postgres_template" > "$ns_dir/postgres-cluster.yaml"
        
        # Backup cronjob manifest
        echo "$backup_cronjob_template" > "$ns_dir/backup-cronjob.yaml"
        
        # Namespace kustomization
        cat > "$ns_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $ns_name

resources:
  - namespace.yaml
  - secrets.yaml
  - postgres-cluster.yaml
  - backup-cronjob.yaml
EOF
        
        # Add to root kustomization
        echo "  - namespaces/$ns_name" >> "$GENERATED_DIR/kustomization.yaml"
    done
    
    log_ok "Generated manifests in $GENERATED_DIR"
}

# Deploy manifests
deploy_manifests() {
    log_info "Deploying manifests..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would run: kubectl apply -k $GENERATED_DIR"
        kubectl kustomize "$GENERATED_DIR" | head -50
        echo "... (truncated)"
    else
        kubectl apply -k "$GENERATED_DIR"
        log_ok "Manifests applied"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BOLD}=======================================${NC}"
    echo -e "${BOLD}        Deployment Summary${NC}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}DRY-RUN MODE - No changes were made${NC}"
        echo ""
    fi
    
    echo "  Namespaces:     $NAMESPACE_COUNT"
    echo "  Storage class:  $STORAGE_CLASS"
    echo "  CronJobs:       Deployed (SUSPENDED)"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "  1. Wait for PostgreSQL clusters to be ready:"
    echo "     kubectl get clusters.postgresql.cnpg.io -A -w"
    echo ""
    echo "  2. Once all clusters show 'Cluster in healthy state', enable CronJobs:"
    echo "     ./scripts/enable-cronjobs.sh"
    echo ""
    echo "  3. Monitor for volume attachment issues:"
    echo "     kubectl get pods -A | grep -E '(Pending|ContainerCreating)'"
    echo "     kubectl get volumeattachments"
    echo ""
    echo "  4. Run the diagnostic script to detect issues:"
    echo "     ../diagnostic/k8s-volume-diagnostic.sh \\"
    echo "       --downstream-context <context> \\"
    echo "       --harvester-context <context> \\"
    echo "       --harvester-namespace <namespace>"
    echo ""
    echo -e "${BOLD}Cleanup:${NC}"
    echo "     ./setup.sh --cleanup"
    echo ""
}

# Main
main() {
    parse_args "$@"
    
    echo ""
    echo -e "${BOLD}Harvester CSI Volume Stress Test Setup${NC}"
    echo "========================================"
    echo ""
    
    if [[ "$CLEANUP" == "true" ]]; then
        check_prerequisites
        do_cleanup
    fi
    
    log_info "Configuration:"
    log_info "  Namespace count: $NAMESPACE_COUNT"
    log_info "  Storage class:   $STORAGE_CLASS"
    log_info "  Dry run:         $DRY_RUN"
    echo ""
    
    check_prerequisites
    echo ""
    
    install_cnpg
    echo ""
    
    generate_manifests
    echo ""
    
    deploy_manifests
    echo ""
    
    print_summary
}

main "$@"
