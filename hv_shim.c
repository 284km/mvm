/* hv_shim.c — Hypervisor.framework, behind a flat integer API.
 *
 * WHY A SHIM AT ALL, when hv_* is already a C API: the FFI boundary's `int` is
 * C's `int`, 32 bits. A guest physical address fits in that only while the
 * guest is small, and a register VALUE never does. So 64-bit quantities cross
 * as hex strings, which are explicit, printable, and wrong in a way that shows
 * up immediately rather than as a silently truncated address.
 *
 * The vCPU belongs to the thread that created it, so every call here has to
 * happen on one thread. The caller keeps to that; nothing is checked.
 */
#include <Hypervisor/Hypervisor.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static hv_vcpu_t VCPU;
static hv_vcpu_exit_t *EXIT;
static void *RAM;            /* the host mapping backing the guest's memory */
static uint64_t RAM_GPA;
static size_t RAM_SIZE;
static _Thread_local char strbuf[128];

static uint64_t hex64(const char *s) {
    if (!s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    return (uint64_t)strtoull(s, NULL, 16);
}
static const char *put64(uint64_t v) { snprintf(strbuf, sizeof strbuf, "0x%" PRIx64, v); return strbuf; }

/* Create the VM. 0 on success, the hv_return_t otherwise -- the number Apple's
 * header documents, not a -1 that loses which of eight things went wrong. */
int hv_up(void) { return (int)hv_vm_create(NULL); }

/* Allocate host memory and map it as the guest's physical memory at `gpa`. */
int hv_map(const char *gpa_hex, int size) {
    if (RAM) return -2;
    RAM_SIZE = (size_t)size;
    RAM_GPA = hex64(gpa_hex);
    // No PROT_EXEC on the HOST mapping. On Apple Silicon an anonymous
    // executable mapping needs the JIT entitlement, and this one does not need
    // to be executable at all: the guest's permission to execute comes from
    // HV_MEMORY_EXEC in hv_vm_map, which is a property of the guest's view.
    RAM = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE,
               MAP_ANON | MAP_PRIVATE, -1, 0);
    if (RAM == MAP_FAILED) { RAM = NULL; return -3; }
    memset(RAM, 0, RAM_SIZE);
    return (int)hv_vm_map(RAM, RAM_GPA, RAM_SIZE,
                          HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
}

static void *at(uint64_t gpa, size_t len) {
    if (!RAM || gpa < RAM_GPA || gpa + len > RAM_GPA + RAM_SIZE) return NULL;
    return (char *)RAM + (gpa - RAM_GPA);
}

int hv_poke32(const char *gpa_hex, int val) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return -1;
    uint32_t v = (uint32_t)val;
    memcpy(p, &v, 4);
    return 0;
}
int hv_peek32(const char *gpa_hex) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return 0;
    uint32_t v; memcpy(&v, p, 4); return (int)v;
}

int hv_vcpu_new(void) { return (int)hv_vcpu_create(&VCPU, &EXIT, NULL); }

/* Registers by NUMBER: 0-30 are X0-X30, and PC and CPSR have their own calls,
 * because their enum values are not in that range and inventing a numbering
 * here would be a second mapping to get wrong. */
int hv_set_x(int n, const char *val_hex) {
    if (n < 0 || n > 30) return -1;
    return (int)hv_vcpu_set_reg(VCPU, (hv_reg_t)(HV_REG_X0 + n), hex64(val_hex));
}
const char *hv_get_x(int n) {
    uint64_t v = 0;
    if (n >= 0 && n <= 30) hv_vcpu_get_reg(VCPU, (hv_reg_t)(HV_REG_X0 + n), &v);
    return put64(v);
}
int hv_set_pc(const char *val_hex) { return (int)hv_vcpu_set_reg(VCPU, HV_REG_PC, hex64(val_hex)); }
const char *hv_get_pc(void) { uint64_t v = 0; hv_vcpu_get_reg(VCPU, HV_REG_PC, &v); return put64(v); }

/* EL1h with interrupts masked. 0x3c5 is what a reset vector starts in, and
 * setting it explicitly is required: the value read back before any write is
 * the same number but the vCPU starts at EL0 without it. */
int hv_set_cpsr(const char *val_hex) { return (int)hv_vcpu_set_reg(VCPU, HV_REG_CPSR, hex64(val_hex)); }

int hv_run(void) { return (int)hv_vcpu_run(VCPU); }

int hv_exit_reason(void) { return EXIT ? (int)EXIT->reason : -1; }
const char *hv_exit_syndrome(void) { return put64(EXIT ? EXIT->exception.syndrome : 0); }
const char *hv_exit_va(void) { return put64(EXIT ? EXIT->exception.virtual_address : 0); }
/* EC is the top six bits of the syndrome: which KIND of exception this was. */
int hv_exit_ec(void) { return EXIT ? (int)((EXIT->exception.syndrome >> 26) & 0x3f) : -1; }

/* ---- the GIC ------------------------------------------------------------ */
/*
 * macOS provides the interrupt controller: hv_gic_create takes a config with
 * the distributor and redistributor base addresses and the framework emulates
 * GICv3 behind them. The alternative is several thousand lines of register
 * emulation, so the addresses in the device tree are chosen to match what is
 * passed here -- one file decides both, which is why the tree is generated
 * rather than compiled from a separate source.
 */
int hv_gic_up(const char *dist_hex, const char *redist_hex) {
    hv_gic_config_t cfg = hv_gic_config_create();
    if (!cfg) return -1;
    hv_return_t r = hv_gic_config_set_distributor_base(cfg, hex64(dist_hex));
    if (r != HV_SUCCESS) return (int)r;
    r = hv_gic_config_set_redistributor_base(cfg, hex64(redist_hex));
    if (r != HV_SUCCESS) return (int)r;
    return (int)hv_gic_create(cfg);
}

/* ---- loading ------------------------------------------------------------ */
long long hv_load_file(const char *path, const char *gpa_hex) {
    uint64_t gpa = hex64(gpa_hex);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    void *p = at(gpa, (size_t)sz);
    if (!p) { fclose(f); return -2; }
    size_t got = fread(p, 1, (size_t)sz, f);
    fclose(f);
    return (long long)got;
}

/* ---- decoding an exit --------------------------------------------------- */
/* The instruction-specific syndrome, which for a data abort says which
 * register, how wide, and which direction. */
int hv_exit_iss(void) { return EXIT ? (int)(EXIT->exception.syndrome & 0x1ffffff) : 0; }

/* Step over the instruction that faulted. AArch64 instructions are four bytes;
 * a fault that is not retried has to be stepped past or the guest runs it
 * again forever. */
int hv_advance_pc(void) {
    uint64_t pc = 0;
    hv_return_t r = hv_vcpu_get_reg(VCPU, HV_REG_PC, &pc);
    if (r != HV_SUCCESS) return (int)r;
    return (int)hv_vcpu_set_reg(VCPU, HV_REG_PC, pc + 4);
}

/* HVF reports the virtual timer becoming active; masking it and continuing is
 * what a VMM with nothing else to do about it does. */
int hv_mask_vtimer(void) { return (int)hv_vcpu_set_vtimer_mask(VCPU, true); }

/* Sys regs by name, so a caller does not carry Apple's enum values. */
int hv_set_sys(const char *name, const char *val_hex) {
    hv_sys_reg_t r;
    if (!strcmp(name, "CNTV_CTL_EL0")) r = HV_SYS_REG_CNTV_CTL_EL0;
    else if (!strcmp(name, "MIDR_EL1")) r = HV_SYS_REG_MIDR_EL1;
    // The framework places a vCPU's redistributor from its AFFINITY, and the
    // header says so: hv_gic_get_redistributor_base "must be called after the
    // affinity of the given vCPU has been set in its MPIDR_EL1 register".
    // Without that it answers HV_BAD_ARGUMENT and the redistributor is not
    // anywhere -- which the guest discovers as a data abort in the middle of
    // GIC initialisation.
    else if (!strcmp(name, "MPIDR_EL1")) r = HV_SYS_REG_MPIDR_EL1;
    else return -1;
    return (int)hv_vcpu_set_sys_reg(VCPU, r, hex64(val_hex));
}

/* The guest's PHYSICAL address for a fault. virtual_address is the address in
 * the guest's own page tables, which is where the kernel mapped the device --
 * not where the device is. Dispatching on it sends every MMIO access to
 * "unhandled", which is what it did. */
const char *hv_exit_pa(void) { return put64(EXIT ? EXIT->exception.physical_address : 0); }

/* ---- the GIC's own geometry -------------------------------------------- */
/*
 * Ask the framework how big its distributor and redistributor windows are,
 * rather than writing 0x10000 and 0x100000 into a device tree and hoping. The
 * kernel probes to the end of the window it is told about; a window described
 * larger than the one the framework answers for produces a data abort in the
 * middle of GIC initialisation, at an address that looks arbitrary
 * (0x80affe8 -- the PIDR2 register at the end of a frame that was not there).
 */
long long hv_gic_dist_size(void) { size_t v = 0; return hv_gic_get_distributor_size(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_size(void) { size_t v = 0; return hv_gic_get_redistributor_size(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_dist_align(void) { size_t v = 0; return hv_gic_get_distributor_base_alignment(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_align(void) { size_t v = 0; return hv_gic_get_redistributor_base_alignment(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_region_size(void) { size_t v = 0; return hv_gic_get_redistributor_region_size(&v) == HV_SUCCESS ? (long long)v : -1; }

/* Where the framework actually put this vCPU's redistributor. It assigns them
 * itself from the region the config named; the device tree has to describe
 * where they ARE, not where the region started. */
const char *hv_gic_redist_base_of_vcpu(void) {
    hv_ipa_t b = 0;
    if (hv_gic_get_redistributor_base(VCPU, &b) != HV_SUCCESS) return put64(0);
    return put64(b);
}
