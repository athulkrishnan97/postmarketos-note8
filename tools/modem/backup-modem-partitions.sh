#!/bin/sh
# Back up the modem-related partitions before the CP is ever started from
# Linux. Run on the phone as root; writes images + SHA256SUMS to $1
# (default /home/user/modem-backup). Copy the result off the phone.
#
#   EFS        IMEI, nv_data.bin (RF calibration) - irreplaceable
#   RADIO      modem.bin (CP firmware)
#   CP_DEBUG   CP crash logs
#   PERSISTENT, PARAM, (SEC_EFS / CPEFS if present)
set -eu
out=${1:-/home/user/modem-backup}
mkdir -p "$out"
cd "$out"
for p in EFS SEC_EFS CPEFS RADIO CP_DEBUG PERSISTENT PARAM; do
	dev=/dev/disk/by-partlabel/$p
	[ -e "$dev" ] || { echo "skip $p (no such partition)"; continue; }
	echo "backing up $p ($(readlink -f "$dev"))"
	dd if="$dev" of="$p.img" bs=1M conv=fsync status=none
done
sha256sum ./*.img > SHA256SUMS
cat SHA256SUMS
echo "done: $out - now copy it to another machine (scp -r)"
