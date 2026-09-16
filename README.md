# mvm

A virtual machine monitor in [Mere](https://merelang.org/), on Apple's
Hypervisor.framework. **A real Linux kernel boots on it and runs userspace** —
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

Without an initramfs it boots the same way and panics because there is no root
filesystem, which is the one thing this VMM does not provide yet.

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

## What it does not do

No block device: userspace here is an initramfs, which the kernel unpacks
into memory. A root filesystem on a disk needs virtio-blk, which is next. No network, no console
input, no SMP: PSCI answers `NOT_SUPPORTED` to everything except the two calls
that end the machine. System registers this VMM does not emulate read as zero
and drop writes, which is what every VMM does with the debug and trace
registers a kernel touches on the way up, and is also a place where a guest
could be quietly misled.

## What is next

**virtio-blk**, so there is a root filesystem and the boot gets past the panic
to an init process. That is the step where guest memory has to be read from
Mere rather than through the shim — a virtio queue is descriptors in the
guest's RAM — and it is the first thing in this whole project that wants a
language change: `Raw`, Mere's window type for physical memory, has exactly one
source today, the argument `mere -rv --bare` hands a bare-metal program. Giving
it a second one is a change to what the language guarantees, so it gets designed
before it gets written.
