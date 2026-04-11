#!/usr/bin/env bash
# directories.sh
# Creates the top-level and device-type log directories for the rsyslog
# centralised logging server.  Run once on the rsyslog server as root
# before starting (or restarting) rsyslog.
#
# Usage:
#   sudo bash directories.sh
#
# Per-device sub-directories (e.g. /var/log/network/cisco-ios/SW-CORE/)
# are created automatically by rsyslog the first time a message is received
# from that device — no manual action needed.

set -euo pipefail

LOG_ROOT="/var/log"
LOG_USER="syslog"
LOG_GROUP="adm"
DIR_MODE="0750"

# ── Category → space-separated list of device-type sub-directories ───────────
declare -A SUBTYPES=(
    [network]="cisco-ios cisco-ios-xe cisco-ios-xr cisco-nxos arista-eos mikrotik unknown"
    [firewall]="cisco-asa cisco-ftd fortigate"
    [compute]="dell hp"
    [vms]="linux windows"
)

echo "Creating rsyslog log directory structure under ${LOG_ROOT} ..."
echo ""

for category in network firewall compute vms; do
    for subtype in ${SUBTYPES[$category]}; do
        target="${LOG_ROOT}/${category}/${subtype}"
        install -d -m "${DIR_MODE}" -o "${LOG_USER}" -g "${LOG_GROUP}" "${target}"
        echo "  [OK]  ${target}"
    done
done

echo ""
echo "Permissions summary:"
find "${LOG_ROOT}/network" \
     "${LOG_ROOT}/firewall" \
     "${LOG_ROOT}/compute" \
     "${LOG_ROOT}/vms" \
     -maxdepth 2 -type d | sort | \
while IFS= read -r d; do
    printf "  %-55s  %s\n" "$d" "$(stat -c '%U:%G %a' "$d")"
done

echo ""
echo "Done."
echo "NOTE: Device sub-directories are created on first log receipt."
