// The Steam bridge: how the Steamworks stand-in (kl_steam.c) reaches the
// user's REAL Steam account.
//
// The account itself lives outside the runtime, in SteamDepot's
// SteamBridgeService (a logged-on Steam session plus an offline cache). The
// stand-in talks to it in newline-delimited JSON, one request and one response
// line at a time, every response carrying "ok":
//
//   {"op":"hello","app":N}    -> {"ok":true,"steamid":"<u64>","name":"..","owned":bool,"offline":bool}
//   {"op":"stats","app":N,"lang":".."}
//                             -> {"ok":true,"offline":bool,"stats":{..},"achievements":{..}}
//                                (each achievement may carry "display":{name,desc,icon,icon_gray,hidden})
//   {"op":"store","app":N,"stats":{..},"achievements":{..},"dry_run":bool,"lang":".."}
//                             -> {"ok":true,"queued":bool,"stored":bool,"unlocked":[{api,name,desc?,icon?}]}
//   {"op":"icon","url":"https://.."} -> {"ok":true,"path":"<local cached file>"}
//   {"op":"playing","app":N,"on":bool} -> {"ok":true}
//
// TWO TRANSPORTS, one call:
//   - a backend registered with kl_steam_set_backend() (the visionOS app does
//     this before the runtime boots; its Swift glue calls SteamBridgeService);
//   - otherwise, on the Mac, the Unix socket $KL_STEAM_BRIDGE (default
//     ~/.steamdepot/bridge.sock), which `steamdepot serve` listens on.
//
// This header is part of the app's C surface (Klepton-Bridging-Header.h).
#ifndef KL_STEAM_BRIDGE_H
#define KL_STEAM_BRIDGE_H
#include <stddef.h>

// A backend answers ONE request line (no trailing newline) with ONE response
// line, written NUL-terminated into `response` (at most `cap` bytes, NUL
// included). Returns the response length, or -1 if the service could not be
// reached or did not answer within `timeout_ms`. Called on a game thread (never
// on the app's main thread, except for the teardown call), possibly from
// several threads at once; it must block until it has an answer.
typedef int (*kl_steam_backend_fn)(const char *request, char *response, size_t cap, int timeout_ms);

// Register (or, with NULL, remove) the backend. Call before the guest boots.
void kl_steam_set_backend(kl_steam_backend_fn fn);
// Whether one is registered.
int  kl_steam_has_backend(void);

// One round trip through whichever transport applies. Same contract as a
// backend: the response length, or -1.
int  kl_steam_backend_call(const char *request, char *response, size_t cap, int timeout_ms);

// ACHIEVEMENT UNLOCKS, for the "achievement unlocked" toast. When a StoreStats
// comes back with a non-empty "unlocked" list (the store turned those
// achievements false -> true; with KL_STEAM_STATS_DRYRUN=1, what it WOULD
// unlock), the stand-in calls the registered handler once per achievement, in
// order, on the store's worker thread (never the game thread). `name` and
// `desc` are already localised to the game language (KL_STEAM_LANG); `desc`
// may be ""; `icon_path` is a local cached file (the bridge's `icon` op) or ""
// when there is none. The strings live only for the call. With no handler the
// unlock is only logged ("[toast]").
typedef void (*kl_steam_unlock_fn)(const char *api, const char *name,
                                   const char *desc, const char *icon_path);
void kl_steam_set_unlock_handler(kl_steam_unlock_fn fn);
kl_steam_unlock_fn kl_steam_unlock_handler(void);

// The game language the stand-in answers GetCurrentGameLanguage with (a Steam
// API language name: "english", "spanish", "latam", ...). For localising the
// host's own UI (the toast header) the same way the game is.
const char *kl_steam_game_language(void);

// Tell Steam the game is no longer running ("playing" off), once. Called by
// SteamAPI_Shutdown and at exit; the app calls it on its own teardown path too,
// because a visionOS app that is backgrounded exits without unwinding the guest.
// Harmless when nothing was announced.
void kl_steam_shutdown(void);
#endif
