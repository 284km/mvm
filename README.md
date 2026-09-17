# mvm

A virtual machine monitor in [Mere](https://merelang.org/), on Apple's
Hypervisor.framework.

**A real `docker` client runs containers on it.**

```
$ docker -H unix://.build/docker.sock run alpine sh -c 'echo to-stdout'
to-stdout
$ docker -H unix://.build/docker.sock version --format '{{.Server.Version}}/{{.Server.Arch}}'
0.1.0/linux/arm64
```

```
docker (macOS) -> a unix socket -> mvm -> virtio-vsock -> mengd -> mrun -> the container
```

`docker compose up` works, and so do published ports — a host TCP port carried
in over vsock and delivered inside the container's own network namespace:

```
$ docker -H unix://.build/docker.sock compose up
 Network compose_default  Created
 Container compose-hello-1  Created
Attaching to hello-1
hello-1  | hello-from-compose

$ docker -H unix://.build/docker.sock run -d -p 19090:8080 alpine \
    sh -c 'while true; do echo hello-from-19090 | nc -l -p 8080; done'
$ nc 127.0.0.1 19090
hello-from-19090
```

Nothing was told about 19090 beforehand. The container asks for it, `mports`
notices, and the VMM opens the host's end — and closes it again when the
container goes.

Everything after the client is Mere: this VMM, the vsock device it carries the
stream over, [mengd](https://github.com/284km/mengd) answering the Docker
Engine API inside the guest, and [mrun](https://github.com/284km/mrun) as its
OCI runtime. No lima, no vz, no Go. `sh test/stack.sh` is the check, and its
oracle is the client a person actually types at.

---

**A real Linux kernel boots on it and runs userspace** —
Alpine's busybox as pid 1, mounting filesystems and powering the machine down
through PSCI.

```
[    0.153470] Run /init as init process
[    0.161653] userspace: devtmpfs is mounted and kmsg is writable
[    0.162770] userspace: uname Linux 6.8.0-117-generic aarch64
[    0.163771] userspace: pid 1 uid 0
[    0.165255] userspace: root has 18 entries
[    0.166320] reboot: Power down
mvm: guest called PSCI SYSTEM_OFF
```

It has a **virtio-blk device**, so the guest mounts a real filesystem off a
disk image and reads and writes files on it:

```
[    0.103121] virtio_blk virtio0: [vda] 32768 512-byte logical blocks (16.8 MB)
[    0.159524] EXT4-fs (vda): mounted filesystem ... r/w with ordered data mode
userspace: disk says: this file came off a virtio-blk device emulated in Mere
userspace: wrote a file back
```

and the host finds those bytes in the image afterwards.

It has a **virtio-vsock device**, so a program in the guest holds a conversation
with a program on the host — the guest's end is a virtqueue, the host's end is
an ordinary unix socket:

```
[    0.227002] userspace: vsock_client exit 0: got 39 bytes: host saw 20 bytes: HELLO FROM THE GUEST
[    0.235926] userspace: vsock_bulk exit 0: bulk ok 65536 bytes each way
mvm: vsock stream open, guest port 598999410 to port 1234
```

and **in the other direction**, which is the one a daemon inside the VM needs —
a host program connects to an ordinary path on the host's filesystem and
reaches a server in the guest:

```
host got 39 bytes after 3 attempts: guest saw 19 bytes: HELLO FROM THE HOST
mvm: vsock listening at /tmp/vs-in.sock for guest port 1024
mvm: vsock inward stream, host port 49153 to guest port 1024
mvm: vsock inward stream accepted by the guest on port 49153
```

Each reply is *derived* from what arrived rather than echoed, because an echo
cannot tell "the bytes crossed" apart from "the caller is looking at its own
buffer". 128 KiB crosses in 8.9 ms by the guest's own clock, every byte checked
by value at both ends.

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]
[    0.000000] Machine model: linux,dummy-virt
[    0.000000] GICv3: 988 SPIs implemented
[    0.000000] arch_timer: cp15 timer(s) running at 24.00MHz (virt).
[    0.024394] devtmpfs: initialized
[    0.116989] VFS: Cannot open root device "" or unknown-block(0,0): error -6
[    0.119115] Kernel panic - not syncing: VFS: Unable to mount root fs
mvm: guest called PSCI SYSTEM_RESET
```

```sh
sh initrd/build.sh   # an initramfs from a container image, with the init below
sh test/stack.sh     # a real docker client runs a container inside this VMM
sh test/vsock.sh     # the guest and a host program hold a conversation, both ways
sh test/disk.sh      # virtio-blk, judged from both ends
sh test/init.sh      # userspace runs
sh test/boot.sh      # the kernel boots and panics for the right reason
sh test/run.sh       # the one-instruction check
```

**A panic is the judgement on purpose.** It means the CPU, the memory map, the
interrupt controller and the timer all worked, and it is the first thing a guest
says that a VMM which merely started cannot fake. The test requires it to be
*that* panic: any other one is a different failure using the same word.

```sh
export MERE=/path/to/a/merelang/mere/checkout
sh test/run.sh
```

```
  ok    the binary carries com.apple.security.hypervisor
  ok    it loaded the value it was given (42 -> 0x2a)
  ok    it loaded the value it was given (1234 -> 0x4d2)
  ok    it loaded the value it was given (65535 -> 0xffff)
  ok    the exit is EC 0x16, an HVC from the guest
  ok    the pc advanced past both instructions
  ok    with nothing to execute it does not claim the guest ran
```

A Mere program creates the VM, maps guest memory at `0x40000000`, writes two
AArch64 instructions into it — `movz x0, #N` and `hvc #0` — creates a vCPU at
EL1h, and runs it. The guest loads the value and traps out; `x0` comes back
holding it and the program counter has advanced past both.

The value is given on the command line rather than fixed, because "the guest
ran" should be a claim about *that* number. A check that only ever asks for 42
passes against a hypervisor that always answers 42.

## The device tree is generated, not compiled

`mkdtb` writes the DTB the kernel is handed — memory, CPU, PSCI, the timer, the
GIC and the PL011 — and `dtc -I dtb -O dts` reads it back as the check.
Compiling it from a `.dts` would work and would mean the VMM does not know what
it is telling the guest: **the addresses in the tree have to agree with the ones
the emulator answers at, and two files that have to agree are two files that can
disagree.**

That is not hypothetical. The GIC window sizes were written into the tree by
hand first — `0x10000` and `0x100000`, because they looked like enough — and the
kernel took a data abort in the middle of GIC initialisation at `0x80affe8`, an
address inside the window the tree claimed and outside the one the framework
answers for. `mkdtb` asks the framework (`hv_gic_get_distributor_size`,
`hv_gic_get_redistributor_size`) and writes down the answer.

## Three things the guest could not have told us

**The physical address, not the virtual one.** The first MMIO dispatch used
`exception.virtual_address`, which is where the *kernel* mapped the device in
its own page tables. Every access went to "unhandled". The device is at the
address the device tree named, and only `physical_address` says so.

**The flag register has to answer.** The early console polls the PL011's FR at
offset `0x18` and will not write a byte until TXFF is clear. Answering zero is
what lets it speak at all — before that it was a guest that ran perfectly and
said nothing.

**MPIDR_EL1 before the redistributor exists.** The framework places a vCPU's GIC
redistributor from its affinity, and the header says so: *"must be called after
the affinity of the given vCPU has been set in its MPIDR_EL1 register"*. Without
it `hv_gic_get_redistributor_base` answers `HV_BAD_ARGUMENT` and the
redistributor is nowhere — which the guest discovers as a data abort on a
register the device tree promised. **The answer was in the header the whole
time**, one line below the function that was returning the error.

## Why there is a C file at all, when `hv_*` is already C

The FFI boundary's `int` is C's `int`: 32 bits. A guest physical address fits
only while the guest is small and a register **value** never does, so 64-bit
quantities cross as hex strings — explicit, printable, and wrong in a way that
shows up immediately rather than as a silently truncated address.

## Two things that were not obvious

**The host mapping must not be executable.** The first version asked `mmap` for
`PROT_EXEC` and got `MAP_FAILED`: on Apple silicon an anonymous executable
mapping needs the JIT entitlement. It does not need to be executable at all —
the guest's permission to execute comes from `HV_MEMORY_EXEC` in `hv_vm_map`,
which is a property of the guest's view of that memory, not the host's.

**CPSR has to be set even to the value it already reads.** Without writing
`0x3c5` the vCPU starts at EL0 and the first instruction faults instead of
running.

## Entitlements

Ad-hoc signing is enough:

```sh
codesign --sign - --force --entitlements mvm.entitlements ./mvm
```

No developer account and no notarisation. Homebrew signs `qemu` the same way for
`com.apple.security.hypervisor`, which is how this was checked before any of it
was written.

### The exit status was the only channel, and it was enough

Before `/dev` exists, init has no stdout: the kernel opens `/dev/console` for
it, and a root filesystem exported from a container image has no device nodes,
because a container runtime makes those. So init ran perfectly and said nothing,
and the kernel reported `Attempted to kill init! exitcode=0x00000100` — a
message about a shell exiting 1 that says nothing about why.

The init script gives each step a number and exits with it. `mkdir` failing is
21, the `devtmpfs` mount failing is 22, a missing `/dev/kmsg` is 23. The kernel
prints the number, and the number says which step. The test checks those numbers
do **not** appear, because each of them is a specific failure rather than a
general one.

The actual cause was one step earlier than any of them: `2>/dev/null` on the
first line, opening a file that does not exist yet.

### A VMM that never gives up cannot be tested

`hv_vcpu_run` blocks. A guest waiting for an interrupt a broken device never
raises sits in WFI, the framework does not return, and a deadline checked
between exits is never reached — **the loop doing the checking is not running**.
Checking the clock in that thread is checking it in the one place that is not
executing.

The first attempt did exactly that, and the poison for "never advance the used
ring" hung the test instead of failing it. `hv_vcpus_exit` from a second thread
is what forces the vCPU out, and with it the same poison fails in five seconds
with four named checks red.

### What the poisons say

| break | what goes red |
|---|---|
| never advance the used ring index | the guest never sees a request complete: no `/dev/vda`, no mount, no file |
| never raise the interrupt | the same, for the same reason one step later |

Both take the deadline rather than reporting anything, which is why the
deadline had to work before the poisons meant anything.

## What it does not do

*This section was wrong for a while, which is worse than it being short.* It
still said one virtio device, no port mapping and one inward path after all
three had stopped being true — and the rest of this file described the ports it
denied. A reader believes the document over the code, so a stale limit sends
the next person off to build something that is already here.

**Two virtio devices**: block (one queue) and vsock (three — rx, tx, event).
Indirect descriptors are not offered, so a driver cannot ask for them;
`VIRTIO_BLK_T_FLUSH` is answered as unsupported, which is honest for a device
with no write cache of its own. A request whose descriptor chain is not the
shape the specification requires is answered `VIRTIO_BLK_S_UNSUPP` rather than
guessed at. See `DESIGN-virtio.md`.

**No network interface**, and that one is load-bearing: the guest has no NIC at
all, by design. Everything in and out goes through virtio-vsock — published
ports (static and dynamic, both directions), the docker socket, the registry,
the proxy. It is also why there is no NAT: there is nothing to translate *to*,
and the three ways to change that are written down in the design notes rather
than half-built.

**No SMP and no console input.** PSCI answers `NOT_SUPPORTED` to everything
except the two calls that end the machine. One vCPU is not a performance
problem as far as anything here has measured: `docker run --rm alpine echo`
takes 418 ms against colima's 428, and `docker ps` 90 ms against 105.

System registers this VMM does not emulate read as zero and drop writes, which
is what every VMM does with the debug and trace registers a kernel touches on
the way up, and is also a place where a guest could be quietly misled.

## Two things the integration said that nothing before it could

**A root filesystem has to be a filesystem.** `pivot_root` refuses when the
current root is the initramfs — `mrun: pivot_root (errno 22)` — so a container
runtime cannot enter a container there at all. The daemon comes up, answers
every route, and creates containers that never run. `tools/mkrootfs.sh` builds
an ext4 image with `mke2fs -d`, which needs no privilege and no mounting, and
the guest boots `root=/dev/vda`.

**A guest with no clock hands out timestamps its clients parse.** Without an
RTC the guest starts at the epoch and `docker ps` says a container was created
56 years ago. There is a PL031 in the device tree now — the guest's AMBA bus
reads its identity registers, which is the check — but a stock kernel's driver
for it is a module that is not always installed, so the VMM also puts the time
on the kernel command line, where an unrecognised `key=value` reaches init as
an environment variable. Both numbers come from the same call, so they cannot
disagree.

## The client that hangs up

`docker compose up` abandons its `/events` connection when it exits. The guest
wrote to that stream a moment later, and **this process was killed by the
write**: the default action for `SIGPIPE` is to terminate, and a VMM that dies
because a client hung up takes the guest and every other connection with it.

From outside it looked exactly like the daemon *inside* the VM crashing — the
docker client reported `EOF` on a request that had been delivered in full, the
guest's console stopped, and the same sequence worked perfectly against the
same daemon over a plain unix socket. Every check that existed was green.
`test/stack.sh` now abandons a streaming connection on purpose and requires the
VMM to survive it and say so.

## Out, as well as in

The guest has no network interface at all — `vmnet_start_interface` returns
1001 for a process that is not root — so anything it needs from outside goes
over vsock too. `MVM_VSOCK_OUT` is the table for that direction:

```
MVM_VSOCK_OUT=5000=tcp:5000       a guest vsock connection to 5000 reaches
                                  127.0.0.1:5000 on this machine
```

and `mfwd out 5000 5000` in the guest listens on its own port 5000 and carries
what arrives there outward. So a daemon inside that knows nothing about any of
this connects to `127.0.0.1:5000` and reaches a registry running here:

```
$ docker -H unix://.build/docker.sock pull 127.0.0.1:5000/gate/alpine:v1
$ docker -H unix://.build/docker.sock run 127.0.0.1:5000/gate/alpine:v1 echo ok
ok
```

An address, not a name: there is no resolver in there, and the daemon says
which of the two things went wrong rather than "cannot fetch the manifest".

**Over TLS as well**, with the certificate verified against an authority the
guest carries. `test/stack.sh` asks all three states of that policy: a registry
it may speak to in the clear because it was named, one whose certificate checks
out, and one signed by an authority the guest does not have — which is refused,
and nothing from it reaches the store. The third needs its own authority, which
is why `tools/make-certs.sh` makes two.

## Out to somewhere it cannot name

```
$ docker -H unix://.build/docker.sock pull docker.io/library/alpine:latest
docker.io/library/alpine:latest
$ docker -H unix://.build/docker.sock run docker.io/library/alpine:latest echo ok
ok
```

That is Docker Hub, from a guest with **no network interface at all**. Every
byte went over one vsock route, to `mproxy` on this machine — a CONNECT proxy,
because a route table cannot follow a name it was never given, and Hub
redirects blobs to a content network whose host nobody knows when the machine
starts. Something that can be *told* the name can.

The proxy sees the name in the CONNECT line and **ciphertext after it**: the
guest's TLS is end to end with the real host, through the tunnel. That is the
whole difference between this and letting something on this side terminate TLS
on the guest's behalf. It binds the loopback, because what is on the other end
is a virtual machine asking to reach the internet.

A build's steps use it too — `docker build` with `RUN apk add` installs from
the package mirror, inside a machine with no network interface at all:

```
mproxy: registry-1.docker.io:443
mproxy: production.cloudfront.docker.com:443
mproxy: dl-cdn.alpinelinux.org:443
```

**A client has to speak `CONNECT`.** One that sends `GET http://host/path` is
asking this to fetch on its behalf, which is a different thing — and for
`https` it would mean this end doing the TLS. It is refused, and told why.

`test/hub.sh` is the check, and it needs the internet — it **fails rather than
skips** without it. Its oracle is not this stack: the config digest of the
arm64 manifest out of what `docker` downloaded for the same reference.

## Three programs and one number

A published port needs all three, and each knows something the others cannot:

| | what it does | what only it knows |
|---|---|---|
| `mports` (host) | watches the Docker API, asks for ports | which ports are published |
| `mvm` (host) | opens the host's TCP port, carries the stream | that there is a VM at all |
| `mfwd` (guest) | enters the container's namespace, connects | where the container is listening |

They agree on one number and nothing else: **the vsock port is the published
host port**. That convention needs no negotiation, because whoever opened the
host's end already chose it.

`MVM_CONTROL=<path>` is where the asking happens — one line in, one line out:

```
LISTEN 19090      -> ok listening 19090
UNLISTEN 19090    -> ok closed 19090
PORTS             -> ok 2 listeners
```

It is the VMM's socket, not the guest's, and it says nothing about containers:
it opens and closes host ports, and who wanted one is the caller's business.

## What is next

*Two things this section used to predict have happened, and neither happened
the way it said.* **A second machine** was expected to need the control socket
to say which machine it meant; every path turned out to be an argument or an
environment variable already, so the work was a check rather than a change —
`test/two.sh`. **`docker build`** was listed as absent; it builds, caches, and
writes one layer per step now.

*Two more have happened since.* **A single command to bring a machine up** was
listed here as the thing that was left; it is `tools/mvm`, and it now also
builds what a machine is made of and brings the way out with it. **The kernel**
was the piece a Mac alone could not obtain — `mvm build --kernel` takes it out
of a pinned package, and produces the same bytes the checks here have always
run against.

What is actually left is one choice and one refusal. The choice: **building the
kernel rather than unpacking somebody's**, which is worth having because the
modules that exist decide what the machine can do — the measurement that sets
it up is in the header of `tools/mkkernel.sh`. The refusal: **outbound NAT**,
which is not an omission but a request with no meaning on a machine that has no
upstream interface.

The language change this project expected never arrived. `Raw`, Mere's window
type for physical memory, was going to need a second source so that a virtio
queue in the guest's RAM could be read from Mere. It did not: the queue is read
by copying through the shim, and the measurement said what that costs — 4 KiB
at 1,659 MB/s once the disk is opened once rather than per request. Nothing in
this VMM has needed a change to the language.

## Two machines

```
sh test/two.sh          # after test/stack.sh, which builds what it reuses
```

Everything here assumed one: one VM, one docker socket, one control socket, one
set of published ports. The plan expected the second machine to need the
control socket to say *which* machine it meant — the first place where a number
is not enough and a name is.

It turned out not to. Every path is already an argument or an environment
variable, so a second machine is a second set of them. That is worth a **check**
rather than a claim: "it should work" and "it works" differ exactly there.

What the check judges is that the two are **separate**, because both answering
is not enough — one VM answering on two sockets would do that:

- a container made in one is not in the other, **by name**
- each published port reaches **its own** guest
- killing one leaves the other answering, on its port and on its socket

Poisoned by pointing the second client at the first socket, it fails five ways.

Two things it found about itself. The names have to be **unique per run**: the
disks keep whatever a previous run put in them, and a fixed name made the check
report that the second machine could see the first one's container — which it
could, from the run before. And the first version counted images instead of
naming them, which said the machines were sharing when they were not.

## An application, not a feature

```
sh test/app.sh          # after test/stack.sh, which builds what it reuses
```

Every other check here asks whether one thing works. This one asks the question
the whole project exists to answer: **can somebody put a small application on
this and use it**, the way they would with the thing it replaces? So it uses
the pieces together, in the order a person would:

| | |
|---|---|
| `compose up --build` | a service built from a Dockerfile in the context |
| two services | talking to each other by name |
| a named volume | that survives the container that wrote it |
| a published port | reached from macOS with `curl` |
| `docker exec` | to look inside while it runs |
| `docker cp` | to take something out |
| `compose down` | and nothing of the project left behind |

None of that was new when it was written. It found **four** defects anyway —
they are in mengd's README — and every one of them is a feature that works
alone and breaks in company. That is the shape of check that can see them, and
the reason this file exists.

Its own two lessons, both about not asserting on machine state: the disk image
carries whatever earlier runs left in it, so "no containers left" has to mean
**this project's** containers, and the HTTP server the test builds had to
compute its own `Content-Length` correctly before the port check meant
anything.

## When the client is the thing that broke

`mvm/test/app.sh` used to build its service through the VM with
`compose up --build`. It stopped working, and the daemon was innocent: on this
macOS docker CLI (29.8.0), **`DOCKER_BUILDKIT=0 docker build` hangs forever**,
with no output and no image — *against the real docker as well*. The same build
with BuildKit finishes instantly, and BuildKit wants `/session` and a builder
container, which is a different daemon feature.

Finding that took the same discipline as any other bug: the hang looked exactly
like a daemon that had stopped answering, and the proof that it was not came
from pointing the same command at a daemon nobody doubts.

So `hub.sh` now **asks first**, with a deadline, and skips by name:

```
== can this client drive a build at all ==
  SKIP  this client's legacy builder does not finish, against ANY daemon
  SKIP  the build-through-the-VM checks (the client, not the daemon)
```

A gate that cannot tell "the daemon is broken" from "the client is broken"
would hang, and a hang says nothing at all. The build path itself is still
checked where the client is Linux and the legacy builder works — that is
mengd's own gate, with COPY, ADD, the cache and one layer per step.

## Building one

```
sh tools/mvm build --kernel     # the guest's kernel, from a pinned package
MERE=… MENGD_SRC=… MRUN_SRC=… sh tools/mvm build
```

**`build --kernel` is how a machine that has only macOS gets a Linux kernel.**
Until now the answer was "gunzip `/boot/vmlinuz` on a Linux box that runs that
kernel", which means somebody with only a Mac cannot start. It opens
`linux-image-6.8.0-117-generic` and `linux-modules-…` (both, because the kernel
package carries no modules) inside a container, unpacks the eight modules —
each one is a capability — and writes `.build/kernel.lock` with the digest of
everything it used.

The pin is exact, and that is the point: the Image it produces has sha256
`ce3cccaf…450e`, **byte for byte the kernel every check here has been green
against**. Obtaining it this way is not a new kernel to re-validate.

**`build --kernel --from-source` builds one instead**, from a kernel.org
tarball pinned by digest, with `kernel/config.fragment` on top of arm64
`defconfig`. That fragment is **nine lines** — measured, not guessed: every
other thing this machine needs, `defconfig` already has. What the nine buy is
that **there are no modules at all**: no eight files beside the Image, no
version that has to match it, no `insmod` at boot. 287 seconds on six cores,
and an Image of 44.5 MB against the package's 59.

It is not the default. The package path produces an Image whose sha256 is
`ce3cccaf…450e` every time — an external oracle, and the kernel every check
here has been green against — while a kernel build stamps itself and is not
byte-reproducible. Both are checked; `KERNEL_SOURCE=1 sh test/build.sh` runs
the second.

**Finding a capability is not finding a module.** The guest used to report what
it could do by looking in `/sys/module`, which is right for four of these and
wrong for the one that matters: a built-in `veth` leaves nothing there at all,
while `bridge`, `overlay` and `vsock` do. So a machine whose containers were
reaching each other perfectly announced "no bridge/veth: containers will have
no way to reach each other". It makes a veth pair and deletes it now, and
mounts an overlay and unmounts it — the capability, asked in its own terms.

Alpine's `linux-virt` is half the download and was measured and set aside for
one reason: `CONFIG_VIRTIO_MMIO=m`, `CONFIG_VIRTIO_BLK=m`, `CONFIG_EXT4_FS=m`.
A kernel whose virtio and ext4 are modules cannot mount `root=/dev/vda` without
an initramfs to load them first. Ubuntu's are all `=y`, which is exactly why
this VMM boots with no initrd at all. (Its `vmlinuz` is also an EFI zboot
container — `MZ\0\0zimg`, a gzip payload at a stated offset — so it is not a
`gunzip` either. Both facts belong to whoever builds their own.)

**`build` makes the rest**: the host's four (`mvm-boot`, `mkdtb`, `mports`,
`mproxy`, the first two signed), the guest's three (`mengd`, `mrun`, `mfwd`,
static), and the initramfs that makes a disk. The guest's land in
`.build/guest/`, so **a machine can be started from this directory alone** —
`MENGD_SRC` and `MRUN_SRC` are how they get built, not how they get used. It
does not use `docker build`: the legacy builder in the Docker CLI on macOS
hangs against any daemon, real ones included, and a tool that hangs while
building itself is worse than a slow one.

## The guest makes its own disk

Everything about shipping this was easy except one thing. 25 MB compressed; an
adhoc signature that survives a tarball, since it carries no identity. (And the
signature is not what to check: the linker on arm64 macOS ad-hoc signs
everything, so removing the `codesign` step leaves a binary that is still
"signed" and has lost the **entitlement** — that is the half that can go
missing, and the half Hypervisor.framework asks for.) And then the root
filesystem was built by `docker create` for the tree and a container running
`mke2fs` for the filesystem — so **a tool that replaces docker needed docker to
install**, on a system that has nothing else that writes ext4.

It does not have to be built on the host. The guest has a kernel with ext4 in
it, so the host only makes a file of the right size — that is `dd` — and one
boot of `initrd-format.gz` does the rest: `mke2fs`, copy its own userspace in,
install `/sbin/init` and the payload, power off. About **four seconds, once**.

**It powers off rather than `switch_root`.** The running path — `root=/dev/vda
init=/sbin/init` — is the one every check here is green against, and a second
way to reach it would be a second thing to keep working.

**A rebuilt tool installs itself.** The initramfs carries the daemon and the
runtime, and `start` records its digest beside the disk; when they differ it
boots the formatter in `refresh` mode, which copies the programs in and leaves
the filesystem alone. Before that, upgrading meant deleting the machine. The
initramfs is built from a pipe, so gzip stores no timestamp and the same inputs
give the same bytes — which is what makes "has this changed" a comparison
rather than a guess, and what stops an ordinary restart from doing any of this.

`tools/mkrootfs.sh` is still here and still needs docker. It builds a disk from
a particular image with a particular payload, which several checks want before
there is a machine; it is not how a machine is installed any more.

**What a person needs: macOS on Apple silicon.** Not docker, not Mere. A
downloaded release is quarantined, and a quarantined VMM does not fail — it
**hangs**, with a dialog somewhere. `doctor` names it before `start` can reach
it. (`spctl` is no use as the check: it reports `rejected` for every adhoc
signature, including one that runs perfectly.)

`test/build.sh` is the check, and its last section is the point: it takes
docker off the `PATH` and starts a machine.

## Starting one

```
sh tools/mvm start [--name N] [--disk-size MiB] [-p HOST:GUEST] [--proxy-port P]
sh tools/mvm status
sh tools/mvm stop
sh tools/mvm doctor
```

Everything it does was already possible; it was six pieces assembled by hand,
and that is the difference between "the stack works" and "somebody uses it".
State lives in one directory per machine (`$MVM_HOME/<name>`, default
`~/.mvm/<name>`) — the second machine is not a special case, since two of them
already run side by side.

**`doctor` names what is missing**, one line each: the kernel, the modules, the
guest's daemon and runtime, the signature Hypervisor.framework requires. "It
did not start" is not one of those sentences.

**A stop has to be a stop.** Killing the VMM loses whatever the guest has not
committed yet: a machine stopped a second after a container was created came
back *without it*. `stop` asks the daemon to flush and power the machine off —
`POST /_shutdown`, spelt with an underscore like `/_ping` so it cannot be
mistaken for part of the Docker API — and the VMM sees the same PSCI
`SYSTEM_OFF` a guest sends when its init finishes. Only if that does not happen
does it signal, and then escalate.

**No deadline.** `MENGD_SECONDS` and `MVM_TIMEOUT_MS` were 180 s and 20 s by
default, which was right while every run of this was a test and wrong the
moment a person started one. Both are opt-in now, and the checks name the
number they want.

**cgroup v2 is mounted in the guest.** Without it a container has no cgroup of
its own — no limit, nothing to measure, nothing to freeze — and the runtime
said so into the container's own stderr, where a person running `docker run`
saw a warning about the machine instead of their output.

**It brings the way out with it.** This guest has no network interface at all,
so everything that leaves goes through a proxy on this side; that was always
possible and never automatic — `test/hub.sh` started `mproxy` by hand and
passed three environment variables. `start` now starts it, on the first free
port from 3128 upward, and tells the guest three agreeing facts: the vsock port
that carries it, the forwarder to put on `0.0.0.0` inside, and the address the
daemon should use. It takes **its own** port rather than reusing whatever is
already on 3128 — that is squid's port, and a machine that found a stranger
there would send everything inside it to that stranger.

`test/lifecycle.sh` is the check: start, put things in, stop, start again, and
ask what is there. It is the first check here that cares about **what
survives** — every other one builds a machine, uses it and throws it away.
Poisoned by killing the VMM without asking, five of its checks go red; poisoned
by skipping the daemon's reconciliation, the container comes back claiming to
be running.
