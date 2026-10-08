#!/bin/sh
# Install rootfs-addons/ into a pmbootstrap-built greatlte disk image
# (partition 2 = pmOS_root) and enable the services, so the image boots to
# Plasma Mobile with GPU, WiFi and Bluetooth without any manual steps.
#
# usage: sudo tools/install-rootfs-addons.sh samsung-greatlte.img
set -eu

IMG=$1
ADDONS=$(cd "$(dirname "$0")/../rootfs-addons" && pwd)

LOOP=$(losetup -fP --show "$IMG")
MNT=$(mktemp -d)
trap 'umount "$MNT" 2>/dev/null; losetup -d "$LOOP"; rmdir "$MNT"' EXIT
mount "${LOOP}p2" "$MNT"

# GPU bring-up (real G3D PLL, 546 MHz) and CPU clocks after boot
install -m 755 "$ADDONS/etc-init.d/g3d" "$MNT/etc/init.d/g3d"
install -m 755 "$ADDONS/etc-local.d/cpuspeed.start" "$MNT/etc/local.d/cpuspeed.start"

# Bluetooth: UART attach, started/stopped from rfkill
install -m 755 "$ADDONS/etc-init.d/hciattach" "$MNT/etc/init.d/hciattach"
install -D -m 644 "$ADDONS/etc-udev-rules.d/10-hciattach.rules" \
	"$MNT/etc/udev/rules.d/10-hciattach.rules"

# No RTC: resync the clock once WiFi is up
install -D -m 755 "$ADDONS/etc-NetworkManager-dispatcher.d/50-chrony-resync" \
	"$MNT/etc/NetworkManager/dispatcher.d/50-chrony-resync"

install -D -m 755 "$ADDONS/usr-local-bin/bt-pan-up.sh" "$MNT/usr/local/bin/bt-pan-up.sh"

# BCM4361 WiFi (brcmfmac looks for both the generic and the board name)
FW="$MNT/lib/firmware/brcm"
mkdir -p "$FW"
for n in brcmfmac4361-pcie brcmfmac4361-pcie.samsung,greatlte; do
	install -m 644 "$ADDONS/firmware/bcmdhd_sta.bin_b0" "$FW/$n.bin"
	install -m 644 "$ADDONS/firmware/bcmdhd_clm.blob" "$FW/$n.clm_blob"
	install -m 644 "$ADDONS/firmware/nvram.txt_murata_r033_b0" "$FW/$n.txt"
done
# BCM4361 Bluetooth patchram
install -m 644 "$ADDONS/firmware/bcm4361B0_murata.hcd" "$ADDONS/firmware/bcm4361B0_semco.hcd" "$FW/"
# hciattach (bcm43xx) looks for the chip's ROM name in /etc/firmware; the
# greatlte module is the semco one
install -D -m 644 "$ADDONS/firmware/bcm4361B0_semco.hcd" "$MNT/etc/firmware/BCM4347B0.hcd"

for s in g3d hciattach local; do
	ln -sf "/etc/init.d/$s" "$MNT/etc/runlevels/default/$s"
done

# MTP (usb-mode mtp): files created as the phone user, not root
install -D -m 644 "$ADDONS/etc-umtprd/umtprd.conf" "$MNT/etc/umtprd/umtprd.conf"
install -D -m 755 "$ADDONS/usr-local-bin/usb-mode" "$MNT/usr/local/bin/usb-mode"

# Qt glyph cache workaround (under test: letters missing in Plasma labels)
install -D -m 644 "$ADDONS/etc-xdg-plasma-workspace-env/glyphcache-workaround.sh" \
	"$MNT/etc/xdg/plasma-workspace/env/glyphcache-workaround.sh"

echo "addons installed into $IMG"
