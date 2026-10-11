# AVP Game Hub — guide

Everything the [README](../README.md) leaves out.

## Requirements

- An Apple silicon Mac with Xcode and the visionOS SDK.
- An Apple Developer account. A **paid** account is strongly recommended: the hub uses the
  *Increased Memory Limit* and *Extended Virtual Addressing* capabilities (explicit App ID), and
  installs last a year instead of seven days.
- Apple Vision Pro.
- PlayStation VR2 Sense controllers (paired to the Vision Pro). Hand tracking covers menus, not
  gameplay.
- The games, bought on your own Steam and/or Meta account.

## Setup

1. Clone, then create your local folder (gitignored, never committed):

   ```bash
   git clone https://github.com/NSCabezon/AVPGameHub.git && cd AVPGameHub
   mkdir -p local/{apks,game,foz,tools}
   cp local/config.env.example local/config.env
   ```

   | `local/…` | What goes there |
   |---|---|
   | `config.env` | `KLEPTON_TEAM` (team id), `KLEPTON_DEVICE` (headset UDID), `KLEPTON_BUNDLE_ID` (your hub's bundle id — required for device builds) |
   | `apks/` | APKs you fetched for translation (`metastore fetch … --apk-only`) |
   | `game/` | Linux game builds you downloaded for translation (Half-Life: Alyx binaries) |
   | `foz/` | Recorded Vulkan pipeline caches (Fossilize) |
   | `tools/` | Meta's `ovr-platform-util` (below) |

   Team and device are detected when left empty. The bundle id is yours: pick one under your own
   reverse domain (`com.yourname.avpgamehub`) and keep it — the game data lives in its container.
   A device build with the placeholder stops with a clear error.

2. Build the toolchain pieces Klepton needs (ANGLE, MoltenVK, Fossilize) — see
   [`klepton/BUILDING.md`](../klepton/BUILDING.md).
3. Build and install the hub on the headset:

   ```bash
   klepton/build_run_vpro.sh hub
   ```

   or press **Build & Install** in the Mac app.
4. On the headset, open **AVP Game Hub**, sign in to Steam and/or Meta, and download a game.

### Meta's tool (never committed)

Meta sign-in uses Meta's own command-line tool, `ovr-platform-util` (macOS, arm64, signed by
Meta's team `HXH6UQBHD4`). It is proprietary, so it is not in this repository and must never be
committed:

1. Download it from
   [Meta's Platform Command Line Utility page](https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/).
2. Put it in `local/tools/ovr-platform-util`.
3. `apps/macos/scripts/make-app.sh` bundles it into the Mac app, after checking Meta's signature.

## Mac companion app

`apps/macos` — a SwiftUI app for macOS 15+.

```bash
cd apps/macos && scripts/make-app.sh && open "build/AVP Game Hub.app"
```

- **Status**: checks Xcode, the visionOS SDK, the Klepton toolchain pieces, signing team,
  headset and bundle id, and says how to fix what is missing.
- **Accounts**: Steam (QR or password, token on this Mac) and Meta. **Meta sign-in**: your e-mail,
  password and one-time code go only to Meta's tool; the token is stored in your Keychain and
  **Send to headset** copies it into the hub's container once. Meta's API used here is unofficial:
  use it at your own risk.
- **Games**: what you own, per store.
- **Build & Install**: runs `klepton/build_run_vpro.sh hub` with your settings.
- **Sessions**: the performance summary of every session played on the headset.

The command-line tools are in the packages: `swift run steamdepot …` in `packages/SteamDepot` and
`swift run metastore …` in `packages/MetaStore`.

## On the headset

### Siri

The hub registers App Shortcuts. In-app phrases need the app's name, for example
*"Open game settings in Hub"* (Spanish: *"Abre ajustes del juego en Hub"*), *"Turn on the FPS
overlay in Game Hub"*, *"Set antialiasing to 4x in Hub"*, *"Turn on foveated rendering in Hub"*.

For a shorter phrase, create a personal Shortcut in the Shortcuts app named, for example,
*"Game settings"* (Spanish: *"Abre ajustes del juego"*) that runs the hub's **Open game settings**
action (*"Abrir ajustes del juego"*). Avoid plain *"open settings"* / *"abre los ajustes"*: it
clashes with the system Settings app.

### Quick settings menu

An in-game, head-locked menu with five rows: **Performance overlay**, **Antialiasing** (2×/4×,
live), **Foveated rendering** (live when the game booted foveated), **Render scale**
(80/90/100 %, next launch) and **Close**. Stick up/down moves, trigger or ✕ changes, ○ closes;
with hands, left pinch moves and right pinch changes. Every change is saved per game.

### Performance overlay

A small panel, lower left: guest fps and frame time (average / worst of the last half second),
GPU ms per frame, reprojected frames, memory footprint, thermal state and display Hz. Off by
default; turn it on from the menu or with Siri.

### Session stats

Every session records frame-time median and percentiles, 1 % low fps, loading time, shader
stalls, prewarm time and peak memory, kept after the app closes. The hub shows the last sessions
per game; the Mac app reads them all.

## Measured on device

Apple Vision Pro **M2**, Half-Life: Alyx. (Glovebox's numbers are on an M5 Vision Pro; the M2 is
roughly half the GPU.)

| Run | Settings | Result |
|---|---|---|
| 2026-10-11, hand fix build (latest) | defaults (4× MSAA, foveated, 45 fps pace) | avg **42.7 fps**, median **22.1 ms**, 1 % low **29.5 fps**, **0 shader stalls**, peak **7.6 GB**, 90 Hz |
| 2026-10-11, 4 min 38 s session | integrated build, defaults | median frame **22.6 ms**, 1 % low **27.7 fps**, **0 shader stalls**, prewarm **3.1 s / 5,207 pipelines**, peak **7.9 GB** |
| 2026-10-11, 9 min 53 s | 4× MSAA, foveation A/B | GPU **18.3 ms** foveated vs **28.8 ms** without (**−36 %**) |
| 2026-10-11 | 2× MSAA | GPU **21.9 ms**, **45 fps**, **5.5 GB** |
| 2026-10-11, 8 min | integrated build | median **22.4 ms**, 1 % low **21.9 fps**, peak **8.2 GB**; display throttled to ~80 Hz |

## Steam Frame candidates

From `steamdepot frame-scan` (reads which games in your Steam library have ARM64 builds). Only
games with an ARM64 build can run natively.

| Game | Build | Status |
|---|---|---|
| Half-Life: Alyx | Linux arm64 (Steam Frame) | ✅ works |
| SUPERHOT VR | Android arm64 (Steam Frame) | ✅ works |
| Metro Awakening | Unreal Engine, Android | not tested (high effort) |
| VVVVVV | flat 2D | not tested |
| Teenage Mutant Ninja Turtles: Shredder's Revenge | flat 2D | not tested |
| FEZ | flat 2D | not tested |
| Capsized | flat 2D | not tested |

Of Valve's Source titles, only Half-Life: Alyx ships an ARM64 build.

## Known issues

- **Meta sign-in in the Mac app may fail** for some accounts. Workaround: sign in from Terminal,
  then use **Send to headset** in the app (or `metastore push-token`):

  ```bash
  cd packages/MetaStore && swift run metastore login --tool ../../local/tools/ovr-platform-util
  ```

## Next steps to investigate

- **Steam Frame**: more ARM64 titles from the candidates table.
- **More stores**: SideQuest; itch.io (via `butler`); Pico.
- **Open-source ports with your own data** from Steam/GOG (for example Doom 3 via Doom3Quest).
- **Streaming from the Mac** for games with no ARM64 build.
- **PS VR games** through an emulator plus streaming (for example Astro Bot).
- Google Play: looked at and discarded.

## Why not the App Store

- The game's own code is compiled into the app at build time, from a copy you downloaded: there
  is no app to ship that contains it legally for everyone.
- visionOS apps may not download and run code (App Review Guideline 2.5.2).
- Steam and Meta sign-in use unofficial APIs.

So you build it yourself, for your own headset, with your own developer account.

## Privacy

- No analytics, no servers of ours. Everything runs on your Mac and headset.
- Store tokens stay on your devices (Keychain on the Mac, the app's container on the headset).
- The apps show your **Steam persona name** only — never your login name, SteamID or Meta e-mail.
  Logs mask account identifiers.

See also [`klepton/PRIVACY.md`](../klepton/PRIVACY.md).

## Repository layout

```
klepton/            the runtime and the visionOS app (fork of Klepton, MIT)
apps/macos/         the Mac companion app (SwiftUI)
packages/SteamDepot Steam client: sign-in, ownership, depot downloads, cloud saves, frame-scan
packages/MetaStore  Meta store client: sign-in via Meta's tool, ownership, verified downloads
docs/               design notes and audits
site/               the GitHub Pages landing page
local/              yours only, gitignored (config, tools, APKs, game data)
```

