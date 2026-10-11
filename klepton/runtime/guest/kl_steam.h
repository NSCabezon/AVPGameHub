// A stand-in Steam client (kl_steam.c): the libsteam_api entry points the
// engine imports (SteamAPI_*, SteamInternal_*, SteamGameServer_*), answered
// with C++ interface objects whose vtables follow the Steamworks SDK. Identity,
// ownership, stats/achievements and "playing" come from the user's real Steam
// account through the Steam bridge (kl_steam_bridge.h) when it answers, else
// from a stub (logged-on fake user, the target's app owned). Real loopback
// ISteamNetworkingSockets either way. NULL for any other name. Installed on the glibc door
// (kl_glibc_shim.c, Alyx) and on the bionic one (kl_shim.c, Metro Awakening's
// Android build, which links libsteam_api.so).
// KL_STEAM_STUB=0 leaves them to the guest's own libsteam_api.
#ifndef KL_STEAM_H
#define KL_STEAM_H
void *kl_steam_lookup(const char *name);
#endif
