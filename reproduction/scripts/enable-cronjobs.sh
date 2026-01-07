#!/bin/bash
# enable-cronjobs.sh - Enable all backup-simulator cronjobs in voltest namespaces
#
# This starts the stress test by unsuspending all CronJobs, which will begin
# creating pods that attach and detach volumes every 10 minutes.

set -euo pipefail

echo "Enabling backup-simulator CronJobs in all voltest namespaces..."

count=0
for ns in $(kubectl get ns -o name | grep "voltest-" | cut -d/ -f2 | sort); do
    if kubectl patch cronjob backup-simulator -n "$ns" -p '{"spec":{"suspend":false}}' 2>/dev/null; then
        ((count++))
    fi
done

echo ""
echo "Enabled $count CronJobs (schedule: */10 * * * *)"
echo ""
echo "The stress test is now running. CronJobs will trigger every 10 minutes."
echo "To disable: ./disable-cronjobs.sh"
