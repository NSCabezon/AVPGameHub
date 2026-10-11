// The glibc door's SDL video seam (kl_glibc_sdl.c): our answer for an SDL2
// video/window/Vulkan/event entry point, or NULL to leave it to the guest's SDL.
#ifndef KL_GLIBC_SDL_H
#define KL_GLIBC_SDL_H
void *kl_glibc_sdl_lookup(const char *name);
#endif
