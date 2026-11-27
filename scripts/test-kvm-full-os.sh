#!/usr/bin/env bash
set -euo pipefail

# Usage: SOURCE_VM_DISK=/path/to/verified-offline-desktop.raw scripts/test-kvm-full-os.sh /path/to/linux-jarvisos-....pkg.tar.zst
# Use a whole-device ext4 JARVIS desktop image, not a partitioned or active disk.
die() { printf 'Full OS gate: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && -f $1 && $1 == *.pkg.tar.zst ]] || die "supply one finished linux-jarvisos .pkg.tar.zst archive"
KERNEL_PKG=$(realpath -- "$1")
[[ -n ${SOURCE_VM_DISK:-} ]] || die "set SOURCE_VM_DISK to a verified offline ext4 image"
BASE=$(realpath -e -- "$SOURCE_VM_DISK")
[[ -f $BASE && -r $BASE && $(blkid -p -s TYPE -o value "$BASE") == ext4 ]] || die "base must be a readable raw ext4 filesystem"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die "hardware KVM access is required"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read -r VERSION EXPECTED_RELEASE < <(
  source "$ROOT/PKGBUILD"
  upstream=${_srcname#cachyos-}
  printf '%s:%s-%s %s-%s%s%s\n' "$epoch" "$pkgver" "$pkgrel" "${upstream%-*}" "$pkgrel" "${pkgbase#linux}" "$pkgver"
)
umask 077
mkdir -p "$ROOT/out"
WORK=$(mktemp -d "$ROOT/out/kvm-full-os.XXXXXXXX")
printf 'Evidence: %s\n' "$WORK"
mkdir -p "$WORK/payload"
R="$WORK/init"
mkdir -p "$R"/{bin,dev,proc,sys,run,target,usr/lib}

# Stage once: metadata, kernel, module digest and pacman input all refer to
# this snapshot. Leave other runs (including their evidence) untouched.
PKG="$WORK/payload/kernel.pkg.tar.zst"
cp --reflink=auto -- "$KERNEL_PKG" "$PKG"
SIGNED=0
if [[ -s $KERNEL_PKG.sig ]]; then
  cp -- "$KERNEL_PKG.sig" "$PKG.sig"
  SIGNED=1
elif [[ ${ALLOW_UNSIGNED_LOCAL:-0} != 1 ]]; then
  die "detached package signature required (functional-only override: ALLOW_UNSIGNED_LOCAL=1)"
fi
bsdtar -xOf "$PKG" .PKGINFO > "$WORK/pkginfo"
for field in 'pkgname = linux-jarvisos' "pkgver = $VERSION" 'arch = x86_64'; do
  grep -Fxq "$field" "$WORK/pkginfo" || die "package metadata mismatch: $field"
done
bsdtar -tf "$PKG" > "$WORK/members"
! grep -Eq '(^|/)(signing_key\.pem|.*private.*\.pem)$' "$WORK/members" || die "archive leaks private signing material"
mapfile -t images < <(grep -E '^usr/lib/modules/[A-Za-z0-9._+-]+/vmlinuz$' "$WORK/members")
[[ ${#images[@]} == 1 ]] || die "expected exactly one packaged kernel image"
release=${images[0]#usr/lib/modules/}
release=${release%/vmlinuz}
[[ $release == "$EXPECTED_RELEASE" ]] || die "archive release $release does not match recipe $EXPECTED_RELEASE"
mapfile -t modules < <(grep -E '/jarvis\.ko(\.(xz|zst|gz))?$' "$WORK/members")
[[ ${#modules[@]} == 1 && ${modules[0]} == "usr/lib/modules/$release/kernel/drivers/jarvis/"* ]] || die "missing or ambiguous matching jarvis module"
bsdtar -xOf "$PKG" "${images[0]}" > "$WORK/vmlinuz"
[[ -s $WORK/vmlinuz ]] || die "empty packaged kernel image"
module_hash=$(bsdtar -xOf "$PKG" "${modules[0]}" | sha256sum)
printf '%s  /%s\n' "${module_hash%% *}" "${modules[0]}" > "$WORK/payload/module.sha256"
printf '%s\n' "$release" > "$WORK/payload/release"
printf '%s\n' "$VERSION" > "$WORK/payload/version"
{
  printf 'base=%s\narchive=%s\nrelease=%s\n' "$BASE" "$KERNEL_PKG" "$release"
  stat -Lc 'base_bytes=%s base_mtime=%y' -- "$BASE"
  blkid -p -- "$BASE"
  sha256sum "$PKG" "$WORK/vmlinuz"
  cat "$WORK/payload/module.sha256"
} | tee "$WORK/inputs.log"

echo "Cloning JARVIS VM disk with a CoW reflink..."
cp --reflink=always -- "$BASE" "$WORK/desktop-test.raw"
LC_ALL=C dumpe2fs -h "$WORK/desktop-test.raw" > "$WORK/clone-superblock.log"
grep -Eq '^Filesystem state:[[:space:]]+clean$' "$WORK/clone-superblock.log" &&
  ! grep -Eq '^Filesystem features:.*[[:space:]]needs_recovery([[:space:]]|$)' "$WORK/clone-superblock.log" ||
  die "clone is dirty or needs journal recovery; use an offline base"
clang -O2 -Wall -Wextra "$ROOT/tests/jarvis_userspace_check.c" -o "$WORK/payload/jarvis-kernel-check"
chmod 755 "$WORK/payload/jarvis-kernel-check"
truncate -s "$(( $(du -sb "$WORK/payload" | cut -f1) + 32*1024*1024 ))" "$WORK/packages.raw"
mkfs.ext4 -q -F -m 0 -d "$WORK/payload" "$WORK/packages.raw"

ln -s usr/lib "$R/lib"
ln -s usr/lib "$R/lib64"
cp /usr/lib/initcpio/busybox "$R/bin/busybox"
# Arch's initcpio BusyBox has umount but not mount.
install -m755 /usr/bin/mount "$R/bin/mount"
for bin in "$R/bin/busybox" "$R/bin/mount"; do
  while read -r lib; do
    cp -L -- "$lib" "$R/usr/lib/${lib##*/}"
  done < <(ldd "$bin" | awk '/=> \// {print $3} /^[[:space:]]*\/[^ ]+ \(/ {print $1}')
done

cat > "$R/init" << 'INITEOF'
#!/bin/busybox sh
set -eu
export PATH=/bin:/usr/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run
mount -t ext4 /dev/vda /target
mkdir -p /target/dev /target/sys /target/proc /target/run
for fs in dev sys proc run; do mount --bind "/$fs" "/target/$fs"; done

P=/run/jarvis-release-gate
mkdir -p "/target$P"
mount -t ext4 -o ro /dev/vdb "/target$P"
release=$(cat "/target$P/release")
[ "$(uname -r)" = "$release" ]
# A release gate verifies the detached signature through the guest's installed
# pacman keyring before asking pacman to enforce dependencies and install it.
if [ -f "/target$P/kernel.pkg.tar.zst.sig" ]; then
  chroot /target /usr/bin/pacman-key --verify "$P/kernel.pkg.tar.zst.sig"
fi
chroot /target /usr/bin/pacman -U --noconfirm "$P/kernel.pkg.tar.zst"
chroot /target depmod "$release"

mkdir -p /target/etc/modules-load.d /target/usr/local/lib/jarvis-release-gate
printf 'jarvis\n' > /target/etc/modules-load.d/jarvis.conf
D=/target/usr/local/lib/jarvis-release-gate
cp "/target$P/release" "/target$P/version" "/target$P/module.sha256" "/target$P/jarvis-kernel-check" "$D/"
chmod 755 "$D" "$D/jarvis-kernel-check"

cat > "$D/verify" << 'VERIFY'
#!/bin/sh
set -eu
echo '=== FULL_OS_KVM_VERIFY_START ==='
cd /usr/local/lib/jarvis-release-gate
release=$(cat release)
[ "$(uname -r)" = "$release" ]
[ "$(pacman -Q linux-jarvisos)" = "linux-jarvisos $(cat version)" ]
sig_enforce=$(cat /sys/module/module/parameters/sig_enforce)
echo "SIG_ENFORCE=$sig_enforce"
[ "$sig_enforce" = Y ] || { echo "FAIL: module signatures not enforced"; exit 1; }
echo "GUEST_RELEASE=$release"
health=$(systemctl is-system-running --wait) || { systemctl --failed --no-pager; exit 1; }
[ "$health" = running ]
systemctl is-active --quiet multi-user.target
failed=$(systemctl --failed --no-legend --no-pager --plain)
[ -z "$failed" ] || { echo "$failed"; exit 1; }
echo 'FAILED_UNITS=0'
[ -d /sys/module/jarvis ]
grep -q '^jarvis ' /proc/modules
module=$(awk '{print $2}' module.sha256)
[ "$(realpath "$(modinfo -n jarvis)")" = "$module" ]
sha256sum -c module.sha256
[ -c /dev/jarvis ] || { echo 'FAIL: /dev/jarvis missing'; exit 1; }
device_mode=$(stat -c '%a %U:%G' /dev/jarvis)
echo "JARVIS_DEVICE=$device_mode"
[ "$device_mode" = '660 root:jarvis' ] || { echo "FAIL: unsafe /dev/jarvis ownership or mode"; exit 1; }
bore=$(cat /proc/sys/kernel/sched_bore)
echo "SCHED_BORE=$bore"
[ "$bore" = 1 ] || { echo "FAIL: BORE disabled"; exit 1; }
scheduler=$(cat /sys/block/vda/queue/scheduler)
echo "VDA_SCHEDULER=$scheduler"
printf '%s\n' "$scheduler" | grep -Fq '[adios]' || { echo "FAIL: ADIOS not selected"; exit 1; }
tcp=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
echo "TCP_CONGESTION=$tcp"
[ "$tcp" = bbr3 ] || { echo "FAIL: BBRv3 not selected"; exit 1; }
command -v setpriv || { echo 'FAIL: setpriv missing'; exit 1; }
id jarvis
ls -l ./jarvis-kernel-check
if ! setpriv --reuid=jarvis --regid=jarvis --init-groups -- ./jarvis-kernel-check; then
  echo "FAIL: non-root userspace policy check"
  exit 1
fi
echo '=== FULL_OS_KVM_VERIFY_PASS ==='
systemctl poweroff --no-block
VERIFY
chmod 755 "$D/verify"

cat > /target/etc/systemd/system/jarvis-kernel-verify.service << 'UNIT'
[Unit]
Description=Verify linux-jarvisos full OS boot in KVM
After=systemd-udev-trigger.service systemd-modules-load.service

[Service]
# Complete the startup job before waiting for the manager to finish booting.
Type=simple
StandardOutput=tty
TTYPath=/dev/ttyS0
StandardError=inherit
ExecStart=/usr/local/lib/jarvis-release-gate/verify

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /target/etc/systemd/system/multi-user.target.wants
ln -sf ../jarvis-kernel-verify.service /target/etc/systemd/system/multi-user.target.wants/jarvis-kernel-verify.service

umount "/target$P"
for fs in run proc sys dev; do umount "/target/$fs"; done
umount /target
sync
printf '\nSTAGE1_INSTALL_OK\n'
poweroff -f
INITEOF
chmod 755 "$R/init"

(cd "$R" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1 > "$WORK/install-init.gz")

qemu=(qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m 1536 -no-reboot
      -nic none -display none -monitor none -drive "file=$WORK/desktop-test.raw,format=raw,if=virtio")
run_stage() {
  local log=$1 marker=$2
  shift 2
  if ! timeout -k 10s 180s "${qemu[@]}" -serial "file:$log" "$@" ||
     ! grep -Fxq "$marker" < <(tr -d '\r' < "$log"); then
    tail -n 60 "$log" >&2
    die "stage failed ($log)"
  fi
}

echo "Installing linux-jarvisos $VERSION into the clone..."
run_stage "$WORK/stage1-install.log" 'STAGE1_INSTALL_OK' \
  -kernel "$WORK/vmlinuz" -initrd "$WORK/install-init.gz" \
  -append "console=ttyS0 quiet loglevel=3 panic=1" \
  -drive "file=$WORK/packages.raw,format=raw,if=virtio,readonly=on"

# Boot the clone's installed kernel and initramfs, not a host or staging image.
(cd "$WORK"
 debugfs -R 'dump /boot/vmlinuz-linux-jarvisos installed-vmlinuz' desktop-test.raw
 debugfs -R 'dump /boot/initramfs-linux-jarvisos.img installed-initramfs' desktop-test.raw)
cmp "$WORK/vmlinuz" "$WORK/installed-vmlinuz" || die "installed kernel differs from archive"
[[ -s $WORK/installed-initramfs ]] || die "no installed initramfs"
echo "Booting full JARVIS OS with $release..."
run_stage "$WORK/stage2-boot.log" '=== FULL_OS_KVM_VERIFY_PASS ===' \
  -kernel "$WORK/installed-vmlinuz" -initrd "$WORK/installed-initramfs" \
  -append "root=/dev/vda rw rootwait console=ttyS0 panic=1"
for proof in "GUEST_RELEASE=$release" FAILED_UNITS=0 JARVIS_USERSPACE_IOCTL_OK; do
  grep -Fxq "$proof" < <(tr -d '\r' < "$WORK/stage2-boot.log") || die "missing guest evidence: $proof"
done
if (( SIGNED )); then
  printf 'PASS: linux-jarvisos %s (%s); evidence: %s\n' "$VERSION" "$release" "$WORK"
else
  printf 'FUNCTIONAL PASS (UNSIGNED; NOT RELEASE): linux-jarvisos %s (%s); evidence: %s\n' "$VERSION" "$release" "$WORK"
fi
