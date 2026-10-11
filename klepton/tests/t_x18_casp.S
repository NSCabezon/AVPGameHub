// Templates for tests/t_x18_casp.c. Never called in place: the test copies
// each [f, f_end) into a fresh mapping and runs kl_x18_emit over it first.
// Shapes adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// tests/t_x18_shapes.S.
    .text
    .p2align 2

// void f_casp(uint64_t mem[2] (16-byte aligned), uint64_t out[4],
//             uint64_t exp_lo, uint64_t exp_hi, uint64_t new_lo, uint64_t new_hi)
// First casp: Rs pair = x18:x19 (expected -> receives the old value), Rt = x4:x5.
// Second: Rs = x6:x7, Rt pair = x18:x19 (the value written back).
    .globl _f_casp
_f_casp:
    stp  x19, x20, [sp, #-16]!
    mov  x18, x2
    mov  x19, x3
    mov  x9, #20000                 // spin: the kernel zeroes x18 on every
2:  subs x9, x9, #1                 // exception return, so a value kept in the
    b.ne 2b                         // architectural register would not survive
    caspal x18, x19, x4, x5, [x0]
    str  x18, [x1]
    str  x19, [x1, #8]
    mov  x6, x4
    mov  x7, x5
    mov  x18, x2
    mov  x19, x3
    caspal x6, x7, x18, x19, [x0]
    str  x6, [x1, #16]
    str  x7, [x1, #24]
    ldp  x19, x20, [sp], #16
    ret
    .globl _f_casp_end
_f_casp_end:

// uint64_t f_casp_rn(uint64_t mem[2], uint64_t out[2], exp_lo, exp_hi, new_lo, new_hi)
// x18 as the BASE address only: an ordinary single-register substitution.
    .globl _f_casp_rn
_f_casp_rn:
    mov  x18, x0
    mov  x9, #20000
2:  subs x9, x9, #1
    b.ne 2b
    casp x2, x3, x4, x5, [x18]
    stp  x2, x3, [x1]
    ret
    .globl _f_casp_rn_end
_f_casp_rn_end:
