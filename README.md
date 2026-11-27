# `jarvis-kernel` (`linux-jarvisos 1:1.0-1`)

Custom Linux kernel (`7.3.6-1-jarvisos1.0`) for **JARVIS OS**, combining the CachyOS `7.3.6` kernel base, BORE CPU scheduler, ADIOS `3.3.0` I/O scheduler, TCP BBRv3, Omarchy desktop tuning, and the in-tree `drivers/jarvis/` AI integration module (`/dev/jarvis`).

---

## Architecture & Key Features

| Component | Configuration / Details |
|---|---|
| **Base Kernel** | CachyOS `cachyos-7.3.6-1` (`CONFIG_CACHY=y`, Clang ThinLTO, `-O3`, `x86-64-v3`) |
| **CPU Scheduler** | BORE (`patches/0001-bore-cachy.patch`, `CONFIG_SCHED_BORE=y`, `1000 Hz`, `PREEMPT_DYNAMIC`, `NO_HZ_FULL`) |
| **I/O Scheduler** | ADIOS `3.3.0` default MQ scheduler (`CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`, BFQ + Kyber available) |
| **Networking** | TCP BBRv3 default (`CONFIG_DEFAULT_TCP_CONG="bbr3"`) + Fair Queue (`CONFIG_DEFAULT_FQ=y`) |
| **Module Integrity** | Mandatory kernel module signature enforcement (`CONFIG_MODULE_SIG_FORCE=y`, SHA-512) |
| **Memory & Security** | MGLRU (`CONFIG_LRU_GEN_ENABLED=y`), `zram`-safe (`# CONFIG_ZSWAP_DEFAULT_ON is not set`), Landlock, seccomp, `io_uring`, cgroups |
| **JARVIS Drivers** | `drivers/jarvis/` (`jarvis.ko`) + `include/linux/jarvis.h` + `include/uapi/linux/jarvis.h` + `99-jarvis-dev.rules` |
| **Target Profile** | `localmod.db` tuned for Intel Alder Lake (`i5-1235U`, Iris Xe `i915`/`xe`, Intel SOF audio, Realtek `rtw88_8822ce`), staying safely inside `7.4 GiB` RAM during builds (`_jobs=1`, `CONFIG_DEBUG_INFO_NONE=y`) |

---

## `drivers/jarvis/` Kernel Subsystems

Built from `patches/0002-jarvis-drivers.patch` (mirrored in `drivers/jarvis/` and `include/`) as `CONFIG_JARVIS=m` (`jarvis.ko`), exposing `/dev/jarvis` (`0660 root:jarvis` via `99-jarvis-dev.rules`) and `/sys/class/misc/jarvis`:

- **`jarvis_core.c`**: Misc character device `/dev/jarvis` with dual KFIFO query/response queues, daemon connection/state/model/provider tracking (`JARVIS_IOC_STATUS`, `JARVIS_IOC_SET_STATE`, `JARVIS_IOC_SET_MODEL`, `JARVIS_IOC_SET_PROVIDER`, `JARVIS_IOC_RESPOND`, `JARVIS_IOC_FLUSH`), and sysfs attributes (`state`, `model`, `pending`).
- **`jarvis_policy.c`**: Tiered MCP action policy engine (`SAFE`, `ELEVATED`, `DANGEROUS`, `FORBIDDEN`) with path-prefix rules protecting sensitive directories (`/etc`, `/usr`, `/boot`, `/sys`, `/proc`, `/sbin`, `/bin`, `/lib`, `/lib64`), per-rule token-bucket rate limiting, and atomic policy-table resets (`JARVIS_IOC_POLICY_*`).
- **`jarvis_sysmon.c`**: Real-time CPU load/count, RAM/swap, and thermal zone sampling exposed via `JARVIS_IOC_SYSMON` and `/sys/class/misc/jarvis/sysmon/`.
- **`jarvis_keys.c`**: Private `_jarvis` kernel keyring integration (`JARVIS_IOC_KEY_*`, `CAP_SYS_ADMIN` gated).
- **`jarvis_dibs.c`**: DIBS (`CONFIG_DIBS=y`) zero-copy direct memory buffer slot registration (`JARVIS_IOC_DIBS_REG` / `JARVIS_IOC_DIBS_UNREG`).

Userspace Python bindings live in the main [JARVIS-OS](https://github.com/Jarvis-os-tech/JARVIS-OS) repository (`kernel/jarvis_dev.py`).

---

## Repository Layout

```text
jarvis-kernel/
├── PKGBUILD                       # Arch Linux recipe (linux-jarvisos + linux-jarvisos-headers)
├── config                         # Base CachyOS 7.3 kernel configuration
├── jarvisos.fragment.config       # JARVIS OS Kconfig overrides merged onto base config
├── localmod.db                    # Targeted hardware module list for localmodconfig
├── 99-jarvis-dev.rules            # udev rule setting /dev/jarvis to 0660 root:jarvis
├── patches/
│   ├── 0001-bore-cachy.patch      # CachyOS BORE scheduler patch
│   └── 0002-jarvis-drivers.patch  # Cleaned drivers/jarvis/ and UAPI header patch
├── drivers/jarvis/                # JARVIS kernel driver sources (synced with patch 0002)
├── include/
│   ├── linux/jarvis.h             # In-kernel JARVIS API header
│   └── uapi/linux/jarvis.h        # Userspace UAPI header
├── scripts/
│   ├── build-kernel.sh            # Pre-flight validator and bounded makepkg wrapper
│   ├── test-kvm.sh                # Direct-kernel QEMU/KVM smoke test + policy race checks
│   ├── test-package-kvm.sh        # Package metadata, signature enforcement & KVM archive gate
│   ├── test-kvm-full-os.sh        # Full-OS reflink KVM install & boot gate
│   └── verify-repo.sh             # Repo syntax, b2sum, patch sync & C test compile check
├── tests/
│   ├── jarvis_kvm_init.c          # Zero-dependency KVM /init smoke & concurrency test
│   ├── jarvis_userspace_check.c   # Non-root /dev/jarvis userspace verification binary
│   └── uapi_jarvis.h              # UAPI header copy for standalone test builds
├── docs/
│   └── VALIDATION-2026-11-27.md   # Hardware & KVM validation report for 1:1.0-1
├── knowledge-base/
│   └── PROJECT-LESSONS.md         # Engineering lessons from kernel bring-up & debugging
├── KERNEL-BUILD-PLAN.md           # Build, verification, and release gate checklist
└── JARVIS-OS-STAGE2-HANDOFF.md    # Bare-metal Stage 2 verification checklist
```

---

## Build & Verification

### 1. Verify Repository Integrity

```bash
./scripts/verify-repo.sh
```

> **Note:** If you modify files under `drivers/jarvis/` or `include/`, regenerate `patches/0002-jarvis-drivers.patch` and update its `b2sums` entry in `PKGBUILD` so `makepkg` and `verify-repo.sh` stay in sync.

### 2. Build Arch Packages (`linux-jarvisos` & `linux-jarvisos-headers`)

`makepkg` downloads `cachyos-7.3.6-1.tar.gz` automatically from upstream CachyOS releases and verifies its BLAKE2b checksum. Requires Arch kernel build tools (`clang`, `lld`, `llvm`, `pahole`, `bison`, `flex`, `cpio`, `bc`, `makepkg`) and ~18–25 GiB free disk space:

```bash
./scripts/build-kernel.sh
```

Built packages are written to `out/`:
- `out/linux-jarvisos-1:1.0-1-x86_64.pkg.tar.zst`
- `out/linux-jarvisos-headers-1:1.0-1-x86_64.pkg.tar.zst`

### 3. Run KVM Verification Gates

```bash
# Package metadata, forced module signature, and KVM smoke + policy reset race gate
./scripts/test-package-kvm.sh \
  out/linux-jarvisos-1:1.0-1-x86_64.pkg.tar.zst \
  out/linux-jarvisos-headers-1:1.0-1-x86_64.pkg.tar.zst

# Full-OS reflink clone install and boot verification (requires signed package or ALLOW_UNSIGNED_LOCAL=1)
SOURCE_VM_DISK=/path/to/offline-desktop.raw ALLOW_UNSIGNED_LOCAL=1 \
  ./scripts/test-kvm-full-os.sh out/linux-jarvisos-1:1.0-1-x86_64.pkg.tar.zst
```

---

## License

Linux kernel driver sources, patches, and packaging recipes are licensed under **GPL-2.0-only** ([`LICENSE`](LICENSE)).
