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

One virtio device and one queue. Indirect descriptors are not offered, so a
driver cannot ask for them; `VIRTIO_BLK_T_FLUSH` is answered as unsupported,
which is honest for a device with no write cache of its own. A request whose
descriptor chain is not the shape the specification requires is answered
`VIRTIO_BLK_S_UNSUPP` rather than guessed at. See `DESIGN-virtio.md`.

No network and no SMP, and no console input: PSCI answers `NOT_SUPPORTED` to
everything except the two calls that end the machine. There *is* a way in and out of
the VM — virtio-vsock, whose host end is a unix socket, in both directions —
but no port mapping: one inward path to one guest port. See `DESIGN-vsock.md`. System registers this VMM does not emulate read as zero
and drop writes, which is what every VMM does with the debug and trace
registers a kernel touches on the way up, and is also a place where a guest
could be quietly misled.

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

## What is next

**Ports, and more than one thing at a time.** Every inward connection goes to
one guest port, there are eight streams, and there is no port mapping, so a
container that listens is not reachable from the host. `docker compose up` is
the next real user.

The language change this project expected never arrived. `Raw`, Mere's window
type for physical memory, was going to need a second source so that a virtio
queue in the guest's RAM could be read from Mere. It did not: the queue is read
by copying through the shim, and the measurement said what that costs — 4 KiB
at 1,659 MB/s once the disk is opened once rather than per request. Nothing in
this VMM has needed a change to the language.
