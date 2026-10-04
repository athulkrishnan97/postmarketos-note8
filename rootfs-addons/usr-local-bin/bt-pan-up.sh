#!/bin/sh
# bt-pan-up - bring up the Bluetooth PAN link from this phone to the
# laptop (laptop = NAP server at 192.168.99.1, phone joins as PANU).
#
# Safe to re-run: every step checks current state first.
# Everything is logged to $LOG as well as printed on screen.
# Usage: bt-pan-up.sh [laptop-bdaddr]

set -u

PC_BDADDR="${1:-90:E8:68:42:1D:2A}"
PAN_MAC="42:47:B0:00:1F:AC"   # valid unicast MAC (phone BD addr has the
                              # ethernet multicast bit set - kernel rejects
                              # it for bnep0, so we use this instead)
BR="br0"
BR_ADDR="192.168.99.2/24"
BR_GW="192.168.99.1"
HCI=""
BNEP_UP=/usr/local/bin/bnep-up

LOG=/home/athul/bt-pan-up.log
: > "$LOG" 2>/dev/null || LOG=/tmp/bt-pan-up.log

step() { echo "==> $*" | tee -a "$LOG"; }
info() { echo "    $*" | tee -a "$LOG"; }
fail() { echo "ERROR: $*" | tee -a "$LOG" >&2; exit 1; }
dump() { { echo ""; echo "--- $* ---"; "$@" 2>&1; } | tee -a "$LOG"; }

step "bt-pan-up starting $(date 2>/dev/null)"
info "target NAP: $PC_BDADDR  log: $LOG"
dump uname -a
dump ls /sys/class/bluetooth

# --- 1. find the hci device, power it up ----------------------------------
# NOTE: do NOT run hciattach if an hci device already exists - attaching a
# second time wedges the chip until reboot.
step "checking hci device"
HCI=""
if command -v hciconfig >/dev/null 2>&1; then
	HCI=$(hciconfig 2>/dev/null | sed -n 's/^\(hci[0-9]*\):.*/\1/p' | head -1)
fi
if [ -z "$HCI" ]; then
	for d in /sys/class/bluetooth/hci*; do
		[ -d "$d" ] && HCI="${d##*/}" && break
	done
fi
if [ -z "$HCI" ]; then
	info "no hci device at all; last-resort hciattach..."
	hciattach /dev/ttySAC0 bcm43xx 3000000 2>&1 | tee -a "$LOG" || true
	sleep 2
	HCI=$(hciconfig 2>/dev/null | sed -n 's/^\(hci[0-9]*\):.*/\1/p' | head -1)
fi
[ -n "$HCI" ] || fail "no hci device even after hciattach - reboot the phone"

step "powering up $HCI"
rfkill unblock bluetooth 2>/dev/null || true
hciconfig "$HCI" up 2>/dev/null || true
sleep 1
hciconfig "$HCI" 2>/dev/null | grep -q "UP RUNNING" \
	|| fail "$HCI exists but won't come up - a double hciattach may have wedged the chip; reboot the phone and re-run this script"
info "$HCI is up"
dump hciconfig "$HCI"

# --- 2. bluetooth service -------------------------------------------------
step "checking bluetooth service"
if ! rc-service bluetooth status >/dev/null 2>&1; then
	rc-service bluetooth start 2>&1 | tee -a "$LOG" || fail "could not start bluetooth service"
fi
info "bluetoothd running"

# --- 3. bnep kernel module ------------------------------------------------
step "checking bnep module"
# bnep may be built into the kernel - /sys/module/bnep exists in that case
# too, while lsmod would (wrongly) report it as missing.
if [ ! -d /sys/module/bnep ]; then
	modprobe bnep 2>&1 | tee -a "$LOG" || fail "modprobe bnep failed (module missing?)"
fi
[ -d /sys/module/bnep ] || fail "bnep module not available"
info "bnep available"

# --- 4. bridge ------------------------------------------------------------
step "setting up $BR"
if [ ! -d /sys/module/bridge ]; then
	# if modules.dep is missing/stale modprobe loads without deps and
	# bridge fails with "Unknown symbol" (it needs stp + llc)
	[ -f /lib/modules/$(uname -r)/modules.dep ] || depmod -a 2>&1 | tee -a "$LOG" || true
	modprobe bridge 2>&1 | tee -a "$LOG" || fail "modprobe bridge failed (module missing?)"
fi
[ -d /sys/module/bridge ] || fail "bridge module not available"
ip link show "$BR" >/dev/null 2>&1 || ip link add "$BR" type bridge || fail "cannot create $BR"
ip addr show dev "$BR" | grep -q "$BR_ADDR" || ip addr add "$BR_ADDR" dev "$BR" || fail "cannot add $BR_ADDR"
ip link set "$BR" up || fail "cannot bring up $BR"
info "$BR up with $BR_ADDR"

# --- 5. BNEP connection -----------------------------------------------------
step "connecting to NAP $PC_BDADDR"
pkill -f "$BNEP_UP" 2>/dev/null && sleep 1

: > /tmp/bnep-up.log
info "running: $BNEP_UP $PC_BDADDR $HCI"
setsid "$BNEP_UP" "$PC_BDADDR" "$HCI" >/tmp/bnep-up.log 2>&1 &
BPID=$!
info "bnep-up pid: $BPID"

BNIF=""
i=0
while [ $i -lt 20 ]; do
	for d in /sys/class/net/bnep*; do
		[ -e "$d" ] && BNIF="${d##*/}" && break
	done
	[ -n "$BNIF" ] && break
	kill -0 $BPID 2>/dev/null || break
	sleep 1
	i=$((i + 1))
done

if [ -z "$BNIF" ]; then
	info "bnep-up exited or timed out; its output was:"
	cat /tmp/bnep-up.log | tee -a "$LOG"
	dump hciconfig "$HCI"
	fail "no bnep interface appeared (see above)"
fi
info "got interface $BNIF"

# --- 6. configure the interface ---------------------------------------------
step "configuring $BNIF (valid MAC, MTU, up, enslaved to $BR)"
ip link set dev "$BNIF" down 2>/dev/null
ip link set dev "$BNIF" address "$PAN_MAC" || fail "cannot set MAC on $BNIF"
# The bnep link silently drops frames above ~620 bytes (real path MTU is
# far below Ethernet 1500); without this, everything that sends larger
# packets (ssh key exchange!) hangs. 600 leaves headroom for headers.
ip link set dev "$BNIF" mtu 600 2>/dev/null || info "WARN: could not set MTU 600 on $BNIF"
ip link set dev "$BNIF" up || fail "cannot bring up $BNIF"
ip link set dev "$BNIF" master "$BR" || fail "cannot enslave $BNIF to $BR"

# --- 7. verify ---------------------------------------------------------------
dump ip addr show "$BR"
dump ip link show "$BR"

step "checking link to laptop ($BR_GW)"
if ping -c 2 -W 2 "$BR_GW" 2>&1 | tee -a "$LOG" >/dev/null 2>&1; then
	info "PING OK - laptop reachable at $BR_GW"
else
	info "WARN: no ping reply yet (laptop may still be attaching its end)"
fi

echo | tee -a "$LOG"
echo "ssh from the laptop with:" | tee -a "$LOG"
echo "    ssh -o StrictHostKeyChecking=no athul@192.168.99.2" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "(bnep-up runs in background, PID $BPID; the link stays up until" | tee -a "$LOG"
echo " the phone reboots or you run: pkill -f bnep-up)" | tee -a "$LOG"
