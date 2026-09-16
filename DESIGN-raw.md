# Does virtio need a second source for `Raw`?

**No.** Written down before building the thing that was supposed to need it.

## What the plan predicted

`aidocs` note 212 said virtio would be where this project finally required a
language change. The reasoning: a virtio queue is descriptors and buffers in the
guest's RAM, so the VMM must read and write guest memory, and Mere's window type
for physical memory — `Raw` — has exactly one source, the argument
`mere -rv --bare` hands a bare-metal program. Giving it a second would be a
change to what the language guarantees.

## What `Raw` actually guarantees

From `lib/typer.ml` and `lib/codegen_riscv.ml`:

1. **Unforgeable** — no constructor, no minting function; an `int` cannot become
   one.
2. **Confined** — offsets are relative to the window, so an address outside it
   is *inexpressible*, not merely rejected. `raw_window` narrows and never
   widens, and every access bounds-checks.
3. **One source** — the bare-metal entry point's argument.

Together these make "this function cannot touch raw memory" something you read
off a signature.

## Why none of that helps here

**The confinement has nothing to confine.** A virtio implementation's window
would be *the whole of guest RAM* — the descriptors, the rings and the buffers
are all in it, at addresses the guest chooses. There is no smaller region to
narrow to and nothing inside it to be kept away from.

So `Raw` would contribute exactly one thing to this VMM: avoiding a copy. That
is a performance argument, not a capability one, and performance arguments are
answered by measuring.

## The measurement

`bench_guestmem.mere` runs the shape of a block device's load — ten small
accesses walking a descriptor chain, then one bulk transfer — against the
copying interface.

| transfer | throughput | per request |
|---|---|---|
| 4 KiB | 1,659 MB/s | 2 µs |
| 64 KiB | 14,181 MB/s | 4 µs |

A block device backed by a real disk does not come close to that. **The copy is
free at this scale**, so the language change buys nothing that can be measured.

### The first run said 53 µs, and that was the harness

The first measurement reported ~53 µs per request for a 4 KiB transfer **and**
~57 µs for a 64 KiB one. The same cost for sixteen times the data is the shape
of a fixed overhead, not of a copy — and it was: the shim opened the disk file
on every request. Opening it once moved 4 KiB from 72 MB/s to 1,659 MB/s.

Had that number been taken at face value it would have argued *for* the language
change, on evidence that was entirely about `fopen`.

## The decision

Guest memory is read and written by copying, through `hv_read_u32` and friends
and two bulk calls that move a range between guest RAM and a file. `Raw` keeps
its single source, and `test/escape/ROUTES` gains no row.

Revisit if a device appears whose access pattern is many small scattered
accesses to guest memory per operation rather than a few plus one bulk move —
a virtqueue with hundreds of descriptors per request, or a framebuffer scanned
per frame. The benchmark is the place to find out; it is in this repository for
that reason.
