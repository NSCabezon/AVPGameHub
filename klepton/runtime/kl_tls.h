// ELF thread-local storage for guests that carry a PT_TLS segment — the glibc
// guests (Half-Life: Alyx), whose libraries reach their __thread variables
// through R_AARCH64_TLSDESC and R_AARCH64_TLS_TPREL64 rather than through
// bionic's emutls. See kl_tls.c for the whole design; in short:
//
//   - the guest's thread pointer is Darwin's TSD base (klepton rewrites every
//     `mrs tpidr_el0` to `mrs tpidrro_el0`), so "an offset from TP" is an
//     offset from a structure we do not own and cannot grow;
//   - TLSDESC is answered DYNAMICALLY: the descriptor's resolver returns
//     (this thread's block for the module + offset) - TP, computed per call,
//     with a per-thread DTV kept in a pthread key;
//   - TLS_TPREL64 (initial-exec) needs a CONSTANT offset, so a module that uses
//     it gets its block inside a run of pthread keys we own — the TSD array is
//     the only per-thread memory at a fixed distance from TP.
#ifndef KL_TLS_H
#define KL_TLS_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// A TLS module: one per guest image with a PT_TLS segment. `init` is the
// RELOCATED template (.tdata) inside the mapped image; memsz - filesz is .tbss.
// Returns the module id (>= 1), or 0 if the module table is full.
size_t kl_tls_register_module(const char *path, const void *init, size_t filesz,
                              size_t memsz, size_t align);

// Give a module a block at a fixed TP offset (the static area), because some
// relocation needs one (TLS_TPREL64). Idempotent. Fails — by name, in `err` —
// when the area is full, the module's alignment is coarser than TP's, or a
// thread already holds a dynamic block for it (the two would disagree).
int     kl_tls_make_static(size_t modid, char *err, size_t cap);
// ...and that fixed offset, valid once kl_tls_make_static succeeded.
int64_t kl_tls_static_offset(size_t modid);

// The argument a TLSDESC descriptor carries in its second word. The layout is
// read by kl_tlsdesc.S — keep the two in step. modid 0 means "unresolved": the
// resolver then fails BY NAME the first time the guest touches the variable.
typedef struct {
    uint64_t    modid;
    uint64_t    off;        // st_value + r_addend, inside the module's block
    const char *name;       // for the unresolved case and for reports
} kl_tls_arg;

const kl_tls_arg *kl_tls_desc_arg(size_t modid, uint64_t off, const char *name);
// The resolver every descriptor points at (kl_tlsdesc.S).
void kl_tlsdesc_dynamic(void);

// Copy the static-area templates into this thread's TSD run. Called from
// kl_thread_init and from the resolver's slow path; cheap when already done.
void kl_tls_thread_init(void);

// The resolver's C half: this thread's address for `a`. Never returns for an
// unresolved descriptor.
void *kl_tls_get_addr_slow(const kl_tls_arg *a);

void kl_tls_report(FILE *out);

#endif
