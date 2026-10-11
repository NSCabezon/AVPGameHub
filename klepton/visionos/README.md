# The visionOS host app

The Klepton app itself: Swift for the platform layer (P4).
`spikes/device-probe` stays what it is: a small, disposable thing
for answering device questions. This is the app those answers were for.

```bash
./run.sh              # the booted visionOS Simulator — rung 2, tests dyld
./run.sh device       # a physical Vision Pro         — rung 3, tests AMFI

KLEPTON_TARGET=superhot ./run.sh device      # ...for another guest
../build_run_vpro.sh superhot                # the same, wrapped: builds, runs,
                                             # and reads the log back
```

Both do the same five steps: build the runtime (`make xros`), translate the
guest libraries (`mkguest.sh`), regenerate the project, install, stage
assets, launch. Each builds only the slice it will install — `XROS_PLATFORMS`,
exported by `run.sh` and read by both — because a device build never loads the
simulator's runtime and each slice is a full compile of it. `make xros` on its
own still builds the pair, which is the gate. `KL_SKIP_STAGE=1` skips the upload when the assets are already
there, which on device is the difference between a 20-second loop and a
20-minute one.

## Which guest — one table, five consumers

`targets.py` is the authority: tree, APK, asset directory, entry library, boot
sequence, bundle id, display name and **product name**. `run.sh`, `mkguest.sh`,
`stage_assets.sh` and `gen_xcodeproj.py` all read it, and `make targets`
generates `runtime/kl_target_table.h` from it so the C runtime — the app's
`Sources/kl_app.c` and the host's `build/m_boot` — reads the same row.

That last one is not tidiness. Two drivers describing one guest differently is a
class of bug with no error surface at all: the build succeeds, the app installs,
and the guest is told the wrong thing about itself. The failure is silent in
both directions — one title's APK opened as another's zip, or a title writing
its saves into another's directory.

**A bundle id separates the installed apps and nothing else about a build**, so
the target also carries the PRODUCT name, and with it the `.xcodeproj`, the
`.app`, the derived-data directory and the `Frameworks/<target>/` the
translations are staged into. ANGLE is deliberately not per-target: it is the
same renderer for every guest and `mkangle.sh` writes it once, into
`Frameworks/` itself.

The id itself is **derived, not stored**: `$USER.dev.klepton.target.<target>`.
Two halves, for two different collisions. The `<target>` half separates the apps
on one device. **The `$USER` half separates DEVELOPERS**, and that one is not
cosmetic: an App ID can be registered to exactly one team, automatic signing
registers it on the first build, and so whoever builds this tree first silently
takes the id away from everyone else — the next person's build fails with
`Failed Registering Bundle Identifier: … cannot be registered to your
development team`, which reads like a broken project rather than a name already
spoken for, and it takes the two memory entitlements with it because those need
an explicit App ID.

`KLEPTON_BUNDLE_SCOPE` overrides the `$USER` part (an unset or empty one leaves
the id unscoped rather than emitting a leading dot); `KLEPTON_BUNDLE_ID`
overrides the whole id. **Changing the id orphans the container** — the assets,
the OBB and the guest's saves live in the old app's Documents, and the new id is
a new app with an empty one. That is not silent: the staging stamp is keyed on
the bundle id, so the first build after a change re-stages by itself. It is
still a 2.2 GB upload, and the old app is still installed until you delete it.

`KLEPTON_TARGET` selects it at BUILD time; the chosen name is compiled into the
app as `KL_TARGET_DEFAULT`, because an app launched by hand from the Home View
has no environment at all. `KL_TARGET` overrides that at run time — but the two
apps embed *different* guest frameworks, so pointing one at the other's target
stops at `kl_app_configure` with "missing guest libraries" rather than
misbehaving.

## The hub: one app, several games

`targets.py`'s `hub` row is a BUILD, not a guest (kind `hub`; it never reaches
`runtime/kl_target_table.h`). It embeds every game in its `games` list and opens
on an in-app library (`Sources/KleptonHub.swift`) instead of auto-booting:

- **Frameworks, per game.** Each game's translations go to
  `KleptonHub.app/Frameworks/<game>/` (one Embed phase per game, `dstPath` =
  the game), so same-named libraries from two games cannot collide. They are
  referenced as the platform slice's `.framework`, not the `.xcframework`:
  Xcode flattens every xcframework into one products directory first, and two
  games' `libphonon` then fail the build ("Multiple commands produce"). Guest
  framework bundle ids carry the target (`dev.klepton.guest.<target>.<lib>`). `kl_app.c`
  sets `KL_DYLIB_DIR` to `Frameworks/<target>/` when that folder holds the
  target's entry library, else to `Frameworks/` (every single-target build).
  ANGLE and MoltenVK stay in `Frameworks/` for all games (`KL_ANGLE_DIR`,
  `KL_MVK_DIR`).
- **Selection.** Play sets `KL_TARGET=<game>` (the existing runtime override)
  and only then creates the boot window, so `kl_app_target_name_or_default()`,
  `kl_app_configure` and everything after them are the single-game path. The
  compiled-in `KL_TARGET_DEFAULT` is the first game. `KL_HUB_GAME=<game>` in the
  launch environment skips the library (scripted runs). **One game per
  process**: when the game ends or the app is backgrounded, it exits; the next
  launch shows the library again (visionOS apps cannot relaunch themselves).
- **Data.** Each game's container root is `Documents/games/<game>/`, laid out
  as a single-game build lays out `Documents/` (so alyx's game root is
  `games/alyx/android-files/alyx/game`). The boot log stays at
  `Documents/klepton-boot.log` (`kl_app_set_log_dir`). On first launch the hub
  adopts data that predates it with a rename, not a copy — alyx's
  `Documents/android-files/alyx` becomes `games/alyx/android-files/alyx`, and a
  relative symlink is left at the old path for a single-game alyx build.
- **Downloads.** A game with a `SteamGameDescriptor` (`Sources/
  KleptonSteamContent.swift`, registry `SteamGames.all`: app id, depots or an OS
  filter to discover them, file filter, data subpath, legacy path, presence
  probes, size) downloads its data in-app through SteamDepot, with the same
  Steam sign-in, adopt/verify, free-space check and completion marker as the
  alyx build. "Update available" compares the markers with Steam's current
  manifests once signed in.
- **APK games** (descriptor `apk`, e.g. SUPERHOT: depot 617833's `shvr.apk` +
  `vrpreferences.json` land in `games/superhot/steam/`). Before boot,
  `Sources/KleptonHubPrep.swift` derives on the headset what `kl_app_configure`
  reads: `games/superhot/superhot.apk` (a hard link to the downloaded APK, which
  Unity mounts as a zip), `games/superhot/superhot/assets/` (only the APK's
  assets/ entries of at most 16 MB, ~24 MB; the bulk stays in the APK) and the
  `apktool.yml` / `AndroidManifest.xml` beside it, which `gen_xcodeproj.py` bakes
  into the generated manifest from the Mac's apktool tree (metadata, not game
  data). Stamped with the APK's size and mtime, so it reruns only after an
  update. Nothing is staged from the Mac.
- **Bundle id** `KLEPTON_BUNDLE_ID` from `local/config.env` (the container with Alyx's 72 GB);
  product `KleptonHub`, display name "Klepton".

Adding a game: build its frameworks (`KLEPTON_TARGET=<game> ./mkguest.sh`, which
`run.sh` does for every hub game), add its name to the hub row's `games`, and —
if Steam can supply its data — one `SteamGameDescriptor` in `SteamGames.all`.

```bash
./build_run_vpro.sh hub --build-only      # build + sign for the device, no headset
./build_run_vpro.sh hub                   # build, install, launch (library)
KL_SKIP_GUEST=1 ./build_run_vpro.sh hub   # ...reusing the translated frameworks
KLEPTON_HUB_NO_GUESTS=1 KL_SKIP_GUEST=1 KLEPTON_TARGET=hub visionos/run.sh sim
                                          # library-only build for the simulator
```

## What lives where, and why

|  | where | why |
|---|---|---|
| C runtime | `build/Klepton.xcframework`, linked **statically** | `make xros` builds both slices; `run.sh` passes `XROS_PLATFORMS=xros` or `=xrsim` so a run builds only the one it will install, which halves it. Static, so it is inside the app binary — no load-time cost, and nothing for dyld to resolve. |
| guest libraries | `Frameworks/<name>.xcframework`, **embedded, not linked** | klepton-ld output. Embedded so Xcode code-signs them; a loose Mach-O elsewhere in the bundle is only *sealed* by the outer signature, which is not the same thing and is not what AMFI accepted in P3. Not *linked*, because nothing references their symbols — the runtime `dlopen`s them by path, and linking would make dyld want an exports trie klepton-ld deliberately does not emit. |
| APK assets (2.2 GB) | the app's **Documents container**, staged once | They change only when the APK does; the code changes every few minutes. Bundling them would put a multi-minute upload in front of every build. |

The asymmetry is deliberate: **code in the bundle, data in the container.** P3
established that AMFI accepts a `klepton-ld` dylib inside a bundle we signed,
and established nothing at all about one pushed into Documents afterwards.
Assets carry no code, so they have no such constraint.

## Language boundary

Swift owns the App, and will own the ImmersiveSpace, Compositor Services,
Metal and ARKit. C owns the guest. The seam is `Sources/kl_app.h` — four
functions — imported through `Sources/Klepton-Bridging-Header.h`. There is no
Objective-C anywhere and none is needed; see below for why the
boundary lands there.

`Sources/kl_app.c` is `t_boot`'s sequence with the harness removed: no forked
DRM-guard self-test, no re-exec'd recon child (an app bundle never forks, and
the Metal-refuses-forked-children reason for it is moot once it does not), no
argv, no SDL viewer. What is left is load libmain → `JNI_OnLoad` →
`NativeLoader.load` → `UnityPlayer.initJni`.

## Reading a run

Everything the guest prints goes to `Documents/klepton-boot.log`,
**line-buffered** — an unimplemented JNI slot aborts the process by design, and
a fully-buffered stream loses the whole report when the process dies on a
signal. The UI polls the file while the run is going and offers it via
ShareLink afterwards; on the simulator it is easier to read straight off disk:

```bash
UDID=$(xcrun simctl list devices booted | grep -o '[0-9A-F-]\{36\}' | head -1)
BUNDLE=$(python3 targets.py beatsaber bundle)     # $USER.dev.klepton.target.<target>
LC_ALL=C less "$(xcrun simctl get_app_container $UDID $BUNDLE data)/Documents/klepton-boot.log"
```

`LC_ALL=C` because the log contains guest bytes — the same trap as on the host.

## Gotchas that cost time here

- **Reinstalling rotates the data container.** Assets staged before an install
  end up in an orphaned container and the app reports them missing, which reads
  like a staging bug rather than an ordering one. `run.sh` stages *after*
  installing, always.
- **`$VAR…` is not `$VAR` followed by an ellipsis.** bash folds the multi-byte
  character into the variable name and dies with `unbound variable` on a name
  you never wrote. Brace it.
- **The archives need real Make prerequisites.** With only a `.PHONY` rule
  producing `build/xros/libklepton.a`, an edited runtime source left a stale
  archive, the xcframework was built from it, and the app silently ran the
  *previous* loader — which presents as a bug in the app. Fixed in the Makefile.
