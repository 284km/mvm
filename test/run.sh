#!/bin/sh
# test/run.sh — P5.1: a Mere program drives Hypervisor.framework and the guest
# executes an instruction.
#
# The value the guest loads comes from the command line, so "the guest ran" is
# a claim about that number rather than about a register that happened to hold
# something. Three different values, and a poison that writes no instruction at
# all -- because a check that only ever asks for 42 would pass against a
# hypervisor that always answered 42.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "this needs macOS on Apple silicon" >&2; exit 2;; esac
out="$here/.build"; mkdir -p "$out"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build and sign =="
"$M" -c "$here/mvm.mere" > "$out/mvm.c" 2> "$out/e" || { echo "FAIL: emit"; sed -n 1,10p "$out/e"; exit 1; }
[ -s "$out/mvm.c" ] || { echo "FAIL: emitted C is empty"; exit 1; }
cc -O2 -o "$out/mvm" "$out/mvm.c" "$here/hv_shim.c" -framework Hypervisor 2> "$out/cc" \
  || { echo "FAIL: cc"; sed -n 1,10p "$out/cc"; exit 1; }
# Ad-hoc signing is enough for the hypervisor entitlement on this machine; no
# developer account and no notarisation are involved.
codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm" 2>/dev/null
codesign -d --entitlements - "$out/mvm" 2>&1 | grep -q "com.apple.security.hypervisor"
say $? "the binary carries com.apple.security.hypervisor"

echo "== the guest runs =="
for n in 42 1234 65535; do
  o=$("$out/mvm" "$n" 2>&1)
  got=$(echo "$o" | sed -n 's/^mvm\.x0=//p')
  want=$(echo "$o" | sed -n 's/^mvm\.want=//p')
  [ -n "$want" ] && [ "$got" = "$want" ]; say $? "it loaded the value it was given ($n -> $got)"
done
o=$("$out/mvm" 42 2>&1)
echo "$o" | grep -q "^mvm.exit_ec=22$"; say $? "the exit is EC 0x16, an HVC from the guest"
echo "$o" | grep -q "^mvm.pc=0x40000008$"; say $? "the pc advanced past both instructions"

echo "== poison: write no instruction =="
sed 's|let _ = must "poke" (hv_poke32 "0x40000000" (movz_x0 want)) in|let _ = 0 in|' \
  "$here/mvm.mere" > "$out/poison.mere"
grep -q 'hv_poke32 "0x40000000"' "$out/poison.mere" && { echo "  FAIL  the poison did not remove the write"; fail=1; }
"$M" -c "$out/poison.mere" > "$out/poison.c" 2>/dev/null \
  && cc -O2 -o "$out/mvm-poison" "$out/poison.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null \
  && codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-poison" 2>/dev/null
p=$("$out/mvm-poison" 42 2>&1)
echo "$p" | grep -q "guest-ran=yes" && { echo "  FAIL  it still claims the guest ran"; fail=1; } \
  || echo "  ok    with nothing to execute it does not claim the guest ran"

[ "$fail" = 0 ] && echo "mvm PASS" || echo "mvm FAIL"
exit "$fail"
