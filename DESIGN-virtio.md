# virtio-blk: what is implemented and what is not

## The shape

A virtio-mmio transport at `0xa000000` and one block device behind it. The
guest drives it through 32-bit registers; the queue itself is in the guest's
RAM and the VMM reads it by copying (`DESIGN-raw.md` for why copying).

The device tree node, the MMIO base, and the interrupt number are written by
the same program that answers at them — `mkdtb.mere` and `boot.mere` share the
constants rather than agreeing about them.

## The subset

**Implemented**: the transport registers version 2 requires, one virtqueue,
`VIRTIO_BLK_T_IN` and `VIRTIO_BLK_T_OUT`, and `VIRTIO_F_VERSION_1`, which is
the only feature offered.

**Not implemented, and refused rather than approximated**: indirect descriptors
(`VIRTIO_RING_F_INDIRECT_DESC` is not offered, so a driver cannot use them),
`VIRTIO_BLK_T_FLUSH` (answered as unsupported, which is honest for a device
with no write cache of its own — writes go straight to the file), multiple
queues, and `VIRTIO_BLK_F_*` size hints, which a driver treats as absent.

A request whose descriptor chain does not have the shape the specification
requires — a readable header, some data, a writable status byte — is answered
with `VIRTIO_BLK_S_UNSUPP` rather than guessed at.

## Interrupts

Level, not edge. The specification allows either and an edge is one pulse: if
the driver is not looking, it is gone. A level is raised when the used ring
gains an entry and lowered when the driver acknowledges it, so a driver that
was busy still finds it.

## How it is judged

Not "the device registers read back". The guest has to **mount the disk and
read a file whose contents this VMM put there**, which cannot happen unless the
queue was walked correctly, the data landed at the guest addresses the
descriptors named, and the interrupt arrived.
