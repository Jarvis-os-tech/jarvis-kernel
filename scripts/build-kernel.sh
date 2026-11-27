#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export _jobs="${_jobs:-1}"
export _processor_opt="${_processor_opt:-GENERIC_V3}"
export _use_llvm_lto="${_use_llvm_lto:-thin}"
export _localmodcfg="${_localmodcfg:-yes}"
export _enable_rust="${_enable_rust:-no}"
export CPU_QUOTA="${CPU_QUOTA:-60%}"
export PKGDEST="$ROOT/out"

mkdir -p "$PKGDEST"

missing=()
for cmd in clang ld.lld llvm-strip pahole bison flex cpio makepkg bc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: Missing required kernel build tool(s): ${missing[*]}" >&2
  echo "Install on Arch/Omarchy with:" >&2
  echo "  sudo pacman -S --needed ${missing[*]}" >&2
  exit 1
fi

avail_gb=$(df -BG --output=avail "$ROOT" | tail -n 1 | tr -dc '0-9')
if (( avail_gb < 18 )); then
  echo "WARNING: Only ${avail_gb}G free on $ROOT; full ThinLTO kernel build typically needs 18-25G." >&2
fi

echo "Building linux-jarvisos (jobs=$_jobs opt=$_processor_opt lto=$_use_llvm_lto rust=$_enable_rust quota=$CPU_QUOTA)..."
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope -p "CPUQuota=$CPU_QUOTA" true >/dev/null 2>&1; then
  exec systemd-run --user --scope -p "CPUQuota=$CPU_QUOTA" nice -n 15 makepkg "$@"
else
  exec nice -n 15 makepkg "$@"
fi
