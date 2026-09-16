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

A stream's guest end is a virtqueue and its host end is an ordinary `AF_UNIX`
socket, so what is at the other end is a real program either way. Mere drives
the protocol — queues, headers, the state machine, the table of streams — and C
moves the bulk, which is the same division the block device uses.

## Both directions, and why they are not one

| | the host end | who starts the handshake |
|---|---|---|
| **outward** | the VMM connects to the path in `MVM_VSOCK` | the guest sends `REQUEST` |
| **inward** | the VMM listens at the path in `MVM_VSOCK_IN` | **the VMM** sends `REQUEST`, toward `MVM_VSOCK_PORT` |

The inward direction is the one a container daemon inside the VM needs: a host
program connects to an ordinary path on the host's filesystem and reaches a
server in the guest, without knowing a VM is involved.

It is **not the outward direction with the arguments swapped**. Outward, the
guest sends `REQUEST` and this end answers. Inward, this end has to send
`REQUEST` — on the receive queue, which the guest fills — and then wait for the
guest's `RESPONSE`. A stream therefore has three states rather than two: free,
waiting for the guest to answer, and open.

Eight streams at a time, and a stream is named by the **pair** of ports: the
guest may have several streams to one port of this end's and vice versa, so
neither port alone identifies one.

A host that connects before the guest's driver is up gets a refusal rather than
a wait, and the VMM says so:

```
mvm: vsock could not send op 1: no rx buffer (qnum 0 ready 0)
mvm: vsock dropped that inward stream; the guest was not ready
```

The stream is **released** rather than left waiting. Keeping it would hold a
slot and an open host socket for a handshake that was never started, and there
are eight slots: eight early connections would leave no room for the ninth,
which is the one that would have worked. The host's own retry is what closes
the gap, and `test/vsock_in.py` does exactly that — the first attempt of a run
is normally refused.

## The subset

**Implemented**: `REQUEST`/`RESPONSE`, `RW` in both directions, `CREDIT_UPDATE`
and `CREDIT_REQUEST`, `SHUTDOWN`, `RST`, and `VIRTIO_F_VERSION_1` — the only
feature offered.

**Refused rather than approximated**, each by a packet the guest can see:

| not implemented | what the guest gets |
|---|---|
| more streams than the table holds | `RST`, and the VMM names the limit |
| a host with nothing listening | `RST`, and the VMM names the path |
| a packet for a stream this end does not have | `RST` — a guest waiting on a stream nobody owns waits forever |
| an outward `REQUEST` with no `MVM_VSOCK` given | `RST`, and the VMM says it was given no path |
| `SEQPACKET` | not offered, so a driver cannot ask for it |
| any other operation | `RST`, and the VMM names the number |

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

The inward direction is judged the same way, from the other side. A host
program connects to a path on the host and a server **inside the guest**
answers, twice, each with its own reply:

```
host got 39 bytes after 3 attempts: guest saw 19 bytes: HELLO FROM THE HOST
host got 28 bytes after 1 attempts: guest saw 9 bytes: AND AGAIN
userspace: vsock_server exit 0: listening on port 1024 / served 19 bytes / served 9 bytes
```

### What the poisons say

| break | what goes red |
|---|---|
| take the host program away | `connect()` must fail rather than hang — a device that accepts the connection and leaves the guest waiting would look like "no reply", which a weaker check would call a pass |
| remove the wake-up thread | the stream still opens and the guest still writes; the reply never arrives. This is the bug that actually happened — **twice**, once in each direction, because the thread was started by an event rather than by the device coming up |
| start the inward handshake from the wrong end (answer `RESPONSE` instead of asking `REQUEST`) | the host still reaches the VMM and a stream is still allocated; the guest never accepts. This is the mistake "the same code with the arguments swapped" would make |
| treat a half-close as the end of the stream (`SHUTDOWN` with `3`) | `docker load` and `docker logs` stay green; `docker run` prints nothing, while the daemon's log says it framed the bytes. In `test/stack.sh`, because it takes a real client to close one side and keep reading the other |

## End of file is not the end of the stream

The longest-lived bug in this device, and the one that only a real client
found. `read()` on the host end returning 0 means **the peer will send no
more**. It does not mean the connection is over: a client that closes its write
side is still waiting to read the answer, and `docker run` does exactly that on
the connection it attaches with.

The first version answered that by telling the guest `SHUTDOWN` with **both**
flags set, and by closing the host socket. Both halves were wrong:

- flags `3` says "this end will neither send nor receive", which shuts down the
  **guest's write side** — the direction that still had the answer in it;
- closing the socket takes the write direction with it, so even a correct
  SHUTDOWN would have had nowhere to go.

It now sends `F_SEND` alone (`2`) and **mutes** the socket rather than closing
it: the fd stops being polled for reading, because an fd at end of file stays
readable forever and a poll that still watched it would spin.

The witness was an attach stream that carried its 101 response header — 117
bytes — and nothing after it, while the daemon's own log said it had framed 26
bytes of the container's output. `docker logs` was green the whole time,
because that is a separate connection that nobody half-closes. `test/stack.sh`
poisons it by putting the `3` back.

## A truncated initramfs is not an error

Worth writing down because it cost an hour and said nothing. The device tree
carries the initrd's **bounds**, so booting one archive with a tree built for a
slightly smaller one hands the kernel a shorter length. The kernel unpacks what
it was told to and says nothing; the guest then has an `/opt` with files
missing, and every command fails instantly with an empty error message. The
gate builds a tree per archive and checks for `Initramfs unpacking failed`.

It is the same shape as the trap in `initrd/build.sh`: a bind mount of a path
the container runtime does not have produces an empty directory rather than an
error, and the archive came out 89 bytes with nothing anywhere saying why.

## What it does not do

Eight streams, one outward path and one inward path, chosen at startup. No
port mapping — every inward connection goes to the same guest port — and no
`SOCK_SEQPACKET`. `MVM_VSOCK_TRACE` prints each packet, which is the only way
to see the handshake from this side.
