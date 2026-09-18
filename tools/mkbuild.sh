#!/bin/sh
# tools/mkbuild.sh — everything a machine is made of, built here.
#
# WHY THIS EXISTS. The pieces were built by test/stack.sh, which is a CHECK. A
# tool that tells the person who wants to use it to run its test suite first
# has the order wrong, and it also means the artefacts only exist as long as
# somebody keeps running the tests.
#
# TWO SIDES, and they are not the same build:
#
#   host  (macOS arm64, SIGNED)   mvm-boot  mkdtb  mports  mproxy
#   guest (linux/arm64, STATIC)   mengd     mrun   mfwd
#
# The guest's are static because the guest has no package manager, no dynamic
# loader worth relying on and no compiler; the host's are signed because
# Hypervisor.framework refuses an unsigned VMM.
#
# The guest binaries land in .build/guest/, not in somebody else's checkout, so
# that a machine can be started from this directory alone. MENGD_SRC and
# MRUN_SRC are needed to BUILD them and not to use them.
#
#   MERE=<mere checkout> MENGD_SRC=<mengd> MRUN_SRC=<mrun> sh tools/mkbuild.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"
mkdir -p "$out/guest"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "mkbuild: set MERE=<a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "mkbuild: no mere binary at $M" >&2; exit 2; }
IMG="${IMG:-gcc:14}"
fail=0

# THE OLDEST macOS THIS CAN RUN ON, written once. clang reads this variable for
# every compile it does from here, so the floor does not have to be repeated at
# each cc line -- and repeating a rule is how it becomes three different rules.
#
# 15.0 is not a preference. hv_gic_create and the eight calls around it are
# API_AVAILABLE(macos(15.0)); everything else this uses is macOS 11. Without a
# target declared, clang stamps the version of the machine that happened to do
# the build (26.0 here) and, worse, says NOTHING when code calls something
# newer -- and Hypervisor.framework has entries marked macos(26.0) and
# macos(27.0) waiting to be called by accident.
MVM_MACOS_MIN="${MVM_MACOS_MIN:-15.0}"
export MACOSX_DEPLOYMENT_TARGET="$MVM_MACOS_MIN"

emit() {  # emit <source> <out.c>
  "$M" -c "$1" > "$2" 2>"$out/mkbuild.err" || {
    echo "mkbuild: could not compile $1:" >&2; sed -n 1,8p "$out/mkbuild.err" >&2; return 1; }
}

echo "== the host's side =="
for prog in boot:mvm-boot mkdtb:mkdtb mports:mports mproxy:mproxy; do
  src="${prog%%:*}"; bin="${prog##*:}"
  emit "$here/$src.mere" "$out/$src.c" || { fail=1; continue; }
  case "$src" in
    boot|mkdtb) shim="$here/hv_shim.c"; extra="-framework Hypervisor";;
    mports)     shim="$here/mports_shim.c"; extra="";;
    mproxy)     shim="$here/proxy_shim.c"; extra="";;
  esac
  # -Werror on the availability warning, which is the whole reason the floor
  # above is declared: calling something newer than 15.0 stops the build here
  # rather than on somebody else's Mac.
  # shellcheck disable=SC2086
  cc -O2 -Werror=unguarded-availability-new -o "$out/$bin" "$out/$src.c" "$shim" $extra \
       2>"$out/cc-$bin.err" \
    || { echo "mkbuild: could not link $bin" >&2; sed -n 1,6p "$out/cc-$bin.err" >&2; fail=1; continue; }
  echo "  built $bin"
done
# SIGNED, and only the two that talk to the framework. An unsigned VMM is
# refused by Hypervisor.framework with an error that names entitlements, hours
# after the build that produced it.
for b in mvm-boot mkdtb; do
  [ -x "$out/$b" ] || continue
  codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null \
    || { echo "mkbuild: could not sign $b" >&2; fail=1; }
done
codesign -dv "$out/mvm-boot" 2>&1 | grep -q Signature && echo "  signed mvm-boot, mkdtb"

# WHAT A MACHINE WITHOUT DOCKER CAN STILL CHECK. CI has no docker on macOS, and
# the host's side is where the compiler is the gate; stopping here lets the real
# build command run there rather than a copy of it kept in a workflow file.
if [ "${MVM_HOST_ONLY:-0}" = 1 ]; then
  echo "== stopping after the host's side (MVM_HOST_ONLY=1) =="
  [ "$fail" = 0 ] || exit 1
  exit 0
fi
command -v docker >/dev/null 2>&1 || { echo "mkbuild: needs docker to build for the guest" >&2; exit 2; }

echo "== the guest's side =="
[ -n "${MENGD_SRC:-}" ] && [ -f "$MENGD_SRC/mengd.mere" ] || { echo "mkbuild: set MENGD_SRC" >&2; exit 2; }
[ -n "${MRUN_SRC:-}" ] && [ -f "$MRUN_SRC/mrun.mere" ] || { echo "mkbuild: set MRUN_SRC" >&2; exit 2; }
mkdir -p "$MENGD_SRC/.build" "$MRUN_SRC/.build"
emit "$MENGD_SRC/mengd.mere" "$MENGD_SRC/.build/mengd.c" || exit 1
emit "$MRUN_SRC/mrun.mere"   "$MRUN_SRC/.build/mrun.c"   || exit 1
emit "$here/guest/mfwd.mere" "$out/mfwd.c"               || exit 1

# The daemon links OpenSSL, and a static link wants zlib and zstd with it --
# which is not obvious until the linker asks for `inflate` and
# `ZSTD_decompressStream`. A prepared image makes this quick; without one the
# packages go in on each build, which is slower and always works.
#
# NOT `docker build`. The legacy builder in the Docker CLI on macOS hangs
# against any daemon, real ones included, and a tool that hangs while building
# itself is worse than one that takes a minute.
if docker image inspect mvm-build:1 >/dev/null 2>&1; then
  PREP=""; BIMG="mvm-build:1"
  echo "  using the prepared toolchain image mvm-build:1"
else
  PREP="apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y libssl-dev zlib1g-dev libzstd-dev >/dev/null 2>&1 && "
  BIMG="$IMG"
  echo "  no mvm-build:1 -- installing the libraries in $IMG for this build (docker build mvm-build:1 to cache it)"
fi
docker run --rm -v "$MENGD_SRC:/w" -w /w "$BIMG" sh -c \
  "${PREP}cc -O2 -static -o .build/mengd-linux .build/mengd.c unix_shim.c fs_shim.c store_shim.c net_shim.c -lssl -lcrypto -lz -lzstd -ldl -lpthread" \
  >/dev/null 2>&1
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c >/dev/null 2>&1
docker run --rm -v "$out:/o" -v "$here/guest:/g:ro" -w /o "$IMG" \
  cc -O2 -static -o /o/mfwd-linux /o/mfwd.c /g/fwd_shim.c >/dev/null 2>&1

for p in "$MENGD_SRC/.build/mengd-linux:mengd" "$MRUN_SRC/.build/mrun-linux:mrun" "$out/mfwd-linux:mfwd"; do
  src="${p%%:*}"; name="${p##*:}"
  if [ -x "$src" ]; then cp "$src" "$out/guest/$name"; chmod 755 "$out/guest/$name"; echo "  built $name for the guest"
  else echo "mkbuild: $name did not build" >&2; fail=1; fi
done

echo "== the initramfs that makes a disk =="
# LAST, because it contains the guest's programs and the kernel's modules: it
# is the thing a person downloads, and it is how a machine gets a filesystem on
# a system that cannot write ext4.
if sh "$here/tools/mkinitrd.sh" 2>&1 | sed 's/^/  /'; then :; else
  echo "  (needs mvm build --kernel first, for the modules)" >&2; fail=1
fi

echo "== what is missing =="
sh "$here/tools/mvm" doctor || fail=1
[ "$fail" = 0 ] || { echo "mkbuild: something did not build" >&2; exit 1; }
echo "mkbuild: done -- .build has a machine in it"
