# J.A.R.V.I.S. OS Kernel Build — Stage 2 Bare-Metal Handoff

**Historical baseline, not a deployment instruction.** The `7.3.6-1` packages below are rollback artifacts with a known policy defect. For the 1.0 candidate, use [release checks](KERNEL-BUILD-PLAN.md#jarvis-os-kernel-10-release-checks) and the [validation report](docs/VALIDATION-2026-11-27.md).

You are running inside **J.A.R.V.I.S. OS** (`/dev/nvme0n1p1`, `ext4`), continuing from Stage 1 (KVM verification) on the host Omarchy system (`/home/g0pi/Projects/kernel`).

## Background Summary
- **Custom Kernel Built**: `linux-jarvisos 7.3.6-1` (`7.3.6-1-jarvisos`), combining:
  - CachyOS `7.3.6` base (`x86-64-v3`, `LLVM=1` ThinLTO, `-O3`, `1000 Hz`, `PREEMPT_DYNAMIC`, `NO_HZ_FULL`, `CONFIG_DEBUG_INFO_NONE=y`)
  - BORE scheduler (`patches/0001-bore-cachy.patch`, `CONFIG_SCHED_BORE=y`)
  - ADIOS I/O scheduler default (`CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`)
  - TCP BBRv3 default (`CONFIG_DEFAULT_TCP_CONG="bbr3"`)
  - Omarchy Alder Lake / desktop tuning + targeted `localmod.db` hardware modules (`i915`, `xe`, `rtw88_8822ce`, `snd_sof_pci_intel_tgl`, `nvme`, `ext4`, `btrfs`, `dm_crypt`, `zram`)
  - `JarvisOSLinux/linux-jarvisos` `drivers/jarvis/` (`patches/0002-jarvis-drivers.patch`, `CONFIG_JARVIS=m`, udev rule `99-jarvis-dev.rules` -> `/dev/jarvis` `0660 root:jarvis`)
- **Stage 1 (KVM) — Passed**:
  - `scripts/test-kvm.sh`: `=== JARVIS_KVM_SMOKE_PASS ===`
  - `scripts/test-kvm-full-os.sh`: `=== FULL_OS_KVM_VERIFY_PASS ===` (`FAILED_UNITS=0`; note benign `systemd[1]: bpf-restrict-fs: Failed to load BPF object: No such process` is expected because `CONFIG_DEBUG_INFO_BTF` is disabled via `CONFIG_DEBUG_INFO_NONE=y`).
- **Stage 2 Setup Installed on `/dev/nvme0n1p1`**:
  - `linux-jarvisos 7.3.6-1` + `/etc/modules-load.d/jarvis.conf` (`jarvis`)
  - Omarchy Shell (`omarchy 4.5.0-3`, `omarchy-settings 4.5.0-3`, patched `quickshell 0.3.2.r7.g2b4501a-1`, `owe 0.2.14-1`) + TTY1 autologin into Hyprland (`J.A.R.V.I.S. OS (7.3.6-1-jarvisos)` Limine entry).

## What To Verify Now (Stage 2 Bare-Metal Checklist)
When asked to run Stage 2 bare-metal verification here in J.A.R.V.I.S. OS:

1. **Kernel, Schedulers & TCP**:
   ```bash
   uname -a
   sysctl kernel.sched_bore net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control
   cat /sys/block/nvme0n1/queue/scheduler
   ```
   Expected: `7.3.6-1-jarvisos`, `kernel.sched_bore = 1`, `bbr3` active, `[adios]` active on `nvme0n1`.

2. **JARVIS Kernel Module, Udev & IOCTLs**:
   ```bash
   lsmod | grep -E 'jarvis|rtw88|sof|i915|xe'
   ls -la /dev/jarvis
   cat /sys/class/misc/jarvis/state /sys/class/misc/jarvis/sysmon/mem_total
   cc -O2 -Wall -Wextra tests/jarvis_userspace_check.c -o /tmp/jarvis-userspace-check && /tmp/jarvis-userspace-check
   ```
   Expected: `/dev/jarvis` owned by `root:jarvis` (`crw-rw----`), `JARVIS_USERSPACE_IOCTL_OK` with real CPU count / RAM / policy checks.

3. **Hardware Drivers, Systemd & Omarchy Shell**:
   ```bash
   systemctl --failed
   journalctl -b -p err --no-pager | head -n 40
   lspci -k | grep -EA3 'VGA|Display|Network|Audio'
   ip -br link
   wpctl status
   quickshell --version
   pgrep -af 'Hyprland|quickshell|omarchy-launch-shell'
   ```

4. **After Stage 2 Passes**:
   Record the tested artifact identity. A baseline pass is not authority to deploy those packages; use only an explicitly approved, verified release for a host change.
