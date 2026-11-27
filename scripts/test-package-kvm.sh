#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $(basename "$0") KERNEL.pkg.tar.zst HEADERS.pkg.tar.zst"
  echo 'Requires Arch packaging tools, the test-kvm.sh dependencies and hardware KVM.'
  echo 'Evidence is retained under PACKAGE_KVM_EVIDENCE_ROOT (default: repository out/).'
}
die() { echo "ERROR: $*" >&2; exit 1; }
[[ ${1:-} != --help ]] || { usage; exit 0; }
[[ $# == 2 ]] || { usage >&2; exit 2; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
declare -A archive
archive[kernel]=$(realpath -e -- "$1")
archive[headers]=$(realpath -e -- "$2")
parent=${PACKAGE_KVM_EVIDENCE_ROOT:-$ROOT/out}
mkdir -p -- "$parent"
run=$(mktemp -d -- "$(realpath -- "$parent")/package-kvm.XXXXXXXX")
echo "Evidence: $run"
cd "$run"
exec > >(tee gate.log) 2>&1
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die 'Hardware KVM access required'

# Evaluate only the trusted repository recipe, never shell-source package metadata.
cp -- "$ROOT/PKGBUILD" .
recipe=$(startdir=$ROOT; source ./PKGBUILD; upstream=${_srcname#cachyos-};
  printf '%s %s %s %s' "$pkgbase" "${epoch:+$epoch:}$pkgver-$pkgrel" "${arch[0]}" \
    "${upstream%-*}-$pkgrel${pkgbase#linux}$pkgver")
read -r base version arch expected_release <<< "$recipe"
recipe_hash=$(sha256sum PKGBUILD); recipe_hash=${recipe_hash%% *}
printf 'Recipe: %s (%s)\n' "$recipe" "$recipe_hash"
sha256sum -- "${archive[kernel]}" "${archive[headers]}" > archives.sha256
cat archives.sha256

# Stream only named, unique members to regular files, never unpack archive links.
extract() {
  local part=$1 member=$2 file=$1/$2
  [[ $(grep -Fxc -- "$member" "$part.members") == 1 ]] || die "$part: expected exactly one $member"
  mkdir -p -- "$(dirname "$file")"
  bsdtar -xqOf "${archive[$part]}" -- "$member" > "$file"
  [[ -s $file ]] || die "$part: empty $member"
  sha256sum -- "$file" >> members.sha256
}
expect_field() {
  local value
  value=$(awk -F ' = ' -v key="$2" '$1 == key {print $2}' "$1")
  [[ $value == "$3" ]] || die "$1: expected $2 = $3, got '$value'"
}
for part in kernel headers; do
  bsdtar -tf "${archive[$part]}" > "$part.members"
  ! grep -Eq '(^|/)(signing_key\.pem|.*private.*\.pem)$' "$part.members" || die "$part leaks private signing material"
  extract "$part" .PKGINFO
  extract "$part" .BUILDINFO
  name=$base; [[ $part != headers ]] || name=$base-headers
  for meta in "$part/.PKGINFO" "$part/.BUILDINFO"; do
    expect_field "$meta" pkgname "$name"
    expect_field "$meta" pkgbase "$base"
    expect_field "$meta" pkgver "$version"
  done
  expect_field "$part/.PKGINFO" arch "$arch"
  expect_field "$part/.BUILDINFO" pkgarch "$arch"
  expect_field "$part/.BUILDINFO" pkgbuild_sha256sum "$recipe_hash"
  # Reject missing or mixed release trees even if one vmlinuz happens to match.
  tree=$(awk -F/ '$1=="usr" && $2=="lib" && $3=="modules" && $4!="" {print $4}' "$part.members" | sort -u)
  [[ $tree == "$expected_release" ]] || die "$part: unexpected release tree(s): '$tree'"
  if [[ $part == kernel ]]; then release=$tree; fi
done
grep -Fxq "depend = $base=$version" headers/.PKGINFO || die 'headers do not pin this kernel version'
mods=usr/lib/modules/$release
extract kernel "$mods/vmlinuz"
extract kernel "$mods/pkgbase"
[[ $(<"kernel/$mods/pkgbase") == "$base" ]] || die 'wrong kernel pkgbase'
extract headers "$mods/build/version"
extract headers "$mods/build/include/config/kernel.release"
extract headers "$mods/build/include/generated/utsrelease.h"
extract headers "$mods/build/.config"
grep -Fxq 'CONFIG_MODULE_SIG_FORCE=y' "headers/$mods/build/.config" || die 'kernel does not force trusted module signatures'
[[ $(<"headers/$mods/build/version") == "$release" &&
   $(<"headers/$mods/build/include/config/kernel.release") == "$release" &&
   $(<"headers/$mods/build/include/generated/utsrelease.h") == "#define UTS_RELEASE \"$release\"" ]] || die 'headers ABI mismatch'
extract kernel "$mods/modules.builtin"
grep -Fxq 'kernel/drivers/dibs/dibs.ko' "kernel/$mods/modules.builtin" || die 'expected built-in DIBS'
ko=$mods/kernel/drivers/jarvis/jarvis.ko
member=$(grep -Fx -e "$ko" -e "$ko.zst" kernel.members) || die 'no packaged JARVIS module'
[[ $member == "$ko" || $member == "$ko.zst" ]] || die 'ambiguous JARVIS module'
extract kernel "$member"
raw=$run/kernel/$ko
if [[ $member == *.zst ]]; then zstd -dq "kernel/$member" -o "$raw"; fi
modinfo "$raw" > modinfo.log
vermagic=$(modinfo -F vermagic "$raw")
signer=$(modinfo -F signer "$raw")
printf 'vermagic=%s\nsigner=%s\n' "$vermagic" "$signer"
[[ ${vermagic%% *} == "$release" && $(modinfo -F name "$raw") == jarvis ]] || die 'module ABI/name mismatch'
[[ -n $signer && -n $(modinfo -F sig_key "$raw") ]] || die 'module signature metadata missing'

# A private harness root keeps its scratch disk, initramfs, sources and logs together.
mkdir scripts tests
cp -- "$ROOT/scripts/test-kvm.sh" scripts/
cp -- "$ROOT/tests/"{jarvis_kvm_init.c,uapi_jarvis.h} tests/
sha256sum scripts/test-kvm.sh tests/* > harness.sha256
REQUIRE_KVM=1 KERNEL_ENFORCES_MODULE_SIG=1 bash scripts/test-kvm.sh "$run/kernel/$mods/vmlinuz" "$raw" - 2>&1 | tr -d '\r' | tee guest.log
awk -v rel="release=$release" -v mach="machine=$arch" \
  '$1=="[KERN]" {seen++; if ($2==rel && $3==mach) ok++} END {exit !(seen==1 && ok==1)}' guest.log || die 'wrong guest release/arch'
for marker in '[MOD]   sig_enforce=Y' '[MOD]   jarvis.ko loaded cleanly' \
    '[POLICY] FileSystemMCP:read_file -> tier=0 allowed=1 (SAFE)' \
    '[POLICY] ShellMCP:run(/etc/passwd) -> tier=3 allowed=0 (FORBIDDEN)' \
    '[POLICY] scoped deny added, enforced and removed' '=== JARVIS_KVM_SMOKE_PASS ==='; do
  grep -Fxq -- "$marker" guest.log || die "guest did not report: $marker"
done
grep -Eq '^POLICY_RESET_RACE checks=[1-9][0-9]* forbidden_allowed=0 resets=[1-9][0-9]* errors=0$' guest.log || die 'missing clean policy regression counters'
if grep -Fq 'JARVIS_KVM_SMOKE_FAIL' guest.log; then die 'guest reported failure'; fi
staged=out/kvm-initrd/usr/lib/modules/jarvis.ko
cmp -- "$raw" "$staged"
bsdtar -xOf out/test-initramfs.cpio.gz usr/lib/modules/jarvis.ko | cmp -- "$raw" -
sha256sum -- "kernel/$ko" "$staged" out/test-initramfs.cpio.gz >> members.sha256
cat members.sha256
sha256sum --check archives.sha256
printf '=== PACKAGE_KVM_PASS === %s %s %s\n' "$base" "$version" "$release"
