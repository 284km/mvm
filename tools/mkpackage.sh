#!/bin/sh
# tools/mkpackage.sh — the thing a person downloads.
#
# WHAT GOES IN, and why it is this short. The guest's programs and the kernel's
# modules are not here: they travel inside initrd-format.gz, which is what
# installs them into a machine on its first boot. So a release is the host's
# four programs, a kernel, the initramfs, and the tool itself.
#
#   mvm-boot  mkdtb  mports  mproxy   the host's side, the first two signed
#   Image  kernel.lock               which kernel, by digest
#   initrd-format.gz                 the guest's side, and how a disk is made
#   tools/mvm  INSTALL
#
# THE SIGNATURE SURVIVES THIS. It is adhoc, which means it carries no identity
# and is not tied to the machine that made it, and the entitlement travels in
# the binary -- checked afterwards here rather than assumed.
#
# WHAT IT DOES NOT DO is remove the quarantine attribute a download gets. It
# cannot: that is the attribute's whole purpose. INSTALL says the one command,
# and `mvm doctor` says it again to anyone who skipped it.
#
#   sh tools/mkpackage.sh [outdir]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"
dist="${1:-$out/dist}"

# NOTHING IS PACKAGED THAT DOES NOT WORK. doctor is the same check a person
# runs after unpacking, so failing it here is failing it there, earlier.
sh "$here/tools/mvm" doctor >/dev/null 2>&1 || {
  echo "mkpackage: not packaging an incomplete machine:" >&2
  sh "$here/tools/mvm" doctor >&2
  exit 1; }

# A NAME THAT SAYS WHAT IT IS. The commit, because that is what the source was;
# and "dirty" when it was not exactly that, because a release built from
# uncommitted work is a release nobody else can reproduce.
rev="$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$here" status --porcelain 2>/dev/null)" ] && rev="$rev-dirty"
name="mvm-$(date -u +%Y%m%d)-$rev-macos-arm64"
work="$out/pkg-work/$name"
rm -rf "$out/pkg-work"; mkdir -p "$work/tools"

for f in mvm-boot mkdtb mports mproxy Image kernel.lock initrd-format.gz; do
  [ -r "$out/$f" ] || { echo "mkpackage: no $f" >&2; exit 1; }
  cp "$out/$f" "$work/$f"
done
cp "$here/tools/mvm" "$work/tools/mvm"
chmod 755 "$work/tools/mvm" "$work"/mvm-boot "$work"/mkdtb "$work"/mports "$work"/mproxy

cat > "$work/INSTALL" <<'TXT'
mvm — a container stack for macOS on Apple silicon.

  1. macOS marks anything downloaded. Take the mark off, or the VMM will not
     run -- and it will not say so: it hangs.

       xattr -dr com.apple.quarantine .

  2. Ask what is here:

       sh tools/mvm doctor

  3. Start a machine. The first start makes its disk, which takes a few
     seconds; the guest does that itself, so nothing else has to be installed.

       sh tools/mvm start
       docker context use mvm-default
       docker run --rm alpine echo hello

  4. Put it away. This asks the machine to stop rather than killing it,
     because a machine killed a second after a container was created comes
     back without it.

       sh tools/mvm stop

What you need: macOS on Apple silicon. Not docker -- that is the point -- and
not a compiler.

What is inside, and what it is: the VMM (mvm-boot), the device tree writer
(mkdtb), the port watcher (mports), a CONNECT proxy so the guest can reach the
network (mproxy), a Linux kernel, and an initramfs that carries the daemon and
the runtime and makes the machine's disk on first boot. kernel.lock says which
kernel, by digest.
TXT

mkdir -p "$dist"
( cd "$out/pkg-work" && tar czf "$dist/$name.tar.gz" "$name" ) \
  || { echo "mkpackage: could not write the archive" >&2; exit 1; }

# UNPACKED AND ASKED AGAIN. A signature that did not survive, or a file that
# did not go in, is a release that fails on somebody else's machine and nowhere
# here. Checking the archive rather than the directory it was made from is the
# difference.
v="$out/pkg-verify"; rm -rf "$v"; mkdir -p "$v"
tar xzf "$dist/$name.tar.gz" -C "$v"
codesign -d --entitlements - "$v/$name/mvm-boot" 2>&1 | grep -q "com.apple.security.hypervisor" \
  || { echo "mkpackage: the entitlement did not survive the archive" >&2; exit 1; }
codesign --verify "$v/$name/mvm-boot" 2>/dev/null \
  || { echo "mkpackage: the signature did not survive the archive" >&2; exit 1; }
rm -rf "$v" "$out/pkg-work"

sz=$(wc -c < "$dist/$name.tar.gz" | tr -d ' ')
echo "mkpackage: $sz bytes -> $dist/$name.tar.gz"
shasum -a 256 "$dist/$name.tar.gz" | sed 's/^/  /'
