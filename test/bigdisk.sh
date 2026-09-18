#!/bin/sh
# test/bigdisk.sh -- the default disk size, and the 4 GiB line inside it.
#
# Every other gate here starts its machine with --disk-size 1024, 2048 or
# 4096, so until this one existed nothing had ever taken the branch a person
# gets by typing `mvm start`: 20480 MiB. That mattered, because virtio-blk
# handed its byte offset to the shim through a declaration that said C `int`
# while the definition said `long long`. Mere's int is 64 bits, both sides
# compiled clean, and the CALLER truncated the argument -- so every access at
# or past 2^32 wrapped to the bottom of the file. mke2fs reported success and
# then the block bitmaps of groups 32, 49, 64, 96 and 128 came back as
# whatever had been written over them.
#
# Three questions, because "it booted" is the weakest of them:
#   1. do the declarations and the definitions agree at all,
#   2. does a machine at the DEFAULT size format and come up, having really
#      crossed the line rather than passing because the disk was small,
#   3. does data written above it survive being read back by a new machine.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
out="$here/.build"; mkdir -p "$out"
G="bigdisk-gate"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
cleanup() {
  sh "$here/tools/mvm" stop --name "$G" >/dev/null 2>&1
  rm -rf "$HOME/.mvm/$G"
  docker context rm -f "mvm-$G" >/dev/null 2>&1
}
trap 'cleanup' EXIT INT TERM
cleanup

echo "== the declaration and the definition agree =="
"$M" -c "$here/boot.mere" > "$out/boot.c" 2>"$out/bd-e" \
  || { echo "  FAIL  boot.mere does not compile"; sed -n 1,8p "$out/bd-e"; exit 1; }
# --mere asks the second question: one shim function is declared separately in
# every Mere file that calls it, and those declarations rot one at a time.
python3 "$here/tools/abicheck.py" "$out/boot.c" "$here/hv_shim.c" \
  --mere "$here"/*.mere > "$out/bd-abi.txt" 2>&1
say $? "the declarations agree, with each other and with the C"
sed -n 's/^/        /p' "$out/bd-abi.txt" | grep -v "^ *$" | tail -2

echo "== a machine at the size a person gets by typing \`mvm start' =="
MVM_BLK_TRACE=1 sh "$here/tools/mvm" start --name "$G" > "$out/bd-start.log" 2>&1
say $? "mvm start, with no --disk-size"
mb=$(sed -n 's/.*making a \([0-9][0-9]*\) MiB disk.*/\1/p' "$out/bd-start.log" | head -1)
[ "${mb:-0}" -gt 4096 ] 2>/dev/null
say $? "and the size it chose is past the 32-bit line (${mb:-?} MiB)"
e=$(grep -c "EXT4-fs error" "$HOME/.mvm/$G/format.log" 2>/dev/null | tr -d ' ')
[ "${e:-1}" = 0 ]
say $? "it formatted without an ext4 error ($e)"
# Without this the gate would pass on a 1 GiB disk, having asked nothing.
past=$(awk '/^BLK/{split($2,a,"="); if (a[2]+0 >= 4294967296) c++} END{print c+0}' \
       "$HOME/.mvm/$G/format.log" 2>/dev/null)
[ "${past:-0}" -gt 0 ] 2>/dev/null
say $? "and the accesses really went past 4 GiB ($past of $(grep -c '^BLK' "$HOME/.mvm/$G/format.log" 2>/dev/null | tr -d ' '))"
sh "$here/tools/mvm" status --name "$G" >/dev/null 2>&1
say $? "it is up"

echo "== data on the far side of the line, read by a second machine =="
D="docker --context mvm-$G"
$D load -i "$out/alpine.tar" >/dev/null 2>&1
$D run --rm -v bd:/d alpine sh -c '
  dd if=/dev/urandom of=/d/a bs=1M count=8 2>/dev/null
  fallocate -l 5G /d/gap
  dd if=/dev/urandom of=/d/b bs=1M count=8 2>/dev/null
  sync; md5sum /d/a /d/b' > "$out/bd-before.txt" 2>&1
say $? "wrote a file, reserved 5 GiB, wrote another after it"
sh "$here/tools/mvm" stop  --name "$G" >/dev/null 2>&1
sh "$here/tools/mvm" start --name "$G" >/dev/null 2>&1
say $? "the machine stopped and started again"
$D run --rm -v bd:/d alpine sh -c 'md5sum /d/a /d/b' > "$out/bd-after.txt" 2>&1
cmp -s "$out/bd-before.txt" "$out/bd-after.txt"
say $? "and both files came back byte for byte"
[ -s "$out/bd-before.txt" ] && grep -qc . "$out/bd-before.txt"
say $? "(the comparison had something to compare: $(wc -l < "$out/bd-before.txt" | tr -d ' ') lines)"
sh "$here/tools/mvm" stop --name "$G" >/dev/null 2>&1

echo "== poison: put the offset back through 32 bits =="
sed 's/uint64_t off = hex64(off_hex);/uint64_t off = (uint32_t)hex64(off_hex);/' \
  "$here/hv_shim.c" > "$out/bd-poison.c"
n=$(grep -c "(uint32_t)hex64(off_hex)" "$out/bd-poison.c")
[ "$n" = 2 ]
say $? "the poison truncated both offsets ($n of 2)"
cc -O2 -o "$out/mvm-boot-poison" "$out/boot.c" "$out/bd-poison.c" -framework Hypervisor 2>/dev/null \
  && codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-boot-poison" 2>/dev/null
say $? "it builds (both sides still compile clean -- that is the whole problem)"
rm -rf "$HOME/.mvm/$G"
MVM_BOOT="$out/mvm-boot-poison" sh "$here/tools/mvm" start --name "$G" > "$out/bd-pois.log" 2>&1
pe=$(grep -c "EXT4-fs error" "$HOME/.mvm/$G/format.log" 2>/dev/null | tr -d ' ')
[ "${pe:-0}" -gt 0 ]
say $? "and a machine built with it corrupts its own filesystem ($pe ext4 errors)"

[ "$fail" = 0 ] && echo "bigdisk PASS" || echo "bigdisk FAIL"
exit $fail
