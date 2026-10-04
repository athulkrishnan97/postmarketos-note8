# postmarketOS on the Samsung Galaxy Note 8 (greatlte / SM-N950F)

Mainline Linux (7.0.0-rc1) running on the Exynos 8895 Samsung Galaxy Note 8,
with a fully open-source boot chain, CPU frequency scaling with real voltage
control, a working Mali-G71 GPU (panfrost), WiFi, Bluetooth PAN networking,
and KDE Plasma Mobile with a working touchscreen.

This repository contains everything needed to build and install it:
device kernel packages (with all our mainline driver work as patch files),
the uniLoader board files, and the phone-side runtime addons.

> Status: **daily-driver-ish for tinkering**. See "What works / What doesn't"
> below — the display compositor and the top CPU frequencies are the known
> limitations.

---

## What works

| Feature | Details |
|---|---|
| Boot | Samsung bootloader → uniLoader → mainline kernel → postmarketOS rootfs from microSD |
| CPU frequency scaling | Both clusters, 455 MHz – 1.7 GHz (big) / 455 MHz – 1.69 GHz (little), with **voltage scaling** via the S2MPS17 PMIC over a ported SPEEDY bus driver. Validated under a 100 s all-core stress test. |
| GPU | Mali-G71 via mainline **panfrost** (initialized, OpenGL render node works, compositors render on it) |
| Touchscreen | Samsung s6sy761 (Y661), multi-touch, works in console **and** Plasma Mobile |
| WiFi | Broadcom **BCM4361**B0 (PCIe, brcmfmac) — auto-connects at boot. Use 2.4 GHz WPA2. |
| Bluetooth | BCM4347B0 UART, works (incl. a BT-PAN IP link to a laptop) |
| GUI | KDE Plasma Mobile (tinydm) on a touchscreen |
| SSH | key-based, over WiFi or the Bluetooth PAN link |
| Storage | microSD rootfs (28 GB), 2 GB swapfile |

## What doesn't (yet)

| Feature | Why | Path forward |
|---|---|---|
| Display compositor speed | The only display driver is the **bootloader framebuffer via simpledrm**: every composited frame is CPU-copied into the 1440×2960 shadow FB. Rendering is on the Mali, *displaying* is not. | The big one: an exynos DECON + DSI panel KMS driver (zero-copy GPU scanout). |
| Big CPU above 1.7 GHz | Hangs under load at any voltage (tested to the 1.2 V rail max). Suspected **EMA** (SRAM timing) setup, which Samsung's firmware does per-voltage. | Find the cluster sysreg block (S5E8890 hint: `0x11850000+0x314`), set EMA per voltage, re-test the 2.3 GHz stock OPPs. |
| GPU at full speed | GPU runs at 800 MHz from the CMU_TOP switch; the G3D PLL register at `0x120` is write-protected (bootloader's locked PLL config lives at `0x140`). | Understand the `0x148/0x140` banked PLL programming. |
| GPU display outputs | panfrost has no KMS display (no DSI/decon), so kwin renders on the Mali but scans out via simpledrm. | Same DECON/DSI driver as above. |
| 5 GHz / WPA3 WiFi | The 2.4 GHz WPA2 SSID connects; the 5 GHz WPA3 one scans but won't associate. | Investigate firmware/CLM/regulatory. |
| Sustained full-speed WiFi RX | >5–10 min of heavy download instantly reboots the phone (no panic log). Suspect brcmfmac. | Trickled transfers work around it; needs a proper bug hunt. |
| USB to a PC | The dwc3 gadget runs on `dummy_udc` (virtual loopback) — no real USB data path until the dwc3/PHY work lands. | Port the dwc3 + USB-C role-switch setup. |
| S Pen (wacom w90xx) / hw keys | No mainline driver. | Port the downstream wacom_i2c-style driver. |
| Full 6 GB RAM | Kernel sees 3.8 GB (memory map). | Fix the dts memory nodes. |
| Internal UFS storage | No UFS driver enabled. | — |

## Repository layout

```
aports/                 postmarketOS device packages (build these with pmbootstrap)
  linux-postmarketos-exynos8895/   the kernel: all driver work as patch files
                                   (PCIe/brcmfmac, cpufreq+PMIC, GPU, touch)
  device-samsung-greatlte/         device package (initramfs hooks, device info)
  uniloader-samsung-greatlte/      bootloader package
uniloader-files/        our uniLoader board port (2 files; applied onto upstream uniLoader)
rootfs-addons/          files to install into the phone rootfs
  etc-init.d/g3d                    brings panfrost up before the display manager
  etc-local.d/cpuspeed.start        ramps CPUs to full speed after boot
  usr-local-bin/bt-pan-up.sh        one-command BT-PAN network to a laptop
  firmware/                         BCM4361 wifi firmware + board NVRAM + BT .hcd
docs/BRINGUP.md         the full technical journey: every root cause we hit
```

## Build instructions

Tested on an Ubuntu 24.04 host. You need: `pmbootstrap`, `heimdall-flash`,
`mkbootimg`, an `aarch64-linux-gnu-` toolchain, `clang`/`lld`, `dtc`, plus a
microSD card (≥8 GB) and a Galaxy Note 8 in download mode.

### 1. Kernel + device packages

```sh
git clone https://github.com/athulkrishnan97/postmarketos-note8.git
git clone --branch v3.3.0 https://gitlab.postmarketos.org/pmaports/pmaports.git pmbootstrap

cd pmbootstrap
# point pmbootstrap at this repo's aports
pmbootstrap config aports_custom "/path/to/postmarketos-note8/aports"
pmbootstrap init   # device: samsung-greatlte (pick from the custom aports)

# build the kernel package (applies all patches, builds Image + dtbs + modules)
pmbootstrap build linux-postmarketos-exynos8895
pmbootstrap build device-samsung-greatlte
```

### 2. Boot image (uniLoader shim)

uniLoader carries the kernel Image + dtb concatenated after itself.

```sh
git clone https://github.com/ivoszbg/uniLoader.git
cd uniLoader
cp /path/to/postmarketos-note8/uniloader-files/board-greatlte.c board/samsung/
cp /path/to/postmarketos-note8/uniloader-files/greatlte_defconfig configs/

# kernel artifacts from the pmbootstrap build (or a scratch tree build):
cp <builddir>/usr/share/kernel/postmarketos-exynos8895/Image blob/Image 2>/dev/null || \
cp <path-to>/arch/arm64/boot/Image blob/Image
cp <path-to>/arch/arm64/boot/dts/exynos/exynos8895-greatlte.dtb blob/dtb

make -s ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- clean
make -s ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- greatlte_defconfig
make -s ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-
# ^ the 'uniLoader' binary now embeds kernel + dtb; copy it out:
cp uniLoader /tmp/bootshim

# empty ramdisk + mkbootimg (Android header v1 layout for the N950F BOOT partition)
: > /tmp/empty_ramdisk
mkbootimg --header_version 1 --kernel /tmp/bootshim --ramdisk /tmp/empty_ramdisk \
  --pagesize 2048 --base 0 --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 \
  --second_offset 0x10f00000 --tags_offset 0x10000100 -o boot.img
```

> Gotcha learned the hard way: the `uniLoader` binary embeds `blob/Image` and
> `blob/dtb` at build time. After copying new blobs in, always
> `make clean && make` and verify the dtb inside the binary (search for the
> `d0 0d fe ed` magic) matches your source dtb — a stale dtb costs a flash
> cycle to notice.

### 3. Rootfs

```sh
pmbootstrap install --sdcard /dev/sdX   # your microSD; wipes it
# after first boot, grow partition 2 to fill the card (parted + resize2fs),
# then copy rootfs-addons/ into the rootfs:
#   etc-init.d/g3d        -> /etc/init.d/g3d && rc-update add g3d default
#   etc-local.d/cpuspeed.start -> /etc/local.d/  (chmod +x)
#   firmware/*            -> /lib/firmware/brcm/  (brcmfmac4361-pcie.* names;
#                            see docs/BRINGUP.md for the exact names)
```

### 4. Flash

Phone in download mode (VolDown + Bixby + USB), then:

```sh
heimdall flash --BOOT boot.img    # omit --no-reboot and it reboots itself
```

The phone boots → console with buffyboard on-screen keyboard → a few seconds
later the `cpuspeed` script raises CPU clocks, the `g3d` service brings up
panfrost, and (if tinydm is enabled) Plasma Mobile starts.

## Daily-use notes

- **WiFi**: NetworkManager auto-connects the first time you `nmcli dev wifi connect "SSID" password "psk"`.
- **Console input**: buffyboard on-screen keyboard works on the console. For a
  shell, autologin lands you as the user without a password.
- **BT PAN fallback** (works even when WiFi is broken): see
  `rootfs-addons/usr-local-bin/bt-pan-up.sh` — run it on the phone, it builds
  a bnep network to a laptop NAP bridge. Details + laptop setup in
  docs/BRINGUP.md.
- **Do not** leave big WiFi downloads running unattended (see known issues).

## Credits & provenance

- Kernel: mainline 7.0.0-rc1 + the patches in `aports/linux-postmarketos-exynos8895/`
  (all developed in this project; see docs/BRINGUP.md for the story of each).
- The G3D clock model and register maps came from Samsung's own CAL data
  (universal8895 downstream kernel) and the ECT tables left in RAM by the
  bootloader.
- The SPEEDY bus protocol was reconstructed from the exynos-speedy mainline
  patch (M. Broks / M. Holovach, linux-arm-kernel, Dec 2024) after discovering
  the downstream driver's xfer path was dead code.
- WiFi firmware: Samsung-shipped BCM4361B0 firmware + board NVRAM.
- uniLoader: https://github.com/ivoszbg/uniLoader

## License

GPL-2.0 (kernel patches, uniLoader board files, scripts).
The Broadcom firmware binaries in rootfs-addons/firmware are Samsung/Broadcom
redistributables included for convenience.
