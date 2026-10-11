// The two trampolines behind kl_steam.c's FLAT API (Steamworks.NET).
//
// Each flat name the guest dlsyms is a pre-built TRACE cell (kl_stub_cells.S,
// handed out by kl_trace_stub): it arrives here with the guest's arguments
// untouched in x0-x7 / q0-q7 / x8 and its row from kl_steam.c in x16. Nothing
// here is generated at runtime, so this is as legal on visionOS as any other
// signed code.
//
// kl_steam_flat_tramp: x0 is the interface object (`self`). Ask
//   kl_steam_flat_target(row, self) which vtable slot the row names for that
//   object's version, restore every argument register, and tail-branch there —
//   the implementation sees exactly the call the guest made, `this` included.
//
// kl_steam_accessor_tramp: an accessor (`SteamAPI_SteamUser_v023()`) takes no
//   arguments and returns the interface; x16 is the version string, so it is
//   iface(version) with the string moved into x0.
//
// Frame layout copied from kl_gl_trace.S: fp/lr, x0-x8 + x16, q0-q7 — x8 is the
// indirect-result register (a flat call that returns a struct in memory passes
// its destination there) and q0-q7 carry float arguments (SetStatFloat).

#if defined(__aarch64__)

.text
.align 4

.globl _kl_steam_flat_tramp
_kl_steam_flat_tramp:
    stp     x29, x30, [sp, #-224]!
    mov     x29, sp

    stp     x0,  x1,  [sp, #16]
    stp     x2,  x3,  [sp, #32]
    stp     x4,  x5,  [sp, #48]
    stp     x6,  x7,  [sp, #64]
    stp     x8,  x16, [sp, #80]
    stp     q0,  q1,  [sp, #96]
    stp     q2,  q3,  [sp, #128]
    stp     q4,  q5,  [sp, #160]
    stp     q6,  q7,  [sp, #192]

    mov     x1, x0                   // self
    mov     x0, x16                  // the row
    bl      _kl_steam_flat_target
    mov     x17, x0                  // the implementation

    ldp     q6,  q7,  [sp, #192]
    ldp     q4,  q5,  [sp, #160]
    ldp     q2,  q3,  [sp, #128]
    ldp     q0,  q1,  [sp, #96]
    ldp     x8,  x16, [sp, #80]
    ldp     x6,  x7,  [sp, #64]
    ldp     x4,  x5,  [sp, #48]
    ldp     x2,  x3,  [sp, #32]
    ldp     x0,  x1,  [sp, #16]

    ldp     x29, x30, [sp], #224     // close the frame first: stack arguments
                                     // must be where the guest left them
    br      x17

.globl _kl_steam_accessor_tramp
_kl_steam_accessor_tramp:
    mov     x0, x16
    b       _kl_steam_accessor_target

#endif
