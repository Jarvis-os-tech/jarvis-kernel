#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KERNEL_IMG="${1:-}"
JARVIS_KO="${2:-}"
DIBS_KO="${3:-}"

# Auto-detect built kernel package artifacts or fallback to running kernel + local scratch module
if [[ -z "$KERNEL_IMG" ]]; then
  if compgen -G "$ROOT/pkg/linux-jarvisos/usr/lib/modules/*/vmlinuz" >/dev/null 2>&1; then
    KERNEL_IMG="$(ls "$ROOT"/pkg/linux-jarvisos/usr/lib/modules/*/vmlinuz | head -n 1)"
  elif [[ -r "/usr/lib/modules/$(uname -r)/vmlinuz" ]]; then
    KERNEL_IMG="/usr/lib/modules/$(uname -r)/vmlinuz"
  else
    echo "ERROR: Pass kernel path: $0 <vmlinuz> [jarvis.ko] [dibs.ko]" >&2
    exit 1
  fi
fi

KVER="$(basename "$(dirname "$KERNEL_IMG")")"

if [[ -z "$JARVIS_KO" ]]; then
  if [[ -f "$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/jarvis/jarvis.ko.zst" ]]; then
    JARVIS_KO="$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/jarvis/jarvis.ko.zst"
  elif [[ -f "$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/jarvis/jarvis.ko" ]]; then
    JARVIS_KO="$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/jarvis/jarvis.ko"
  elif [[ -f "/usr/lib/modules/$KVER/build/Module.symvers" ]]; then
    echo "Building matching jarvis.ko against $KVER headers for KVM verification..."
    MOD_STAGE="$ROOT/out/kvm-mod-build"
    rm -rf "$MOD_STAGE"
    mkdir -p "$MOD_STAGE/include/linux" "$MOD_STAGE/include/uapi/linux"
    (
      cd "$MOD_STAGE"
      # Extract drivers/jarvis and headers cleanly from patches/0002-jarvis-drivers.patch
      python3 - "$ROOT/patches/0002-jarvis-drivers.patch" "$MOD_STAGE" << 'PY'
import sys, re, os
patch_path, dst_root = sys.argv[1], sys.argv[2]
with open(patch_path) as f:
    text = f.read()
for blk in text.split("diff --git "):
    m = re.match(r"a/(\S+) b/(\S+)\n", blk)
    if not m:
        continue
    fn = m.group(2)
    if not (fn.startswith("drivers/jarvis/") or fn in ("include/linux/jarvis.h", "include/uapi/linux/jarvis.h")):
        continue
    idx = blk.find("@@")
    if idx < 0:
        continue
    body_lines = []
    for line in blk[idx:].splitlines()[1:]:
        if line.startswith("+"):
            body_lines.append(line[1:])
        elif line.startswith(" "):
            body_lines.append(line[1:])
    rel = fn[len("drivers/jarvis/"):] if fn.startswith("drivers/jarvis/") else fn
    outp = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    with open(outp, "w") as out:
        out.write("\n".join(body_lines) + "\n")
PY
      cat > "$MOD_STAGE/Kbuild" << 'KBLD'
ccflags-y := -I$(src)/include -I$(src)/include/uapi -DCONFIG_JARVIS=1 -DCONFIG_JARVIS_DIBS=1 -DCONFIG_JARVIS_SYSMON=1 -DCONFIG_JARVIS_POLICY=1 -DCONFIG_JARVIS_KEYS=1
obj-m += jarvis.o
jarvis-y := jarvis_core.o jarvis_dibs.o jarvis_sysmon.o jarvis_policy.o jarvis_keys.o
KBLD
      make -C "/usr/lib/modules/$KVER/build" M="$MOD_STAGE" LLVM=1 LLVM_IAS=1 modules >/dev/null
    )
    JARVIS_KO="$MOD_STAGE/jarvis.ko"
  else
    echo "ERROR: jarvis.ko not found and headers for $KVER not installed." >&2
    exit 1
  fi
fi

if [[ -z "$DIBS_KO" ]]; then
  for cand in \
    "$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/dibs/dibs.ko.zst" \
    "$ROOT/pkg/linux-jarvisos/usr/lib/modules/$KVER/kernel/drivers/dibs/dibs.ko" \
    "/usr/lib/modules/$KVER/kernel/drivers/dibs/dibs.ko.zst" \
    "/usr/lib/modules/$KVER/kernel/drivers/dibs/dibs.ko"; do
    if [[ -f "$cand" ]]; then
      DIBS_KO="$cand"
      break
    fi
  done
fi

STAGE="$ROOT/out/kvm-initrd"
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/lib/modules" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev"
ln -s usr/lib "$STAGE/lib"
ln -s usr/lib "$STAGE/lib64"
mkdir -p "$ROOT/out"

echo "Compiling tests/jarvis_kvm_init.c..."
clang -O2 -Wall -Wextra -pthread -Wl,-rpath,/usr/lib:/lib "$ROOT/tests/jarvis_kvm_init.c" -o "$STAGE/init"
chmod 755 "$STAGE/init"

# Bundle required shared libraries for /init into usr/lib (Arch /lib -> usr/lib layout)
while IFS= read -r lib; do
  if [[ -e "$lib" ]]; then
    cp -L "$lib" "$STAGE/usr/lib/"
  fi
done < <(ldd "$STAGE/init" | grep -oE '/[^ ]+' | sort -u)

copy_ko() {
  local src="$1" dst="$2"
  if [[ "$src" == *.zst ]]; then
    zstd -d -q -f "$src" -o "$dst"
  else
    cp "$src" "$dst"
  fi
}

copy_ko "$JARVIS_KO" "$STAGE/lib/modules/jarvis.ko"
# '-' selects built-in DIBS without consulting the host module tree.
if [[ -n "$DIBS_KO" && "$DIBS_KO" != - ]]; then
  copy_ko "$DIBS_KO" "$STAGE/lib/modules/dibs.ko"
fi

INITRD="$ROOT/out/test-initramfs.cpio.gz"
(cd "$STAGE" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -1 > "$INITRD")

DISK_IMG="$ROOT/out/kvm-scratch.raw"
truncate -s 16M "$DISK_IMG"

KVM_ARGS=()
if [[ -c /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
elif [[ ${REQUIRE_KVM:-0} == 1 ]]; then
  echo "ERROR: hardware KVM required but /dev/kvm is unavailable" >&2
  exit 1
else
  echo "WARNING: /dev/kvm not writable; falling back to TCG emulation" >&2
  KVM_ARGS=(-cpu max)
fi

CMDLINE="console=ttyS0 quiet loglevel=4 rdinit=/init panic=1"
if [[ ${REQUIRE_KVM:-0} == 1 && ${KERNEL_ENFORCES_MODULE_SIG:-0} != 1 ]]; then
  CMDLINE+=" module.sig_enforce=1"
fi

echo "Booting $KERNEL_IMG in QEMU (${KVM_ARGS[*]})..."
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
timeout 180 qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -m 512M \
  -smp 2 \
  -nographic \
  -nic none \
  -no-reboot \
  -kernel "$KERNEL_IMG" \
  -initrd "$INITRD" \
  -drive "file=$DISK_IMG,if=virtio,format=raw" \
  -append "$CMDLINE" 2>&1 | tee "$LOG"
grep -q '^=== JARVIS_KVM_SMOKE_PASS ===' "$LOG"
! grep -q 'JARVIS_KVM_SMOKE_FAIL' "$LOG"
