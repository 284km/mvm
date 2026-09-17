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

echo "== or one built here =="
# OPT-IN, because it is five minutes. What it buys is that there are no modules
# at all -- kernel/config.fragment is nine lines on top of arm64 defconfig --
# and the thing to check is that the capabilities are there without any file to
# load. The guest is asked, because the guest is what has to have them.
if [ "${KERNEL_SOURCE:-0}" = 1 ]; then
  sh "$here/tools/mvm" build --kernel --from-source > "$out/build-ksrc.log" 2>&1
  say $? "mvm build --kernel --from-source"
  [ "$(awk '/^modules /{print $2}' "$out/kernel.lock")" = built-in ]
  say $? "it records that the modules are built in"
  [ "$(ls "$out"/extra/*.ko 2>/dev/null | wc -l | tr -d ' ')" = 0 ]
  say $? "and there are no modules left to ship"
  sh "$here/tools/mkinitrd.sh" > "$out/build-ksrc-initrd.log" 2>&1
  grep -q "no modules to carry" "$out/build-ksrc-initrd.log"
  say $? "the initramfs carries none either"
  K="ks$$"
  env PATH=/usr/bin:/bin:/usr/sbin:/sbin MVM_HOME="$MVM_HOME" \
      sh "$here/tools/mvm" start --name "$K" --disk-size 1024 > "$out/build-ksrc-start.log" 2>&1
  # THE CAPABILITY, ASKED OF THE GUEST. /sys/module was the wrong question: a
  # built-in veth leaves nothing there, and the check that used it called a
  # working machine broken.
  grep -q "bridge and veth are in the kernel" "$out/build-ksrc-start.log"
  say $? "the guest has bridge and veth with nothing loaded"
  grep -q "overlay mounts" "$out/build-ksrc-start.log"
  say $? "and overlayfs"
  sh "$here/tools/mvm" stop --name "$K" >/dev/null 2>&1
  rm -rf "$MVM_HOME/$K"; docker context rm "mvm-$K" >/dev/null 2>&1
  # Put the pinned one back: it is the default, and the checks after this one
  # are about what a release contains.
  sh "$here/tools/mvm" build --kernel >/dev/null 2>&1
else
  echo "  SKIP  KERNEL_SOURCE=1 builds a kernel from source (about five minutes)"
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

echo "== and the thing a person actually downloads =="
# EVERYTHING ABOVE IS ABOUT A CHECKOUT. This unpacks the archive somewhere
# else and starts a machine from it, with docker off the PATH -- which is the
# only way to know that what goes in the tarball is what a machine needs. The
# first version of the archive was complete and unusable: the tool looks in
# .build, and a release has no build directory.
sh "$here/tools/mvm" package > "$out/build-pkg.log" 2>&1
say $? "mvm package"
arch=$(ls -t "$out"/dist/*.tar.gz 2>/dev/null | head -1)
[ -n "$arch" ]; say $? "an archive ($(wc -c < "$arch" 2>/dev/null | tr -d ' ') bytes)"
# .build/guest and .build/extra are NOT in it: the guest's programs and the
# modules travel inside the initramfs, and a release that carried both would
# carry them twice.
tar tzf "$arch" 2>/dev/null | grep -qE "(guest|extra)/"; [ $? != 0 ]
say $? "and it does not carry the guest's programs twice"
T="$out/relcheck"; rm -rf "$T"; mkdir -p "$T"
tar xzf "$arch" -C "$T"
R=$(ls -d "$T"/mvm-* 2>/dev/null | head -1)
[ -n "$R" ] && [ -r "$R/INSTALL" ]; say $? "it unpacks, with something that says how to use it"
( cd "$R" && sh tools/mvm doctor >/dev/null 2>&1 ); say $? "doctor is green inside the unpacked archive"
# WHAT IT WOULD NEED ON A MACHINE THAT IS NOT THIS ONE. The nearest thing to
# another Mac that can be checked here: nothing outside /usr/lib and
# /System/Library, a guest side that is static, and no dependence on this
# shell's environment. A binary that picked up Homebrew's OpenSSL would work
# perfectly here and nowhere else, which is the failure this cannot afford.
nonsys=0
for b in mvm-boot mkdtb mports mproxy; do
  n=$(otool -L "$R/$b" 2>/dev/null | tail -n +2 | awk '{print $1}' \
      | grep -cv '^/usr/lib/\|^/System/Library/')
  nonsys=$((nonsys + n))
done
[ "$nonsys" = 0 ]; say $? "the host's programs need nothing but macOS itself ($nonsys outside /usr/lib and /System)"
X="$out/irdcheck"; rm -rf "$X"; mkdir -p "$X"
( cd "$X" && gzip -dc "$R/initrd-format.gz" | cpio -id --quiet 2>/dev/null )
st=0
for b in mengd mrun mfwd; do
  file "$X/payload/opt/$b" 2>/dev/null | grep -q "statically linked" && st=$((st + 1))
done
[ "$st" = 3 ]; say $? "and the guest's are statically linked ($st of 3) -- the guest has no loader to rely on"
rm -rf "$X"
# env -i: not one variable of this shell's. MVM_HOME is passed because the
# check keeps its machines somewhere of its own; a person gets ~/.mvm.
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    sh "$R/tools/mvm" doctor >/dev/null 2>&1
say $? "and none of it depends on this shell's environment (env -i)"
RM="rel$$"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin MVM_HOME="$MVM_HOME" \
    sh "$R/tools/mvm" start --name "$RM" --disk-size 1024 > "$out/build-rel.log" 2>&1
say $? "and a machine starts from it, with docker off the PATH"
o=$(DOCKER_HOST="unix://$MVM_HOME/$RM/docker.sock" DOCKER_CONTEXT= sh -c '
  DOCKER_HOST= docker save alpine:latest -o '"$out"'/build-rel.tar 2>/dev/null
  docker load -i '"$out"'/build-rel.tar >/dev/null 2>&1
  docker run --rm alpine:latest echo from-a-tarball 2>/dev/null' | tr -d '\r\n')
[ "$o" = "from-a-tarball" ]; say $? "and runs a container ($o)"
sh "$R/tools/mvm" stop --name "$RM" >/dev/null 2>&1
rm -rf "$MVM_HOME/$RM" "$T"; docker context rm "mvm-$RM" >/dev/null 2>&1

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
