# AVP Game Hub — guide

Everything the [README](../README.md) leaves out.

## Requirements

- An Apple silicon Mac with **Xcode** and its visionOS SDK (Xcode › Settings › Components ›
  visionOS). The author builds with Xcode 27.0 on macOS 27; upstream Klepton documents Xcode 26.
- [Homebrew](https://brew.sh) tools: `brew install pkg-config sdl3 apktool`.
- Disk: ~25 GB for the toolchain (ANGLE alone takes 14–20 GB), plus each game's files on the Mac
  (0.1–1.2 GB per game, see below). Game data proper downloads on the headset, not the Mac.
- An Apple Developer account, signed in to Xcode. A **paid** team is needed for the
  *Increased Memory Limit* and *Extended Virtual Addressing* capabilities the hub asks for
  (explicit App ID), and installs last a year instead of seven days. A free team cannot sign those
  capabilities: `KLEPTON_ENTITLEMENTS=0` builds without them, and the bigger games will then be
  killed for memory.
- Apple Vision Pro in Developer Mode, paired with the Mac (Setup, step 2).
- PlayStation VR2 Sense controllers (paired to the Vision Pro). Hand tracking covers menus, not
  gameplay.
- The games, bought on your own Steam and/or Meta account.

## Setup

1. **Xcode.** Install it, add the visionOS platform (Settings › Components), and sign in under
   **Xcode › Settings › Accounts**. Signing in creates the *Apple Development* certificate the
   build reads your team id from; without it a device build stops with "no signing team".

2. **Vision Pro.** On the headset, pair it with the Mac: **Settings › General › Remote Devices**,
   then on the Mac open **Xcode › Window › Devices and Simulators**, select the Vision Pro and
   enter the code it shows. Turn on **Developer Mode** on the headset (Settings › Privacy &
   Security › Developer Mode; it appears once the headset has been paired) and restart when asked.
   Keep it on the same Wi-Fi as the Mac.

3. **Clone and configure.**

   ```bash
   git clone --recurse-submodules https://github.com/NSCabezon/AVPGameHub.git && cd AVPGameHub
   cp local/config.env.example local/config.env
   ```

   Then edit `local/config.env` and set **`KLEPTON_BUNDLE_ID`** to an id under your own reverse
   domain, for example `com.jdoe.avpgamehub` (`com.example.*` and `com.yourname.*` are refused).
   Keep it once you have installed: the game data lives in that app's container, and a new id
   means downloading everything again. `KLEPTON_TEAM` and `KLEPTON_DEVICE` are detected when left
   empty.

   `local/` is yours and gitignored:

   | `local/…` | What goes there |
   |---|---|
   | `config.env` | `KLEPTON_BUNDLE_ID` (required), `KLEPTON_TEAM`, `KLEPTON_DEVICE`, optional `KLEPTON_HUB_GAMES` / `KLEPTON_LOW_LATENCY` / `KLEPTON_ICLOUD` (see the example file) |
   | `game/` | Half-Life: Alyx's Linux build: `game/bin/` (Steam depot 546564) and `game/steamrt4-arm64/` (the Steam Linux Runtime 4, arm64) |
   | `superhot/`, `metro/` | Steam downloads the SUPERHOT VR and Metro Awakening APKs come from (can be deleted once copied) |
   | `tools/` | Meta's `ovr-platform-util` (below) |

   The APKs and their decoded trees go in `klepton/` itself (`klepton/<game>.apk`,
   `klepton/<game>/`), which ignores them.

4. **Toolchain.** From the repository root:

   ```bash
   cd klepton
   make angle-xros angle-xrsim   # ANGLE for visionOS: 14–20 GB of disk, an hour or more the first time
   make mvk                      # MoltenVK (Vulkan games: Half-Life: Alyx, Metro Awakening)
   make fossilize                # optional: pipeline caches (Half-Life: Alyx's shader prewarm)
   cd ..
   ```

   `make mvk` fetches the stock MoltenVK prebuilt. The Half-Life: Alyx numbers below were measured
   with the foveating fork, `make mvk-fdm`, which builds MoltenVK from source (slower). More in
   [`klepton/BUILDING.md`](../klepton/BUILDING.md); `make angle-all` also builds the host slice,
   which only `make check` needs.

5. **Game files** — for the games you want in this build: see
   [Getting each game's files](#getting-each-games-files). You can skip this and build first: the
   hub then carries no game yet, only the library.

6. **Build and install** the hub on the headset (or press **Build & Install** in the Mac app):

   ```bash
   klepton/build_run_vpro.sh hub               # build, install, launch
   klepton/build_run_vpro.sh hub --build-only  # build and sign only, no headset needed
   ```

   The first build registers the headset with your team. Keep the Vision Pro on, unlocked, awake
   and on the same Wi-Fi as the Mac; if registration fails, the script says how to add the device
   by hand.

7. **On the headset**, open **AVP Game Hub**, sign in to Steam and/or Meta, and download a game.

## Getting each game's files

The Mac needs each game's **code** — its APK or Linux binaries — because the hub translates it at
build time. The game **data** (gigabytes) downloads on the headset, from the hub, after you sign in.
You need these files only for the games you want: **a build includes only the games whose files
are on this Mac**; the others still appear in the hub's library as *Not included in this build*,
and the build prints what each one is missing. Check before building with the Mac app's
**Status**, or:

```bash
cd klepton && python3 visionos/targets.py --hub-check
```

`KLEPTON_HUB_GAMES=superhot,ktane` (environment or `local/config.env`) builds only those games;
`KLEPTON_HUB_GAMES=none` builds the library alone.

The commands below run from the repository root unless they say otherwise. Steam downloads use the
SteamDepot command-line tool: the first run signs you in with a QR code (open the printed URL or
pass `--qr-png /tmp/qr.png` and scan it with the Steam mobile app) or with `--user <your login>`;
the token is kept in `~/.steamdepot-token.json`. Meta downloads use MetaStore, after
`swift run metastore login` (it needs [Meta's tool](#metas-tool-never-committed)). The first
`swift run` of each package compiles it (a few minutes).

### Half-Life: Alyx (Steam)

About 1.1 GB on the Mac. The Linux arm64 binaries (depot 546564), the Steam Linux Runtime 4 arm64
they link against, then a host run that writes the list of libraries the build translates
(`klepton/build/alyx_images.txt`):

```bash
(cd packages/SteamDepot && swift run -c release steamdepot --app 546560 --depot 546564 --dir ../../local/game/bin)

mkdir -p local/game/steamrt4-arm64 && cd local/game/steamrt4-arm64
curl -LO https://repo.steampowered.com/steamrt4/images/latest-public-beta/com.valvesoftware.SteamRuntime.Platform-arm64-steamrt4-runtime.tar.gz
tar xzf com.valvesoftware.SteamRuntime.Platform-arm64-steamrt4-runtime.tar.gz && rm com.valvesoftware.SteamRuntime.Platform-arm64-steamrt4-runtime.tar.gz
cd ../../../klepton && ./build_run_host.sh alyx --gap && cd ..
```

`local/game/` should then hold `bin/game/bin/linuxsteamrtarm64/hlvr` and
`steamrt4-arm64/files/lib/aarch64-linux-gnu/`. The runtime is Valve's public Steam Runtime 4 image;
the author used the `latest-public-beta` build 4.0.20260928.262390 — if a newer one fails, look
for that build under `https://repo.steampowered.com/steamrt4/images/`. The `--gap` run needs
`pkg-config` and `sdl3` (Homebrew). The 72 GB of game content is downloaded by the hub.

### SUPERHOT VR (Steam)

The port is built from the Steam Frame build (app 617830, depot 617833, `shvr.apk`, ~650 MB;
~700 MB decoded). Meta's Quest build is a different APK: the hub lists Meta as a source but only
installs from the store whose build matches the port.

```bash
(cd packages/SteamDepot && swift run -c release steamdepot --app 617830 --depot 617833 --filter shvr.apk --dir ../../local/superhot)
cp local/superhot/shvr.apk klepton/superhot.apk
cd klepton && apktool d -f -o superhot superhot.apk && cd ..
```

### Meta games: Beat Saber, Batman: Arkham Shadow, I Expect You To Die, Keep Talking and Nobody Explodes

One APK each, fetched from your Meta account (`--apk-only`: no OBBs, no data). Recipes and sizes
(APK / decoded): `beatsaber` (55 MB / 165 MB), `batman` (76 MB / 250 MB), `ieytd` (533 MB /
1.2 GB), `ktane` (150 MB / 220 MB). For each game `<g>` you own:

```bash
(cd packages/MetaStore && swift run metastore fetch <g> --apk-only --out ../../klepton/<g>.apk)
apktool d -f -o klepton/<g> klepton/<g>.apk
```

Beat Saber: the port was tested with 1.40.4; Meta currently sells 1.40.8, which is what `fetch`
downloads, and it is not yet tested.

### Metro Awakening (Steam)

The Steam Frame build (app 2669410, depot 2669412). Only its APK is needed on the Mac (50 MB;
the 19 GB of OBBs download on the headset):

```bash
(cd packages/SteamDepot && swift run -c release steamdepot --app 2669410 --depot 2669412 --filter Impact-Android-Shipping-arm64.apk --dir ../../local/metro)
cp local/metro/Impact-Android-Shipping-arm64.apk klepton/metro.apk
cd klepton && apktool d -f -o metro metro.apk && cd ..
```

Then build again (Setup, step 6): the new games are translated and included.

### Meta's tool (never committed)

Meta sign-in uses Meta's own command-line tool, `ovr-platform-util` (macOS, signed by Meta's team
`HXH6UQBHD4`). It is proprietary, so it is not in this repository and must never be committed.
Either:

- in the Mac app, **Status › Get Meta's tool** opens
  [Meta's download page](https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/)
  and picks the file up from `~/Downloads` once it lands; or
- download it yourself and put it in `local/tools/ovr-platform-util`;
  `apps/macos/scripts/make-app.sh` then bundles it into the Mac app, after checking Meta's
  signature, and `swift run metastore login --tool ../../local/tools/ovr-platform-util` uses it.

## Mac companion app

`apps/macos` — a SwiftUI app for macOS 15+.

```bash
cd apps/macos && scripts/make-app.sh && open "build/AVP Game Hub.app"
```

- **Status**: checks Xcode, the visionOS SDK, the Klepton toolchain pieces, signing team,
  headset, bundle id and which games' files are on this Mac (and what the others are missing),
  and says how to fix what is missing.
- **Accounts**: Steam (QR or password, token on this Mac) and Meta. **Meta sign-in**: your e-mail,
  password and one-time code go only to Meta's tool; the token is stored in your Keychain and
  **Send to headset** copies it into the hub's container once. Meta's API used here is unofficial:
  use it at your own risk.
- **Games**: what you own, per store.
- **Build & Install**: runs `klepton/build_run_vpro.sh hub` with your settings.
- **Sessions**: the performance summary of every session played on the headset.

The command-line tools are in the packages: `swift run steamdepot …` in `packages/SteamDepot` and
`swift run metastore …` in `packages/MetaStore`.

## Troubleshooting the build

- **"no signing team"**: sign in under Xcode › Settings › Accounts (that creates the Apple
  Development certificate), or set `KLEPTON_TEAM` in `local/config.env`.
- **"bundle id is '…'"**: set your own `KLEPTON_BUNDLE_ID` in `local/config.env`.
- **"hub: N game(s) left out of this build"**: not an error — those games' files are not on this
  Mac; the message names what is missing and the command that gets it.
- **Signing fails on an entitlement** ("doesn't include the … entitlement"): the memory
  capabilities need a paid team; `KLEPTON_ENTITLEMENTS=0` builds without any. The
  `low-latency-streaming` entitlement is off unless you set `KLEPTON_LOW_LATENCY=1`, and the iCloud
  entitlements (save backups of the Meta games) unless you set `KLEPTON_ICLOUD=1`.
- **"the Apple team has no device registered yet"**: the first build registers the headset; keep
  it awake, unlocked and on the same Wi-Fi, then run the build again.

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
| Metro Awakening | Unreal Engine, Android | in the hub; being tested on the headset |
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
- **Streaming from the Mac** for games with no ARM64 build (an experimental *Play from Mac* exists).
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
local/              yours only, gitignored (config, Meta's tool, game files for building)
```

