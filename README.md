# AVP Game Hub

[![Tip jar](https://img.shields.io/badge/Tip%20jar-PayPal-00457C?logo=paypal&logoColor=white)](https://paypal.me/nscabezon)
<sub>Tips support development. The project is free and never sells or unlocks games.</sub>

**Play the Steam and Meta games you own, natively on Apple Vision Pro.** One hub on the headset,
one companion app on your Mac. Games with an ARM64 build (Steam Frame, Quest) are translated by
[Klepton](https://github.com/shinyquagsire23/Klepton) and run on the headset itself — no PC, no
streaming.

## Games

| Game | Store | Status |
|---|---|---|
| Half-Life: Alyx | `Steam` | Playable (tested through the early chapters) |
| SUPERHOT VR | `Steam` `Meta` | Playable (the port is built from the Steam Frame build) |
| Beat Saber | `Meta` | 1.40.4 tested; Meta now sells 1.40.8, not yet tested |
| Batman: Arkham Shadow | `Meta` | Runs on the Mac; being tested on the headset |
| Metro Awakening | `Steam` | Runs on the Mac; being tested on the headset |
| I Expect You To Die | `Meta` | Runs on the Mac; being tested on the headset |
| Keep Talking and Nobody Explodes | `Meta` | Runs on the Mac; being tested on the headset |

Half-Life: Alyx on a Vision Pro **M2**: ~45 fps (median frame 22.1 ms, 1 % low 29.5 fps), 4× MSAA
with foveated rendering, 0 shader stalls, ~20 s loads.

## Quick start

You need an Apple silicon Mac with Xcode (signed in to your Apple account), a paid Apple Developer
account (recommended), a Vision Pro in Developer Mode paired with that Mac, PS VR2 Sense
controllers and the games on your own accounts.

```bash
git clone --recurse-submodules https://github.com/NSCabezon/AVPGameHub.git && cd AVPGameHub
cp local/config.env.example local/config.env   # set KLEPTON_BUNDLE_ID to your own id
cd apps/macos && scripts/make-app.sh && open "build/AVP Game Hub.app"
```

The Mac app checks your setup (including which games' files are on this Mac), signs you in to
Steam and Meta, and builds and installs the hub. A build carries only the games whose files you
have; the others show in the hub as not included. Toolchain, per-game files and troubleshooting:
[docs/GUIDE.md](docs/GUIDE.md).

## Highlights

- **One library**, ownership checked per store; game data downloads happen on the headset.
- **Siri**: *"Open game settings in Hub"* opens an in-game menu (antialiasing, foveation,
  performance overlay, render scale).
- **Session stats** on the headset and the Mac.
- **Play from Mac** (experimental): stream a game running on the Mac to the headset.

## Credits

Built on [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas, with ideas and code
from [Glovebox](https://github.com/glovebox-vr/glovebox) and
[avp-play](https://github.com/myMartek/avp-play) (all MIT). Full list:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Legal

Unofficial; not affiliated with Apple, Valve or Meta. Only for games you own — no DRM bypass, no
game files here. Store access uses unofficial APIs, at your own risk. [MIT](LICENSE).
