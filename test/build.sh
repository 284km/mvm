#!/bin/sh
# test/build.sh — the thing a person downloads, and whether it can be made.
#
# WHAT THIS IS FOR. Every other check here starts from a .build directory that
# somebody already filled. This one asks whether it can be FILLED, and then
# whether what came out is enough to start a machine on a system that has none
# of the things this repository assumes.
#
# THE CHECK THAT MATTERS is the last one: a machine starts with docker taken
# off the PATH. The disk used to be built by `docker create` and a container
# running mke2fs, which made this a tool that needed docker to install --
# a tool that replaces docker. The guest formats its own disk now, and the only
# way to know that is still true is to take docker away and try.
#
#   MERE=<mere> MENGD_SRC=<mengd> MRUN_SRC=<mrun> sh test/build.sh
#
# The kernel step fetches about 105 MB. Without a network it is SKIPPED BY
# NAME: a check that cannot run is not a check that passed.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
[ -n "${MERE:-}" ] || { echo "set MERE=<a merelang/mere checkout>" >&2; exit 2; }
[ -n "${MENGD_SRC:-}" ] && [ -n "${MRUN_SRC:-}" ] || { echo "set MENGD_SRC and MRUN_SRC" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "needs docker to BUILD (not to run)" >&2; exit 2; }
out="$here/.build"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
M="out$$"
export MVM_HOME="${MVM_HOME:-$HOME/.mvm}"
D="$MVM_HOME/$M"
cleanup() { sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1; rm -rf "$D"
            docker context rm "mvm-$M" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== the kernel, out of a pinned package =="
if curl -s -m 8 -o /dev/null http://ports.ubuntu.com/ 2>/dev/null; then
  sh "$here/tools/mvm" build --kernel > "$out/build-kernel.log" 2>&1
  say $? "mvm build --kernel"
  # THE PIN, CHECKED AGAINST ITSELF. kernel.lock records the digest of what was
  # extracted; the Image on disk has to be that. This is an external oracle --
  # the bytes come from somebody else's archive -- and it is the strongest
  # check here: it says the kernel is the one every other check was green
  # against, not merely that a kernel appeared.
  want=$(awk '/Image$/{print $1}' "$out/kernel.lock" 2>/dev/null)
  got=$(shasum -a 256 "$out/Image" 2>/dev/null | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ]
  say $? "the Image is the one kernel.lock names ($(echo "$got" | cut -c1-12))"
  n=0
  for m in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport overlay veth bridge stp llc; do
    # Decompressed, not merely present: they ship as .ko.zst, and a version of
    # the extractor once reported all eight "ok" and could not open one.
    head -c 4 "$out/extra/$m.ko" 2>/dev/null | grep -q "ELF" && n=$((n + 1))
  done
  [ "$n" = 8 ]; say $? "eight modules, each a real ELF object ($n)"
else
  echo "  SKIP  no route to ports.ubuntu.com -- the kernel step needs one"
fi

echo "== everything else =="
sh "$here/tools/mvm" build > "$out/build-all.log" 2>&1
say $? "mvm build"
n=0
for b in mvm-boot mkdtb mports mproxy guest/mengd guest/mrun guest/mfwd; do
  [ -x "$out/$b" ] && n=$((n + 1))
done
[ "$n" = 7 ]; say $? "seven programs ($n)"
# Hypervisor.framework refuses a VMM without the entitlement, hours after the
# build that made it.
#
# "IS IT SIGNED" IS NOT THE CHECK. Removing the codesign step and the signature
# and rebuilding leaves this line GREEN: the linker on arm64 macOS ad-hoc signs
# everything it produces, so there is no such thing as an unsigned binary here.
# The entitlement is the half that can be missing, and the line below is the
# one that went red. Both are kept because the pair is the explanation.
codesign -dv "$out/mvm-boot" 2>&1 | grep -q "Signature=adhoc"
say $? "the VMM is signed (which arm64 macOS does by itself -- see below)"
codesign -d --entitlements - "$out/mvm-boot" 2>&1 | grep -q "com.apple.security.hypervisor"
say $? "and carries the entitlement the framework asks for -- THIS is the one that can fail"
[ -r "$out/initrd-format.gz" ] && [ "$(wc -c < "$out/initrd-format.gz" | tr -d ' ')" -gt 2000000 ]
say $? "an initramfs that can make a disk ($(wc -c < "$out/initrd-format.gz" 2>/dev/null | tr -d ' ') bytes)"
sh "$here/tools/mvm" doctor >/dev/null 2>&1; say $? "doctor finds nothing missing"

echo "== a machine, on a system with no docker =="
# PATH without docker, and without the variables that point at checkouts: this
# is what a person who downloaded a release has.
env PATH=/usr/bin:/bin:/usr/sbin:/sbin MVM_HOME="$MVM_HOME" \
    sh "$here/tools/mvm" start --name "$M" --disk-size 2048 > "$out/build-start.log" 2>&1
say $? "mvm start, with docker taken off the PATH"
grep -q "mke2fs ok" "$out/build-start.log"; say $? "the GUEST made its own filesystem"
grep -q "installed:" "$out/build-start.log"; say $? "and installed the daemon into it"
grep -q "is up" "$out/build-start.log"; say $? "the machine is up"

export DOCKER_HOST="unix://$D/docker.sock"
export DOCKER_CONTEXT=
DOCKER_HOST= docker save alpine:latest -o "$out/build-alpine.tar" 2>/dev/null
docker load -i "$out/build-alpine.tar" >/dev/null 2>&1; say $? "an image loads into it"
o=$(docker run --rm alpine:latest echo made-without-docker 2>/dev/null | tr -d '\r\n')
[ "$o" = "made-without-docker" ]; say $? "and a container runs on the disk the guest made ($o)"

echo "== starting it again costs nothing =="
# The initramfs is built from a pipe, so gzip stores no timestamp and the same
# inputs give the same bytes. That is what makes 'has this tool changed' a
# comparison rather than a guess -- and it means an ordinary restart must NOT
# do a format boot. Rebuilding it here first, to prove the answer comes from
# the CONTENT and not from the file being new.
sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
before=$(shasum -a 256 "$out/initrd-format.gz" | cut -d' ' -f1)
sh "$here/tools/mkinitrd.sh" >/dev/null 2>&1
[ "$before" = "$(shasum -a 256 "$out/initrd-format.gz" | cut -d' ' -f1)" ]
say $? "the initramfs is built byte for byte the same from the same inputs"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin MVM_HOME="$MVM_HOME" \
    sh "$here/tools/mvm" start --name "$M" > "$out/build-again.log" 2>&1
grep -q "format:" "$out/build-again.log"; [ $? != 0 ]
say $? "so an ordinary restart does not boot the formatter"
grep -q "is up" "$out/build-again.log"; say $? "and it comes up"

echo "== but a tool that HAS changed installs itself =="
# Upgrading used to mean deleting the machine: the payload went in only when
# the disk was created. What decides is the recorded id, so this is the
# condition itself -- a machine made by a different build of this tool.
sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
echo "made-by-an-older-build" > "$D/initrd.id"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin MVM_HOME="$MVM_HOME" \
    sh "$here/tools/mvm" start --name "$M" > "$out/build-refresh.log" 2>&1
grep -q "refresh mode" "$out/build-refresh.log"; say $? "it installs the new guest programs"
grep -q "there is already an ext4 here" "$out/build-refresh.log"
say $? "without making the filesystem again"
grep -q "is up" "$out/build-refresh.log"; say $? "and it comes up"
[ "$(cat "$D/initrd.id")" = "$(shasum -a 256 "$out/initrd-format.gz" | cut -d' ' -f1)" ]
say $? "and records what it installed, so the next start does not repeat it"

[ "$fail" = 0 ] && echo "build PASS" || echo "build FAIL"
exit "$fail"
