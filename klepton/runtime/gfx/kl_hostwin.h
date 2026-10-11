// The host (macOS, SDL3) window backend for flat guests — see kl_hostwin.c and
// kl_flatwin.h. Host-only: linked by m_boot alone. NULL in a build without SDL3.
#ifndef KL_HOSTWIN_H
#define KL_HOSTWIN_H
#include "kl_flatwin.h"
const kl_flatwin_backend *kl_hostwin_backend(void);
#endif
