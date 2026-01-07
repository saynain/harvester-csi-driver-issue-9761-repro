#!/bin/bash
# disable-cronjobs.sh - Disable all backup-simulator cronjobs in voltest namespaces
#
# This stops the stress test by suspending all CronJobs. Running jobs will
# continue to completion, but no new jobs will be scheduled.

set -euo pipefail

echo "Disabling backup-simulator CronJobs in all voltest namespaces..."

count=0
for ns in $(kubectl get ns -o name | grep "voltest-" | cut -d/ -f2 | sort); do
    if kubectl patch cronjob backup-simulator -n "$ns" -p '{"spec":{"suspend":true}}' 2>/dev/null; then
        count=$((count + 1))
    fi
done

echo ""
echo "Suspended $count CronJobs"
echo ""
echo "No new backup jobs will be scheduled."
echo "To re-enable: ./enable-cronjobs.sh"
