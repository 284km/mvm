#!/bin/sh
# test/all.sh — every gate, in one command, with one answer at the end.
#
# WHY THIS EXISTS. "Everything is green" was a thing said after running six
# scripts by hand and reading six last lines. That is a claim nobody else can
# check and that nobody, including the person who said it, can repeat exactly.
#
# WHAT IT DOES NOT DO is hide which one failed. Each gate keeps its own output
# in .build/all-<name>.log, and the summary names every one that went red --
# a runner that prints "FAILED" and nothing else has taken away the only thing
# worth having.
#
# ORDER IS CHEAPEST FIRST. The ones that need no virtual machine come before
# the ones that boot several, so a mistake in the build shows up in seconds
# rather than after twenty minutes of booting.
#
#   MERE=<mere> MENGD_SRC=<mengd> MRUN_SRC=<mrun> MREG_SRC=<mreg> sh test/all.sh
#
# Options, because the whole suite is about half an hour:
#   QUICK=1        only the gates that do not boot a machine
#   ONLY="a b"     only these
#   KERNEL_SOURCE=1  build a kernel from source inside test/build.sh (+5 min)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"; mkdir -p "$out"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac

# THE GATES, and what each one is for. The list is here rather than globbed
# from the directory: a file that appears in test/ is not automatically a gate,
# and one that disappears should make this fail rather than quietly shrink.
QUICK_GATES="run boot init vsock disk"
VM_GATES="build stack two hub lifecycle app outward vcpus scale bigdisk"
gates="${ONLY:-}"
if [ -z "$gates" ]; then
  if [ "${QUICK:-0}" = 1 ]; then gates="$QUICK_GATES"; else gates="$QUICK_GATES $VM_GATES"; fi
fi

for g in $gates; do
  [ -r "$here/test/$g.sh" ] || { echo "all: there is no test/$g.sh" >&2; exit 2; }
done

start=$(date +%s)
red=""; green=""; skipped=""
for g in $gates; do
  printf "== %-10s " "$g"
  t0=$(date +%s)
  if DOCKER_CONTEXT= sh "$here/test/$g.sh" > "$out/all-$g.log" 2>&1; then
    green="$green $g"; printf "PASS"
  else
    # A gate that could not run is not a gate that failed, and calling it
    # either is a lie in one direction or the other. Both are named.
    if grep -q "^needs \|^set MERE\|^set MENGD_SRC\|^set MREG_SRC" "$out/all-$g.log"; then
      skipped="$skipped $g"; printf "SKIP"
    else
      red="$red $g"; printf "FAIL"
    fi
  fi
  printf "  %ss  (%s)\n" "$(( $(date +%s) - t0 ))" "$(grep -c '^  ok' "$out/all-$g.log" 2>/dev/null) checks, .build/all-$g.log"
done

echo
echo "== $(( $(date +%s) - start ))s =="
[ -n "$green" ] && echo "  PASS:$green"
[ -n "$skipped" ] && echo "  SKIP:$skipped  (these did not run -- read their logs before calling this green)"
if [ -n "$red" ]; then
  echo "  FAIL:$red"
  for g in $red; do
    echo "  -- $g --"
    grep "  FAIL" "$out/all-$g.log" | head -5 | sed 's/^/     /'
  done
  exit 1
fi
echo "all PASS"
