# Third-party notices

AVP Game Hub's own code is MIT licensed (see `LICENSE`). This file lists the third-party
code, data and tools it includes, adapts, or fetches at build time. Where a file adapts
third-party code, a comment in it names the source.

Nothing in this repository is game code or game data: games are downloaded by the player,
from their own store accounts, onto their own devices.

## Included in this repository

| Component | Where | License |
|---|---|---|
| Klepton (Max Thomas) | `klepton/` (fork) | MIT — `klepton/LICENSE` |
| Glovebox (the Glovebox contributors) | adapted parts of `klepton/` and `packages/SteamDepot` (listed below) | MIT |
| avp-play (myMartek) | adapted parts of `klepton/`, `packages/MetaStore`, `apps/macos` (listed below) | MIT |
| ALVR (polygraphene, alvr-org) | `klepton/runtime/guest/kl_openvr_hand.h` (hand skeleton tables); reprojection maths and audio defaults ported from VisionOSALVRClient in `klepton/runtime/gfx/kl_reproject.c`, `klepton/visionos/Sources/KleptonAudio.swift` | MIT |
| Zstandard 1.5.7, decompression only (Meta Platforms, Inc.) | `packages/SteamDepot/Sources/CZstd/` | BSD-3-Clause — `packages/SteamDepot/Sources/CZstd/LICENSE` |
| LZMA decoder, port of Igor Pavlov's LzmaSpec.cpp (LZMA SDK) | `packages/SteamDepot/Sources/SteamDepot/LZMA.swift` | Public domain |
| DejaVu Sans font | `klepton/runtime/data/kl_menu_font.ttf` | Bitstream Vera license + public-domain DejaVu changes |
| CIPIC HRTF subject 124, as shipped in Valve's steam-audio | `klepton/runtime/data/phonon_hrtf_cipic_124.sofa` | Apache-2.0 (steam-audio) |
| OpenVR interface vtable order, generated from Valve's `openvr.h` | `klepton/runtime/guest/kl_openvr_vtables.h` | BSD-3-Clause (OpenVR) |
| Steamworks interface/method names, generated from the SDK headers (names and slot order only, no SDK code) | `klepton/runtime/guest/kl_steam_vtables.h`, `kl_steam_flat.h` | — |
| Root CA anchors (DER), generated from the host's trust store by `tools/gen_cacerts.py` | `klepton/runtime/kl_cacert_table.h` | public certificates |
| Patches against ANGLE | `klepton/angle-patches/` | BSD-3-Clause (ANGLE) |
| Patches against MoltenVK and SPIRV-Cross (fragment density map) | `klepton/mvk-patches/` | Apache-2.0 |
| Built-in Meta store recipes (store ids, sizes, sha256 — no game data) | `packages/MetaStore/Sources/MetaStore/BuiltinRecipes.swift` | MIT (avp-play recipes) |

Steam's network protocol is spoken by `packages/SteamDepot` from the public protobuf
definitions (SteamDatabase/Protobufs); message ids and layouts were checked against SteamKit2
and DepotDownloader, but no code from either is included.

## Fetched at build time (not in this repository)

| Component | Fetched by | License |
|---|---|---|
| ANGLE (Google) + depot_tools | `klepton/Makefile` (`make angle-*`), `klepton/visionos/mkangle.sh` | BSD-3-Clause |
| MoltenVK v1.4.2 (Khronos Group) and the FDM fork build | `klepton/tools/mvk_fetch.sh`, `klepton/tools/mvk_fdm_build.sh` | Apache-2.0 |
| SPIRV-Cross (Khronos Group) | with MoltenVK | Apache-2.0 |
| Fossilize (Valve Software) @ 556da9f | `make fossilize` | MIT |
| SDL3 (host viewer only, Homebrew) | `brew install sdl3` | zlib |
| apktool (host, Homebrew) | `brew install apktool` | Apache-2.0 |
| Meta's `ovr-platform-util` | downloaded by you into `local/tools/` — proprietary, **never committed** | Meta's terms |

## Klepton

`klepton/` is a fork of [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas.

```
MIT License

Copyright (c) 2026 Max Thomas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Glovebox

Parts of `klepton/` are adapted from Glovebox (github.com/glovebox-vr/glovebox),
used under the MIT License below. Each adapted file or function says so in a
comment naming its Glovebox source:

- `runtime/gfx/kl_gpu_time.{m,h}` and `klvk_gpu_watch` in `runtime/gfx/kl_vulkan.c`
  (KL_GPU_TIME)
- the guest frame pacer in `visionos/Sources/kl_app.c` (KL_GUEST_PACE_HZ / _DIV)
- the `tkill(tid, 0)` probe in `runtime/libc/kl_libc.c` (KL_TKILL_PROBE)
- the Alyx render convar list in `runtime/guest/kl_glibc.c` (KL_ALYX_PROFILE)

```
MIT License

Copyright (c) 2026 the Glovebox contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Also adapted from Glovebox: Steam Cloud save sync and its policy (`packages/SteamDepot/Sources/SteamDepot/CloudSync.swift`, `SteamCloud.swift`, `SteamDepotCLI/Cloud.swift`), pinned-manifest support (`SupportedTitles.swift`) and the Alyx pipeline recipe tooling (`klepton/tools/alyx_pipelines.py`).

## avp-play

Parts of `klepton/` are adapted from avp-play's Klepton fork
(github.com/myMartek/avp-play, toolchain 232 / commit 8073c5e), used under the
MIT License below: per-game targets (batman, beatsaber140/128, walkabout,
wrath2, moss, doom3quest, Cave Crave, the generic `x<store id>` row) and generic
runtime fixes across `runtime/` (OVRPlugin, Meta platform, OpenXR, Vulkan, GL,
JNI, libc, media, x18), `tools/`, `visionos/` and `tests/t_casp.c`. Each adapted
block says so in a comment of the form
`Adapted from avp-play (MIT, github.com/myMartek/avp-play) <their path>`.
The inventory of what was taken and why is in
`docs/2026-10-11-avp-play-klepton-diff.md`.

```
MIT License

Copyright (c) 2026 myMartek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Also adapted from avp-play: the Meta sign-in flow, store client and recipes in
`packages/MetaStore` and the Meta tool handling in `apps/macos/Sources/HubCore/MetaToolFiles.swift`.

## ALVR

`klepton/runtime/guest/kl_openvr_hand.h` ports tables and functions verbatim from
[ALVR](https://github.com/alvr-org/ALVR) (`alvr/server_openvr/cpp/alvr_server/Controller.cpp`).

```
MIT License

Copyright (c) 2018-2019 polygraphene
Copyright (c) 2020-2024 alvr-org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Zstandard

See `packages/SteamDepot/Sources/CZstd/LICENSE` (BSD-3-Clause, Copyright (c) Meta Platforms,
Inc. and affiliates). Vendored from github.com/facebook/zstd v1.5.7, decompression sources only.

## DejaVu Sans

Copyright (c) 2003 by Bitstream, Inc. All Rights Reserved. Bitstream Vera is a trademark of
Bitstream, Inc. DejaVu changes are in the public domain. Redistributed under the Bitstream Vera
Fonts license (https://dejavu-fonts.github.io/License.html).

## OpenVR

The interface tables are generated from `openvr.h`, Copyright (c) 2015, Valve Corporation,
BSD-3-Clause (https://github.com/ValveSoftware/openvr/blob/master/LICENSE).

## steam-audio HRTF data

`phonon_hrtf_cipic_124.sofa` is byte-identical to `core/data/hrtf/cipic_124.sofa` in
https://github.com/ValveSoftware/steam-audio (Apache-2.0).
