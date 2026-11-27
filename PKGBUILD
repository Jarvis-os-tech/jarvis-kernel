# Maintainer: Gopi (JARVIS OS Unified Kernel)
# Based on CachyOS/linux-cachyos PKGBUILD + BORE + ADIOS 3.3.0 + JarvisOSLinux drivers/jarvis/

### Build options (override via env, e.g. _jobs=4 _processor_opt=NATIVE makepkg)
: "${_processor_opt:=GENERIC_V3}"   # GENERIC_V3 | NATIVE
: "${_use_llvm_lto:=thin}"          # thin | full | none
: "${_localmodcfg:=yes}"            # yes trims to localmod.db (~260 modules) for 7.4 GiB RAM / disk safety
: "${_enable_rust:=no}"             # yes pulls rust/rust-bindgen/rust-src
: "${_jobs:=2}"                     # Safe parallelism for 7.4 GiB RAM + ThinLTO

pkgbase=linux-jarvisos
pkgname=("$pkgbase" "$pkgbase-headers")
# Product versions are independent of the upstream Linux ABI. The epoch makes
# 1.0 an upgrade from packages previously numbered after the upstream kernel.
epoch=1
pkgver=1.0
pkgrel=1
_srcname=cachyos-7.3.6-1
pkgdesc='JARVIS OS Kernel 1.0 — CachyOS Linux 7.3.6 with JARVIS policy drivers'
arch=('x86_64')
url='https://github.com/Jarvis-os-tech/jarvis-kernel'
license=('GPL-2.0-only')
options=('!strip' '!debug' '!lto')

makedepends=(
  bc
  binutils
  cpio
  gettext
  glibc
  libelf
  libgcc
  openssl
  'pahole>=1:1.32-2'
  perl
  python
  tar
  xxhash
  xz
  zstd
  clang
  llvm
  lld
)

if [ "$_enable_rust" = "yes" ]; then
  makedepends+=(rust rust-bindgen rust-src)
fi

source=(
  "https://github.com/CachyOS/linux/releases/download/${_srcname}/${_srcname}.tar.gz"
  "config"
  "jarvisos.fragment.config"
  "0001-bore-cachy.patch"
  "0002-jarvis-drivers.patch"
  "99-jarvis-dev.rules"
  "localmod.db"
)

b2sums=(
  '67e2a98ad5df5469afae493c34a3f2155932abb94b16c016a8782790bf3a305f91c03b126555294bd4f88d74952bb997f4839b5769980dafbcad08d0579ac7ea'
  'e6fc382da6b317f14b0ffe1e22e120ea8c9efa03a95ee58360765629b7b81f89e98f04349134232215ae0ff8aa10c2200a7551a3c3aeb1e5d1fb1e4c5673f0e9'
  '260692018ce4fd87d68450ad32aee28213251d0d6664a74284a017a25c52d2c5101a68d5a0b432844bf78baec0fe45537ffd7f10f1b32b055d7f5eb3cacd9d90'
  '355a279dea4edf0148cc6499b770bb6d07c55623ea334e6b0db52eba746454d5afafe58bbcf357c9bc53aaa1319a610cd167dba77f6c866835077aed85a2d45c'
  'eab97ba92264bdc3f68df0eac055de61adf8aa70ae39db1eca8e26e3b63d1d62fd36d51d93fa73159b695d3dfc8a9e9afb759f5130c0a51061d0ac4b6205ad88'
  '122c915e1fefbb86cf4bb0f08ae641ffc4e6ee3cbc9e2792eab6b632236ed3485232a3ec276c12182f9b6b8c9f9534042844feb268fc624f1f4f8b9628a401ad'
  '27c469cd6beb396aa62cf29b0d1633d5eee7ad36932b682f0c558e4b3e68568389722f48fe8ecbd89dc5161e0a8ce8517932e1d6628fc6e1e3664898d1229f6f'
)

BUILD_FLAGS=(
  CC=clang
  LD=ld.lld
  LLVM=1
  LLVM_IAS=1
)

export KBUILD_BUILD_HOST=jarvis-os
export KBUILD_BUILD_USER="$pkgbase"
export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

_die() { error "$@"; exit 1; }

prepare() {
  cd "$srcdir/$_srcname"

  echo "-$pkgrel" > localversion.10-pkgrel
  echo "${pkgbase#linux}${pkgver}" > localversion.20-pkgname

  local p
  for p in 0001-bore-cachy.patch 0002-jarvis-drivers.patch; do
    echo "Applying $p..."
    patch -Np1 < "$srcdir/$p"
  done

  cp "$srcdir/config" .config

  local march="${_processor_opt^^}"
  case "$march" in
    GENERIC_V[1-4])
      scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU \
        --set-val X86_64_VERSION "${march#GENERIC_V}"
      ;;
    NATIVE)
      scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU
      ;;
    *)
      _die "Unsupported _processor_opt: $_processor_opt"
      ;;
  esac

  case "$_use_llvm_lto" in
    thin) scripts/config -e LTO_CLANG_THIN -d LTO_NONE -d LTO_CLANG_FULL ;;
    full) scripts/config -e LTO_CLANG_FULL -d LTO_NONE -d LTO_CLANG_THIN ;;
    none) scripts/config -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL ;;
    *) _die "Unsupported _use_llvm_lto: $_use_llvm_lto" ;;
  esac

  if [ "$_enable_rust" != "yes" ]; then
    scripts/config -d RUST
  else
    scripts/config -e RUST
  fi

  if [ "$_localmodcfg" = "yes" ]; then
    yes "" | make "${BUILD_FLAGS[@]}" LSMOD="$srcdir/localmod.db" localmodconfig
  fi

  echo "Merging jarvisos.fragment.config..."
  ./scripts/kconfig/merge_config.sh -m .config "$srcdir/jarvisos.fragment.config"

  if [ "$_enable_rust" = "yes" ]; then
    scripts/config -e RUST
  fi

  make "${BUILD_FLAGS[@]}" olddefconfig
  make "${BUILD_FLAGS[@]}" prepare
  make -s kernelrelease > version
  echo "Prepared $pkgbase kernelrelease: $(<version)"
}

build() {
  cd "$srcdir/$_srcname"
  make "${BUILD_FLAGS[@]}" -j"$_jobs" all
}

package_linux-jarvisos() {
  pkgdesc="The $pkgdesc kernel and modules"
  depends=('coreutils' 'kmod' 'initramfs')
  optdepends=(
    'wireless-regdb: wireless regulatory channels'
    'linux-firmware-realtek: RTL8822CE Wi-Fi/BT firmware'
    'sof-firmware: Intel Alder Lake SOF audio firmware'
    'scx-scheds: sched_ext userspace schedulers'
  )
  provides=(ADIOS-MODULE KSMBD-MODULE NTSYNC-MODULE WIREGUARD-MODULE)

  cd "$srcdir/$_srcname"
  local modulesdir="$pkgdir/usr/lib/modules/$(<version)"

  install -Dm644 "$(make -s image_name)" "$modulesdir/vmlinuz"
  echo "$pkgbase" | install -Dm644 /dev/stdin "$modulesdir/pkgbase"

  ZSTD_CLEVEL=19 make "${BUILD_FLAGS[@]}" \
    INSTALL_MOD_PATH="$pkgdir/usr" \
    INSTALL_MOD_STRIP=1 \
    DEPMOD=/doesnt/exist \
    modules_install

  rm -f "$modulesdir/build"
  install -Dm644 "$srcdir/99-jarvis-dev.rules" "$pkgdir/usr/lib/udev/rules.d/99-jarvis-dev.rules"
}

package_linux-jarvisos-headers() {
  pkgdesc="Headers and scripts for building modules for $pkgbase"
  depends=('binutils' 'glibc' 'libelf' 'openssl' 'pahole>=1:1.32-2' 'zlib' 'zstd' 'clang' 'llvm' 'lld' "$pkgbase=$epoch:$pkgver-$pkgrel")
  provides=('LINUX-HEADERS')

  cd "$srcdir/$_srcname"
  local builddir="$pkgdir/usr/lib/modules/$(<version)/build"

  install -Dt "$builddir" -m644 .config Makefile Module.symvers System.map \
    localversion.* version vmlinux

  install -Dt "$builddir/kernel" -m644 kernel/Makefile
  install -Dt "$builddir/arch/x86" -m644 arch/x86/Makefile
  cp -t "$builddir" -a scripts

  install -Dt "$builddir/tools/objtool" tools/objtool/objtool
  if [ -f tools/bpf/resolve_btfids/resolve_btfids ]; then
    install -Dt "$builddir/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids
  fi

  cp -t "$builddir" -a include
  cp -t "$builddir/arch/x86" -a arch/x86/include
  install -Dt "$builddir/arch/x86/kernel" -m644 arch/x86/kernel/asm-offsets.s

  find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;
  make INSTALL_MOD_PATH="$pkgdir/usr" vdso_install link=

  local arch
  for arch in "$builddir"/arch/*/; do
    [[ $arch = */x86/ ]] && continue
    rm -r "$arch"
  done
  rm -rf "$builddir/Documentation"
  find -L "$builddir" -type l -delete
  find "$builddir" -type f -name '*.o' -delete

  mkdir -p "$pkgdir/usr/src"
  ln -sr "$builddir" "$pkgdir/usr/src/$pkgbase"
}
