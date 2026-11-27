#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "1. Checking shell syntax (PKGBUILD and scripts/*.sh)..."
bash -n PKGBUILD scripts/*.sh

echo "2. Verifying PKGBUILD BLAKE2b checksums for local sources..."
python3 - <<'PY'
import hashlib, re
from pathlib import Path

text = Path("PKGBUILD").read_text(encoding="utf-8")
m_src = re.search(r"source=\((.*?)\)", text, re.S)
m_sum = re.search(r"b2sums=\((.*?)\)", text, re.S)
assert m_src and m_sum, "Could not parse source=() and b2sums=() in PKGBUILD"

sources = re.findall(r'"([^"]+)"', m_src.group(1))
sums = re.findall(r"'([0-9a-f]+)'", m_sum.group(1))
assert len(sources) == len(sums), f"Mismatch: {len(sources)} sources vs {len(sums)} b2sums"

for src, expected in zip(sources, sums):
    if src.startswith(("http://", "https://")):
        continue
    actual = hashlib.blake2b(Path(src).read_bytes(), digest_size=64).hexdigest()
    assert actual == expected, f"b2sum mismatch for {src}: {actual} != {expected}"
    print(f"  OK {src}")
PY

echo "3. Checking patches parse cleanly..."
git apply --numstat patches/0001-bore-cachy.patch >/dev/null
git apply --numstat patches/0002-jarvis-drivers.patch >/dev/null

echo "4. Verifying drivers/jarvis/ and include/ match patches/0002-jarvis-drivers.patch..."
python3 - <<'PY'
import re
from pathlib import Path

text = Path("patches/0002-jarvis-drivers.patch").read_text(encoding="utf-8")
checked = 0
for blk in text.split("diff --git ")[1:]:
    m = re.match(r"a/(\S+) b/(\S+)\n", blk)
    assert m, "Malformed patch block"
    fn = m.group(2)
    if not (fn.startswith("drivers/jarvis/") or fn in ("include/linux/jarvis.h", "include/uapi/linux/jarvis.h")):
        continue
    idx = blk.find("@@")
    assert idx >= 0
    lines = [line[1:] for line in blk[idx:].splitlines()[1:] if line.startswith(("+", " "))]
    expected = "\n".join(lines) + "\n"
    actual = Path(fn).read_text(encoding="utf-8")
    assert actual == expected, f"Drift detected between patches/0002-jarvis-drivers.patch and {fn}"
    checked += 1
assert checked == 13, f"Expected 13 synced driver/header files, checked {checked}"
print(f"  OK {checked} files match patches/0002-jarvis-drivers.patch")
PY

echo "5. Verifying tests/uapi_jarvis.h matches include/uapi/linux/jarvis.h..."
cmp -s tests/uapi_jarvis.h include/uapi/linux/jarvis.h

echo "6. Compiling userspace C tests (-Wall -Wextra -Werror)..."
CC_BIN="${CC:-}"
if [[ -z "$CC_BIN" ]]; then
  if command -v clang >/dev/null 2>&1; then
    CC_BIN=clang
  else
    CC_BIN=gcc
  fi
fi
TMP_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN_DIR"' EXIT
"$CC_BIN" -O2 -Wall -Wextra -Werror -pthread tests/jarvis_kvm_init.c -o "$TMP_BIN_DIR/jarvis_kvm_init"
"$CC_BIN" -O2 -Wall -Wextra -Werror tests/jarvis_userspace_check.c -o "$TMP_BIN_DIR/jarvis_userspace_check"

echo "=== JARVIS_KERNEL_REPO_VERIFY_PASS ==="
