// The TLSDESC resolver — see kl_tls.c for the design, and kl_tls.h for the
// kl_tls_arg layout this reads.
//
// CONTRACT (aarch64 TLS descriptors)
//
//   in:  x0  = address of the descriptor { this function, kl_tls_arg * }
//        x30 = return address (the guest's blr wrote it)
//   out: x0  = &var - TP for the CURRENT thread, where TP is what the guest's
//              (rewritten) `mrs tpidrro_el0` reads
//   preserves EVERY other register: x1-x29, sp, and all of v0-v31. Only x0 and
//   NZCV change. The call site does not treat the blr as a call — the compiler
//   keeps live values in caller-saved registers across it — so the usual
//   AAPCS64 clobber set is NOT available here, and the slow path has to save
//   it all before it may call C.
//
// FAST PATH: this thread's dtv (tsd[kl_tls_dtv_key]) exists, is long enough,
// and already holds the module's block. Uses x1-x4, saved on the stack.

#if defined(__aarch64__)

.text
.align 4
.globl _kl_tlsdesc_dynamic

_kl_tlsdesc_dynamic:
    stp  x1, x2, [sp, #-32]!
    stp  x3, x4, [sp, #16]
    ldr  x1, [x0, #8]                   // x1 = kl_tls_arg *
    adrp x2, _kl_tls_dtv_key@PAGE
    ldr  x2, [x2, _kl_tls_dtv_key@PAGEOFF]
    mrs  x3, tpidrro_el0
    ldr  x2, [x3, x2, lsl #3]           // x2 = dtv = tsd[key]
    cbz  x2, 1f
    ldr  x4, [x1]                       // modid
    ldr  x3, [x2]                       // dtv[0] = slots
    cmp  x4, x3
    b.hs 1f                             // (modid 0 is never filled: slow path names it)
    add  x2, x2, #8
    ldr  x4, [x2, x4, lsl #3]           // block
    cbz  x4, 1f
    ldr  x1, [x1, #8]                   // offset inside the block
    add  x4, x4, x1
    mrs  x3, tpidrro_el0
    sub  x0, x4, x3
    ldp  x3, x4, [sp, #16]
    ldp  x1, x2, [sp], #32
    ret

    // SLOW PATH: back to the entry state (x0 is still the descriptor — the
    // fast path only writes it on success), then save everything C may
    // clobber.
1:  ldp  x3, x4, [sp, #16]
    ldp  x1, x2, [sp], #32
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    sub  sp, sp, #(144 + 512)
    stp  x1,  x2,  [sp, #0]
    stp  x3,  x4,  [sp, #16]
    stp  x5,  x6,  [sp, #32]
    stp  x7,  x8,  [sp, #48]
    stp  x9,  x10, [sp, #64]
    stp  x11, x12, [sp, #80]
    stp  x13, x14, [sp, #96]
    stp  x15, x16, [sp, #112]
    stp  x17, x18, [sp, #128]
    add  x1, sp, #144
    stp  q0,  q1,  [x1, #0]
    stp  q2,  q3,  [x1, #32]
    stp  q4,  q5,  [x1, #64]
    stp  q6,  q7,  [x1, #96]
    stp  q8,  q9,  [x1, #128]
    stp  q10, q11, [x1, #160]
    stp  q12, q13, [x1, #192]
    stp  q14, q15, [x1, #224]
    stp  q16, q17, [x1, #256]
    stp  q18, q19, [x1, #288]
    stp  q20, q21, [x1, #320]
    stp  q22, q23, [x1, #352]
    stp  q24, q25, [x1, #384]
    stp  q26, q27, [x1, #416]
    stp  q28, q29, [x1, #448]
    stp  q30, q31, [x1, #480]
    ldr  x0, [x0, #8]                   // the kl_tls_arg
    bl   _kl_tls_get_addr_slow          // -> absolute address
    mrs  x1, tpidrro_el0
    sub  x0, x0, x1
    add  x1, sp, #144
    ldp  q0,  q1,  [x1, #0]
    ldp  q2,  q3,  [x1, #32]
    ldp  q4,  q5,  [x1, #64]
    ldp  q6,  q7,  [x1, #96]
    ldp  q8,  q9,  [x1, #128]
    ldp  q10, q11, [x1, #160]
    ldp  q12, q13, [x1, #192]
    ldp  q14, q15, [x1, #224]
    ldp  q16, q17, [x1, #256]
    ldp  q18, q19, [x1, #288]
    ldp  q20, q21, [x1, #320]
    ldp  q22, q23, [x1, #352]
    ldp  q24, q25, [x1, #384]
    ldp  q26, q27, [x1, #416]
    ldp  q28, q29, [x1, #448]
    ldp  q30, q31, [x1, #480]
    ldp  x17, x18, [sp, #128]
    ldp  x15, x16, [sp, #112]
    ldp  x13, x14, [sp, #96]
    ldp  x11, x12, [sp, #80]
    ldp  x9,  x10, [sp, #64]
    ldp  x7,  x8,  [sp, #48]
    ldp  x5,  x6,  [sp, #32]
    ldp  x3,  x4,  [sp, #16]
    ldp  x1,  x2,  [sp, #0]
    add  sp, sp, #(144 + 512)
    ldp  x29, x30, [sp], #16
    ret

#endif
