# RIL / modem bring-up plan (Shannon 355 CP on the Exynos 8895)

Written 2026-10-09 from the current repo state (kernel 7.0-r11, see HANDOVER.md)
and the downstream lineage-19.1 kernel
(`exynos8895/android_kernel_samsung_universal8895`: `drivers/misc/modem_v1`,
`drivers/soc/samsung/pmu-cp.c`, `drivers/mcu_ipc`,
`arch/arm64/boot/dts/exynos/modem-ss355ap-pdata.dtsi`,
`exynos8895-greatlte_common.dtsi`, `exynos8895-greatlte-rmem.dtsi`).

Goal, in order of value: SIM + network registration → SMS → mobile data →
voice calls with audio. Each phase below ends in a test that can be checked
over SSH, like the earlier bring-ups.

---

## 1. What the hardware is (from the stock DT and driver)

| Item | Stock value | State in our tree |
|---|---|---|
| Modem | Samsung Shannon 355, **on the SoC** (CP subsystem), `mif,name = "ss355ap"`, `modem_type = SEC_SS310AP` | not described |
| AP↔CP link | **shared memory** (`LINKDEV_SHMEM`), SIPC 5.0, SBD rings (`link_attrs 0x7C9`) | — |
| CP memory | `modem_if` 0xF4C00000, 144 MB; main binary at +0x10000; IPC buffers at +0x500000 (9 MB) | reserved **no-map** (greatlte-reserved-memory.patch) |
| CP log | `cp_ram_logging` 0xFDC00000, 32 MB | reserved no-map |
| 2nd buffer pool | `bufpool_2nd_base = 0xE9000000`, 64 MB | **not reserved**, and it overlaps the stock `video_stream` and `abox_rmem` (0xEA800000) carveouts: work out whether SS355 uses it before touching it |
| Mailbox | `mcu_ipc@15B40000` (0x180), SPI 97, `samsung,exynos-shd-ipc-mailbox` | not described |
| CP IRQs | SPI 21 `INTREQ_ALIVE_CP_ACTIVE`, SPI 57 `INTREQ_CP2AP_RESET_REQ` | — |
| Mailbox map | AP→CP msg 0 / wakeup 1 / status 2 / active 3; CP→AP msg 0 / status 2 / active 4 / DVFS 5-7 / wakelock 8 / RAT mode 9 | — |
| Power control | PMU `CP_CTRL_NS` 0x30, `CP_CTRL_S` 0x34, `CP_STAT` 0x38 (PMU 0x16480000). `CONFIG_CP_SECURE_BOOT=y`: **all CP_CTRL access goes through SMC 0x82000700** (`READ_CTRL`/`WRITE_CTRL`) | — |
| Secure boot | `IOCTL_SECURITY_REQ` → `exynos_smc(SMC_ID, mode, size_boot, size_main)` wrapped by `SMC_ID_CLK` SSS clock on/off; EL3 checks the CP image signature and locks the memory | — |
| Board GPIOs | CP_REV0-3 gpf1-1/2/3/7, AP_REV0-3 gpd0-0..3 | — |

Character/net devices the stock driver creates (the userspace ABI):

| Node | Format | Used by |
|---|---|---|
| `umts_boot0` | IPC_BOOT | cbd (CP boot daemon) |
| `umts_ramdump0` | IPC_DUMP | cbd (crash dumps) |
| `umts_ipc0`, `umts_ipc1` | IPC_FMT (Samsung IPC) | RIL |
| `umts_rfs0` | IPC_RFS | RFS daemon (CP reads/writes files in `/efs`) |
| `umts_router` | RAW | "Data Router" (AT command routing) |
| `umts_csd`, `umts_dm0`, `smd4`, `umts_ciq0` | RAW | CSD calls, DIAG, misc |
| `rmnet0`..`rmnet7` | RAW, net, no link header | mobile data (raw IP) |
| `multipdp`, `multipdp_hiprio` | MULTI_RAW (dummy) | demux |

Firmware: `modem.bin` in the **RADIO** partition (a TOC with BOOT / MAIN /
VSS / NV entries). Calibration and IMEI live in `nv_data.bin` on the **EFS**
partition. Neither is redistributable: read both from the phone at run time.

## 2. Risks to settle first

1. **SMC behaviour under our boot chain.** Two SMCs already hang here (UFS
   FMP, ABOX `SMC_CMD_REG`). If `SMC 0x82000700 READ_CTRL` hangs or
   `WRITE_CTRL CP_CTRL_S` is refused, the CP cannot be started and the rest of
   this plan does not apply. This is the first experiment (Phase 1.1).
2. **Secure memory lockups.** After the security request, EL3 likely protects
   the boot/main part of `modem_if` from the AP. A stray AP access is the same
   silent bus lock-up as the browser freeze (BRINGUP §17). Map only the IPC
   region after boot, never the whole 144 MB.
3. **No RIL protocol stack on Linux.** Samsung's RIL (`libsec-ril.so`) is an
   Android blob speaking proprietary Samsung IPC on `umts_ipc0`. The userspace
   route depends on what the recon in Phase 0 finds (§4).
4. **EFS.** A bad RFS write can corrupt `nv_data.bin` (IMEI, RF calibration).
   Back it up before the CP is ever started from Linux.
5. **Android recon now costs the pmOS install.** USERDATA holds the pmOS root
   (v122+). Booting Android to trace cbd/rild needs USERDATA back. Static
   analysis (SYSTEM is untouched) comes first; a live Android session would
   need pmOS moved back to microSD temporarily (user decision).

## 3. Phases

### Phase 0: backups and recon (no kernel work)

0.1 **Back up** (from pmOS, `dd` over SSH to the laptop, read-only):
EFS, RADIO, CP_DEBUG, PERSISTENT/PARAM and any `*EFS*` partition
(`ls -l /dev/disk/by-partlabel`). Keep SHA256s. Never write EFS until Phase 3.

0.2 **Static analysis from SYSTEM** (mount the SYSTEM partition read-only):
- `/system/bin/cbd` (or `/vendor/bin/cbd`) and its init `.rc` line: arguments,
  the RADIO path, the ioctl sequence (`IOCTL_MODEM_RESET`, `BOOT_ON`,
  `XMIT_BOOT`, `SECURITY_REQ`, `ON`, `BOOT_DONE`), TOC parsing, how NV is
  loaded, and the boot handshake magic.
- `libsec-ril.so`, `librilutils`, and the RFS daemon: the RFS file list and
  message format.
- Parse the RADIO TOC on the laptop (small Python tool for `tools/`):
  entry names, offsets, sizes, CRCs.

0.3 **Live recon on Android** (optional, only if static analysis falls short;
needs the decision in risk 5): `strace -f` cbd at boot, `dmesg | grep mif`,
and the deciding test, **does the CP answer AT on `umts_router`?**
(`cat /dev/umts_router & printf 'AT\r' > /dev/umts_router`, then
`AT+CPIN?`, `AT+COPS?`, `AT+CMGF=1`). Also dump the IPC traffic of a SIM
unlock, an SMS and a data call from rild for later.

Exit: backups on the laptop; a written cbd boot sequence; the answer to the
AT question.

### Phase 1: kernel plumbing (CP not running yet)

1.1 **SMC probe module** (out of tree, like paneldbg): read `CP_CTRL_NS`,
`CP_CTRL_S` through SMC 0x82000700 `READ_CTRL`, compare with a plain PMU read
of 0x16480030/34/38 (`/tmp/devmem`, read only). Then one harmless
`WRITE_CTRL` (write back the value just read). **Go / no-go for the project.**

1.2 **DT**: `mcu_ipc@15b40000` mailbox, a modem node (memory-region =
`modem_if` + `cp_ram_logging`, SPI 21/57, mailbox phandle, PMU syscon),
pinctrl for the REV GPIOs. Settle `bufpool_2nd` (grep the SS355 path; reserve
it only if used, and resolve the overlap with `abox_rmem`).

1.3 **Drivers**, written for 7.0, not a 4.4 copy:
- `exynos-shd-mbox`: a mainline `mailbox` controller (~300 lines, from
  `drivers/mcu_ipc`): 16 shared registers + IRQ set/clear/mask.
- CP power control (from `pmu-cp.c`): init / reset / release / start /
  active-clear / status, through the SMC helpers from 1.1.

Exit: CP held in reset and released on command; `CP_STAT` and the central
sequencer status change as in a stock boot; no IRQ storms (mask and clear
first, the lesson from DSIM/DECON).

### Phase 2: boot the CP

2.1 Kernel: the boot path of `link_device_shmem.c` + `modem_ctrl_ss310ap.c`
only: `umts_boot0` with the stock ioctl numbers (`IOCTL_MODEM_*`,
`IOCTL_SECURITY_REQ`), so a userspace loader matches the Android ABI.
`XMIT_BOOT` copies chunks into the boot region via a temporary write-combined
mapping.

2.2 Userspace `cbd-lite` (C, in this repo): read the RADIO TOC, load
BOOT/MAIN (and VSS) at their TOC offsets, NV from the EFS copy, issue the
security request, start the CP, wait for `CP_ACTIVE` and the boot-done
handshake, then `IOCTL_MODEM_BOOT_DONE`. OpenRC service `cbd`.

2.3 Crash handling: `CP2AP_RESET_REQ` IRQ → log CP status, stop cleanly, no
auto-reboot loop. `cp_ram_logging` readable for debugging.

Exit: CP stays alive more than 10 minutes, no reset request, stable AP (no
freeze from touching protected memory). Risk: if the security request fails,
compare the params byte for byte with the strace from Phase 0.

### Phase 3: IPC link and RFS

3.1 Kernel: SBD ring setup (`link_device_memory_sbd.c`), mailbox msg/status
IRQs, `umts_ipc0`, `umts_rfs0`, `umts_router` as character devices,
`rmnet0..7` as raw-IP netdevs (NAPI). Longer term, register them with the
mainline **WWAN** framework (`drivers/net/wwan`: AT port, wwan netdevs),
which ModemManager already understands.

3.2 `rfsd`: serve the CP's file requests on `umts_rfs0` against a mounted EFS
(start from a **copy** on tmpfs/disk, then the real EFS once the request
log looks sane). Replicant's libsamsung-ipc has RFS/NV handling to compare
against.

Exit: the CP finishes its NV/RFS start-up and sends its power-on/boot-complete
message on `umts_ipc0` (seen in a hex dump of the device).

### Phase 4: control protocol → ModemManager

Choose by the Phase 0 answer:

- **A. AT works on `umts_router`** (preferred, smallest): expose it as a WWAN
  AT port; ModemManager's generic plugin gives SIM/PIN, registration, signal,
  SMS, USSD. A small MM plugin may be needed for the data bearer on `rmnet0`
  and any vendor AT quirks.
- **B. Samsung IPC only**: implement the FMT protocol (power, SIM/SEC, NET,
  SMS, GPRS, CALL message groups) in a small daemon, modelled on
  libsamsung-ipc plus the captured traffic, and connect it to MM (plugin) or
  oFono. Much larger, but the protocol knowledge exists for older Samsung
  modems.
- **C. Fallback**: run Android `rild` + `libsec-ril.so` in a container with
  libhybris and talk to it via oFono's RIL driver. Heavy, awkward on musl;
  only if A and B both stall.

Exit: `mmcli -m 0` shows the SIM and registration; an SMS is sent and
received.

### Phase 5: mobile data

PDP context through the chosen protocol, raw-IP on `rmnet0`
(`ip link set rmnet0 up`, the address from the bearer), MM bearer →
NetworkManager. IPv4 then IPv6. Check the CP's DVFS requests (mailbox 5-7):
there is no MIF DVFS on our side, so LTE throughput may need a fixed MIF
floor.

Exit: `nmcli` brings up a mobile connection; a sustained download is stable
(keep the WiFi-RX reboot bug in mind when interpreting resets).

### Phase 6: voice calls

- Signalling: dial/answer/hang-up through MM (Phase 4 protocol).
- Audio: the CP's voice path runs through ABOX with the **VSS** firmware.
  Today `exynos8895-audio-vss.patch` maps the 8 MiB VSS window (IOVA
  0xA0500000..) to a dummy page; for calls it must map the real VSS area in
  `modem_if`, with VSS loaded from the RADIO TOC by cbd-lite. Then the ABOX
  call routing (CP ↔ UAIF0 codec / UAIF4 speaker), plus the microphones
  (MICBIAS, already an open audio item) and a UCM "Voice Call" verb for
  callaudiod.

Exit: a call with two-way audio on the earpiece and the speaker.

### Phase 7: robustness and packaging

- CP crash recovery (reset + re-boot through cbd-lite), airplane mode
  (rfkill / CP power off), behaviour across screen off.
- Packaging: kernel `exynos8895-modem.patch` (+ pkgrel), a
  `samsung-greatlte-modem` package (cbd-lite, rfsd, OpenRC services),
  ModemManager in the rootfs recipe, `modem.bin` read from RADIO at boot
  (never shipped). README "What works" row, BRINGUP section.

## 4. Order of work and decisions needed

1. Phase 0.1 backups and 0.2 static analysis: safe, can start now.
2. Phase 1.1 SMC probe: one kernel module, one boot. Go / no-go.
3. Decision for the user: is a live Android recon session (Phase 0.3) worth
   moving pmOS back to microSD for a while? It is the fastest way to answer the
   AT question and to capture a known-good cbd sequence.
4. Phases 1.2 → 3 in order; Phase 4 choice A/B/C after the AT test.
5. Data (5) before calls (6): calls depend on the unfinished microphone work.
