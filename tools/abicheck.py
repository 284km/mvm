#!/usr/bin/env python3
# tools/abicheck.py -- does the declaration the caller compiles against say the
# same thing as the C that defines it?
#
# Mere's int is 64 bits; the extern prototype its C backend emits for one says
# plain `int`. A shim written with `long long` therefore compiles clean on both
# sides while the CALLER truncates the argument on the way in -- there is
# nothing to see at the call site, no warning, and no failure until a value
# happens to exceed 2^32.
#
# That is not hypothetical here. virtio-blk passed its byte offset this way,
# so on the default 20 GiB disk every access at or past 4 GiB wrapped to the
# bottom of the file: mke2fs reported success and the block bitmaps for the
# groups above the line came back as whatever had overwritten them.
#
# It asks a second question too. One shim function is declared separately in
# every Mere file that calls it, and those declarations age INDEPENDENTLY:
# `hv_map` went int -> str when a guest first asked for 2 GiB, boot.mere and
# mvm.mere were updated, and bench_guestmem.mere was not -- it segfaulted with
# no output for months because nobody ran it. Fixing the block offset here
# found the same file carrying a second stale declaration. Three instances of
# one shape is enough: the same name must have the same type everywhere.
#
# Usage: abicheck.py <generated .c> <shim .c>... [--mere <file.mere>...]
# Exits 1 if any prototype and definition disagree in width, or if one extern
# is declared two different ways.
import re, sys

def widths(t):
    t = t.replace("const", "").strip()
    if "*" in t:
        return "ptr"
    t = re.sub(r"\b\w+$", "", t).strip() or t     # a parameter may carry a name
    if t in ("long long", "unsigned long long", "int64_t", "uint64_t",
             "size_t", "ssize_t", "long", "unsigned long", "off_t"):
        return "64"
    if t in ("int", "unsigned", "unsigned int", "int32_t", "uint32_t"):
        return "32"
    return t or "?"

def split_params(p):
    p = p.strip()
    return [] if not p or p == "void" else [x.strip() for x in p.split(",")]

def declarations_agree(meres):
    """Every Mere file that declares an extern must declare it the same way."""
    seen = {}
    for f in meres:
        for m in re.finditer(r"^\s*extern\s+fn\s+(\w+)\s*:\s*([^;]+);", 
                             open(f, errors="replace").read(), re.M):
            sig = " ".join(m.group(2).split())
            seen.setdefault(m.group(1), {}).setdefault(sig, []).append(f)
    bad = 0
    for name, sigs in sorted(seen.items()):
        if len(sigs) > 1:
            bad += 1
            print("  %s is declared %d different ways:" % (name, len(sigs)))
            for sig, files in sorted(sigs.items()):
                print("      %-40s %s" % (sig, ", ".join(sorted(set(files)))))
    print("%d externs declared inconsistently, of %d names across %d files"
          % (bad, len(seen), len(meres)))
    # No names found means the files were wrong, not that everything agrees.
    return 1 if bad or not seen else 0


def main(argv):
    argv = list(argv)
    meres = []
    if "--mere" in argv:
        i = argv.index("--mere")
        meres = argv[i + 1:]
        argv = argv[:i]
    # THE DECLARATION CHECK NEEDS NO COMPILER. It reads .mere files as text, so
    # it runs on any machine -- which is the whole point of having it: the file
    # whose declarations rotted was one that nothing on this platform compiles.
    if len(argv) < 3 and not meres:
        print("usage: abicheck.py [<generated .c> <shim .c>...] [--mere <file.mere>...]",
              file=sys.stderr)
        return 2
    if len(argv) < 3:
        return declarations_agree(meres)
    gen, shims = argv[1], argv[2:]
    src = open(gen, errors="replace").read()
    protos = {}
    for m in re.finditer(r"\bextern\s+([A-Za-z_][\w \*]*?)\s+(\w+)\s*\(([^)]*)\)\s*;", src):
        protos.setdefault(m.group(2), (m.group(1).strip(), split_params(m.group(3))))
    defs = {}
    for f in shims:
        for m in re.finditer(r"^([A-Za-z_][\w \*]*?)\s+(\w+)\s*\(([^)]*)\)\s*\{",
                             open(f, errors="replace").read(), re.M):
            if m.group(1).strip().startswith(("static", "if", "for", "while",
                                              "switch", "return")):
                continue
            defs[m.group(2)] = (f, m.group(1).strip(), split_params(m.group(3)))
    bad = checked = 0
    for name, (ret, params) in sorted(protos.items()):
        if name not in defs:
            continue
        checked += 1
        f, dret, dparams = defs[name]
        if len(params) != len(dparams):
            print("  %-26s declared %d arguments, defined with %d  (%s)"
                  % (name, len(params), len(dparams), f))
            bad += 1
            continue
        for i, (a, b) in enumerate(zip(params, dparams)):
            if widths(a) != widths(b):
                print("  %-26s argument %d: declared `%s', defined `%s'  (%s)"
                      % (name, i + 1, a, b, f))
                bad += 1
        if widths(ret) != widths(dret):
            print("  %-26s returns: declared `%s', defined `%s'  (%s)"
                  % (name, ret, dret, f))
            bad += 1
    print("%d disagreed, of %d externs matched to a definition" % (bad, checked))
    # Nothing matched means the arguments were wrong, not that all is well.
    rc = 1 if bad or checked == 0 else 0
    if meres:
        rc = declarations_agree(meres) or rc
    return rc

if __name__ == "__main__":
    sys.exit(main(sys.argv))
