#!/bin/bash
# Kontinuerlig capture av CSI driver logs
# Kjør dette FØR du starter stress test
#
# Usage:
#   ./csi-log-capture.sh              - Start capture (forgrunn)
#   ./csi-log-capture.sh &            - Start capture (bakgrunn)
#   LOG_DIR=/path/to/logs ./csi-log-capture.sh

set -euo pipefail

LOG_DIR="${LOG_DIR:-$HOME/csi-logs}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$LOG_DIR"

echo "=== CSI Log Capture ==="
echo "Timestamp: $TIMESTAMP"
echo "Log directory: $LOG_DIR"
echo ""

# Fokuser på controller pods - disse har ControllerPublish/Unpublish logs
echo "Looking for CSI controller pods (the important ones)..."
CONTROLLER_PODS=$(kubectl get pods -n kube-system -o name 2>/dev/null | grep harvester-csi-driver-controllers || true)

if [ -z "$CONTROLLER_PODS" ]; then
    echo "ERROR: No harvester-csi-driver-controllers pods found!"
    exit 1
fi

echo "Found controller pods:"
echo "$CONTROLLER_PODS"
echo ""

# Start log capture for hver controller pod
for pod_ref in $CONTROLLER_PODS; do
    pod=$(echo "$pod_ref" | sed 's|pod/||')
    log_file="$LOG_DIR/${pod}_${TIMESTAMP}.log"
    
    echo "Starting capture: $pod -> $log_file"
    
    # Follow logs med timestamps, filtrer bort støy
    # Beholder: ControllerPublish, ControllerUnpublish, error, volume operations
    kubectl logs -f "$pod" -n kube-system --all-containers=true 2>&1 | \
        grep -v "leaderelection.go" | \
        grep -v "successfully renewed lease" | \
        grep -v "reflector.go.*Watch close" | \
        while IFS= read -r line; do
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
        done >> "$log_file" &
done

# Capture events også
event_log="$LOG_DIR/events_${TIMESTAMP}.log"
echo "Starting event capture -> $event_log"
(
    while true; do
        echo "=== $(date -Iseconds) ===" >> "$event_log"
        kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null | \
            grep -E "FailedAttachVolume|FailedMount|voltest" >> "$event_log" 2>&1 || true
        sleep 10
    done
) &

echo ""
echo "=== Capture running ==="
echo "Logs: $LOG_DIR/*_${TIMESTAMP}.log"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Hold scriptet kjørende og fang Ctrl+C
trap 'echo ""; echo "Stopping..."; kill $(jobs -p) 2>/dev/null; echo "Logs saved in $LOG_DIR"; exit 0' INT TERM

# Vent på alle bakgrunnsjobber
wait
