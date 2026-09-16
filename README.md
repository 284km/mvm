# mvm

A virtual machine monitor in [Mere](https://merelang.org/), on Apple's
Hypervisor.framework. **It runs one instruction so far.**

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

## What is next

In order, each judged by whether the guest said something rather than by
whether a structure parsed:

1. the AArch64 Linux boot protocol — image header, DTB, PSCI, GICv3, the
   generic timer, WFI — until **the kernel panics**, which is the correct
   outcome when it has no devices yet
2. PL011 and virtio-console, until **init speaks**
3. virtio-blk, so it boots from a root filesystem
4. virtio-net and virtio-vsock

Step 2 is where a comparable project in another language
([kotoba-lang/vmm](https://github.com/kotoba-lang/vmm)) has not yet arrived, so
the judgement for step 1 is deliberately "the kernel panics" — a panic means the
CPU, the memory, the interrupts and the timer are all working, and it is the
first thing a guest says that could not have been faked.

Reading guest memory from Mere rather than through the shim will want `Raw`, the
language's existing window type for physical memory, which today has exactly one
source: the argument `mere -rv --bare` hands a bare-metal program. Giving it a
second source is a language change and is deliberately not part of this step.
