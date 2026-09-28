#!/bin/bash
# Self-test for pkgbuilds/linux-firmware/firmware-parity: the check that lets a
# linux-firmware update merge unattended only when every split matches Arch's
# build of the same release. Offline: the Arch side is a fixture tree.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PARITY="$ROOT/pkgbuilds/linux-firmware/firmware-parity"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# A two-split firmware tree: a compressed blob, a raw file, a symlink to a
# file, a symlink to a directory, and a dangling link.
make_tree() {
  local root="$1" level="$2"
  mkdir -p "$root/other/usr/lib/firmware/vendor" "$root/cirrus/usr/lib/firmware/cirrus/sub"
  printf 'blob' | zstd -q "-$level" -o "$root/other/usr/lib/firmware/vendor/blob.bin.zst"
  printf 'raw' > "$root/other/usr/lib/firmware/raw.bin"
  printf 'amp' | zstd -q "-$level" -o "$root/cirrus/usr/lib/firmware/cirrus/amp.wmfw.zst"
  ln -s amp.wmfw.zst "$root/cirrus/usr/lib/firmware/cirrus/alias.wmfw.zst"
  ln -s sub "$root/cirrus/usr/lib/firmware/cirrus/sub-link"
  ln -s nowhere.bin "$root/other/usr/lib/firmware/dangling.bin"
}

check() {
  python "$PARITY" --reference "$T/arch" "$T/ours" other cirrus >"$T/out" 2>&1
}

reset() {
  rm -rf "$T/ours" "$T/arch"
  make_tree "$T/ours" 19
  make_tree "$T/arch" 19
}

reset
check && pass "identical trees match" || fail "identical trees: $(cat "$T/out")"

rm -rf "$T/ours"; make_tree "$T/ours" 3
check && pass "a different zstd level with the same content matches" || fail "compression level: $(cat "$T/out")"

reset
rm "$T/ours/cirrus/usr/lib/firmware/cirrus/alias.wmfw.zst"
cp "$T/ours/cirrus/usr/lib/firmware/cirrus/amp.wmfw.zst" "$T/ours/cirrus/usr/lib/firmware/cirrus/alias.wmfw.zst"
check && pass "a deduplicated link and a regular copy of the same content match" || fail "dedup: $(cat "$T/out")"

reset
mv "$T/ours/other/usr/lib/firmware/raw.bin" "$T/ours/cirrus/usr/lib/firmware/raw.bin"
if check; then fail "a file in the wrong split should not match"; fi
grep -q "moved: raw.bin is in cirrus, Arch ships it in other" "$T/out" && pass "a file in the wrong split is reported" || fail "moved: $(cat "$T/out")"

reset
printf 'reverted' | zstd -q -19 -f -o "$T/arch/cirrus/usr/lib/firmware/cirrus/amp.wmfw.zst"
if check; then fail "different content should not match"; fi
grep -q "differs: cirrus/amp.wmfw.zst" "$T/out" && grep -q "differs: cirrus/alias.wmfw.zst" "$T/out" \
  && pass "different content is reported, through links too" || fail "differs: $(cat "$T/out")"

reset
rm "$T/ours/other/usr/lib/firmware/raw.bin"
if check; then fail "a missing file should not match"; fi
grep -q "missing: raw.bin" "$T/out" && pass "a missing file is reported" || fail "missing: $(cat "$T/out")"

reset
printf 'new' > "$T/ours/other/usr/lib/firmware/new.bin"
if check; then fail "an extra file should not match"; fi
grep -q "extra: new.bin" "$T/out" && pass "an extra file is reported" || fail "extra: $(cat "$T/out")"

reset
ln -sfn other-sub "$T/ours/cirrus/usr/lib/firmware/cirrus/sub-link"
if check; then fail "a retargeted directory link should not match"; fi
grep -q "differs: cirrus/sub-link" "$T/out" && pass "a retargeted directory link is reported" || fail "dir link: $(cat "$T/out")"

reset
cp -a "$T/ours/other/usr/lib/firmware/raw.bin" "$T/ours/cirrus/usr/lib/firmware/raw.bin"
if check; then fail "a path in two splits should not match"; fi
grep -q "raw.bin is in both" "$T/out" && pass "a path owned by two splits is refused" || fail "two owners: $(cat "$T/out")"

# Arch's packages carry pacman metadata at the top level and firmware dotfiles
# (ath11k's .notice.zst) further down; only the metadata may be left out.
mkdir -p "$T/pkg/usr/lib/firmware/ath11k"
printf 'notice' > "$T/pkg/usr/lib/firmware/ath11k/.notice"
printf 'pkginfo' > "$T/pkg/.PKGINFO"
(cd "$T/pkg" && bsdtar --zstd -cf "$T/fake.pkg.tar.zst" .PKGINFO usr)
PYTHONDONTWRITEBYTECODE=1 python - "$PARITY" "$T/fake.pkg.tar.zst" "$T/extracted" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
parity = SourceFileLoader("parity", sys.argv[1]).load_module()
parity.extract(Path(sys.argv[2]), Path(sys.argv[3]))
PY
[[ -f "$T/extracted/usr/lib/firmware/ath11k/.notice" && ! -e "$T/extracted/.PKGINFO" ]] \
  && pass "extraction keeps nested dotfiles and drops package metadata" || fail "extraction: $(find "$T/extracted" | tr '\n' ' ')"
