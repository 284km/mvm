# virtio-vsock: what is implemented and what is not

## Why this device and not a network

The host and the guest have to talk. The three ways to arrange that are not
equally available here:

- **virtio-net** needs a host interface, and on macOS that is
  `vmnet.framework`. `vmnet_start_interface` returns status `1001` for a
  process that is not root. That is not a thing to work around; it is the
  operating system saying who may create an interface.
- **A shared file** is not a stream. Two programs polling a file have
  reinvented a worse socket with no framing and no end-of-file.
- **vsock** exists for exactly this. No addresses, no DHCP, no bridge, no
  routing: a guest says "the host, port 1234" and that is the whole address.

The guest kernel already has it. Not built in — `CONFIG_VSOCKETS`,
`CONFIG_VIRTIO_VSOCKETS` and `CONFIG_VIRTIO_VSOCKETS_COMMON` are `=m` in a
stock kernel — which is a fact about the initramfs, not about the device, and
the check carries the three `.ko` files and loads them.

## The shape

Device id 19 on a second virtio-mmio transport at `0xa000200`, with its own
interrupt (SPI 17, intid 49). It shares the transport code's descriptor
walking with virtio-blk but not its window or its interrupt: what is behind the
queues is a different device, and two devices sharing one interrupt is a thing
to get wrong for no gain.

Three queues — rx (0), tx (1), event (2) — so the device state is per-queue.
The block device has one queue and its state held one descriptor table address;
a field that holds one address cannot answer for three.

The guest's end of a stream is a virtqueue. **The host's end is an ordinary
`AF_UNIX` socket**, so what the guest connects to is a real program, chosen by
the path in `MVM_VSOCK`. Mere drives the protocol — queues, headers, the state
machine — and C moves the bulk, which is the same division the block device
uses.

## The subset

**Implemented**: `REQUEST`/`RESPONSE`, `RW` in both directions, `CREDIT_UPDATE`
and `CREDIT_REQUEST`, `SHUTDOWN`, `RST`, and `VIRTIO_F_VERSION_1` — the only
feature offered.

**Refused rather than approximated**, each by a packet the guest can see:

| not implemented | what the guest gets |
|---|---|
| a second stream while one is open | `RST` |
| a host with nothing listening | `RST`, and the VMM names the path |
| `SEQPACKET` | not offered, so a driver cannot ask for it |
| any other operation | `RST`, and the VMM names the number |
| a host-initiated connection | there is no code for it, and no packet claims otherwise |

The guest CID is 3 and the host's is 2, which is what the specification fixes.

## Credit

Every packet this end sends carries `buf_alloc` and `fwd_cnt`, and every packet
it receives updates what it believes about the guest's. Before filling a
receive buffer it works out what the guest has room for — what it said it can
hold, less what it has been sent and not yet taken — and sends no more than
that. Ignoring this is how a device overruns a driver that was telling it not
to, and it costs nothing to get right at the point where the header is written
anyway.

## The wake-up, which is the whole difficulty

`hv_vcpu_run` blocks. A guest blocked in `read()` on a vsock stream is idle, so
the loop that would poll the host socket **is not running**. Every obvious
polling point turns out to be one the guest stops reaching:

- WFI is not where an idle Linux guest sits, from this VMM's point of view.
- The virtual timer exit is — but this VMM masks the virtual timer on every
  timer exit, which removes the last thing that was waking it.

The measurement said so plainly: **4 polls in 52,189 exits**, then eight seconds
of nothing while a reply sat readable on the host socket. Everything up to the
guest's write worked, so a check that stopped at "the stream opened" was green.

The fix is the same shape as the deadline: a thread that polls the host socket
and calls `hv_vcpus_exit` when it becomes readable. It signals rather than
copies — every byte still moves on the vCPU's thread — and it only decides
*when*. A cancellation is then ambiguous between the deadline and this, so the
loop asks which before deciding to stop.

Draining matters too. A reply larger than one receive buffer is the normal
case, and handing over one buffer per wake-up makes the stream's speed a
property of how often a thread happens to poll rather than of the device.

## How it is judged

Not "the device answered its registers" — a device that answers registers and
moves nothing looks identical from outside. `test/vsock.sh` requires that bytes
the **guest** wrote arrived at a program on the **host**, and that bytes that
program wrote came back:

```
userspace: vsock_client exit 0: vsock-client: got 39 bytes: host saw 20 bytes: HELLO FROM THE GUEST
userspace: vsock_bulk exit 0: vsock-client: bulk ok 65536 bytes each way
```

The host's reply is **derived** from what arrived rather than echoed. An echo
cannot tell "the bytes made the round trip" apart from "the guest is looking at
its own transmit buffer", and those are the two things the check exists to
distinguish.

The second stream is 65536 bytes each way with **every byte checked by value**,
at both ends. One short message fits in a single receive buffer and so never
asks whether credit, refill or ordering work; a device that repeated a buffer
or handed them over out of order moves exactly the right *number* of bytes. It
is also the second stream on a device that has already closed one, which is its
own thing to get wrong.

Guest side of that stream: 0.2270 s to 0.2359 s by the kernel's own clock, so
**128 KiB in 8.9 ms**, and the host end was asked 33 times across the run.

### What the poisons say

| break | what goes red |
|---|---|
| take the host program away | `connect()` must fail rather than hang — a device that accepts the connection and leaves the guest waiting would look like "no reply", which a weaker check would call a pass |
| remove the wake-up thread | the stream still opens and the guest still writes; the reply never arrives. This is the bug that actually happened, and it was invisible to every check up to "the stream opened" |

## What it does not do

One stream at a time, and the host end is chosen by one path at startup. No
host-initiated connections, so a server inside the guest is not reachable from
outside yet — that is the direction a container daemon in the guest needs, and
it is the next thing rather than a thing this claims.
