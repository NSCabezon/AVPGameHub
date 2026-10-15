# SenseKit: design (draft, 2026-10-13)

Goal: pull the PS VR2 Sense controller logic out of `klepton/visionos/Sources/KleptonControllers.swift`
(2352 lines) into its own Swift package and repo, reusable by any visionOS app
(Klepton guests, the Mac streaming client, other people's apps). No code moved yet.

## Licences: OK

Everything involved is MIT, so a separate MIT repo works. The notices that must travel with it:

| Source | What it contributed | Licence |
|---|---|---|
| Klepton upstream (Max Thomas) | original file and structure | MIT (the `klepton/LICENSE` text) |
| avp-play (myMartek) | blocks marked `Adapted from avp-play` (~L421, L1024, L1495, L1553, L1700) | MIT |
| ALVR (alvr-org) | grip mapping and mirrored pair (`WorldTracker.swift`), PSVR2 tilt and nudge, velocity rotation, haptics engine | MIT |

The SenseKit repo gets `LICENSE` (MIT, the hub contributors) and `THIRD_PARTY_NOTICES.md` with the three
texts. The per-block `Adapted from …` comments move with the code.

## Where it lives

Its own repo, `NSCabezon/SenseKit` (a Swift package, `platforms: [.visionOS(.v26)]`), **added as a git
submodule of Klepton** at `klepton/SenseKit`.

- Klepton's xcodeprojs reference it as an `XCLocalSwiftPackageReference` (`relativePath = "../SenseKit"`),
  emitted by `gen_xcodeproj.py` for all four targets (Klepton, Alyx, Superhot, Hub). `KL_SENSEKIT_PKG`
  overrides the path, the same pattern as `KL_SAVEKIT_PKG`.
- Klepton pins it by submodule commit. No SPM tags are needed, which fits the "never push tags" rule.
- AVPGameHub sees it as a nested submodule (`klepton/SenseKit`). The README already clones with
  `--recurse-submodules`.
- The submodule goes inside Klepton, not AVPGameHub, because all four Klepton targets need it. In the
  parent repo, Klepton would depend on its parent.
- Rejected: a remote SPM dependency. It would need version tags and a resolve step, and there is no in-place
  editing while iterating on the headset.
- Workflow: commit in SenseKit → push SenseKit → bump the pointer in Klepton → bump the klepton pointer
  in AVPGameHub. Push SenseKit before Klepton, or the pointer dangles.

## What moves and what stays

**Into SenseKit (generic Sense):**
- Discovery: spatial `GCController`s, left/right assignment, hot-plug detection (`spatialControllers`,
  `spatialControllersChanged`), presence.
- Pose: `AccessoryTrackingProvider` setup, anchor consumption, prediction with a horizon cap, the grip
  frame and correction (PSVR2 tilt, pos, pivot, mirror), velocities with the gate, the ghost sample.
- Input: buttons, touches, near-touches, trigger, grip, stick; rebinding on every controller rebuild
  (the hot-plug fix from ed062a3); the queued-vs-polled input path; per-hand last activity.
- Haptics: one `CHHapticEngine` per hand, continuous mode plus discrete fallback, gain, minimum pulse.

**Stays in Klepton (adapter `KleptonControllers`):**
- The `OVRPRawButton` bit layout and every `kl_ovrp_*` call (`set_controller_input`, `set_hand_motion`,
  `haptics_pull`, `arm_near_touch`). The near-touch arming pulse is an OVRPlugin quirk, not a Sense one.
- Hand-tracking fallback (`HandAnchor` → grip pose, `KLHandTune`). It could become phase 2 (`SenseKit`
  is controllers only for now).
- Gamepad/DualSense merge (`PadHalf`, `FaceMap`).
- Reading the `KL_*` env vars, `KleptonTuning` live values and `kl_app_target_is_steamlink` defaults.
  The adapter turns these into a `SenseConfiguration`. **The package never reads env vars.**
- Logging: the package exposes a `logger` hook (default off); the adapter routes it to `NSLog` `[cp]`.

## API sketch

```swift
public enum SenseHand: Int, Sendable { case left = 0, right = 1 }

public struct SenseButtons: OptionSet, Sendable {   // physical names, not OVR/OpenXR ones
    public static let cross, circle, square, triangle, options, create, ps,
                      stickClick, trigger, grip: SenseButtons
}

public struct SensePose: Sendable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>
}

public struct SenseHandState: Sendable {
    public var connected: Bool
    public var pose: SensePose?            // nil = not tracked this frame
    public var buttons: SenseButtons
    public var touches: SenseButtons       // capacitive
    public var nearTouches: SenseButtons
    public var trigger: Float, grip: Float
    public var stick: SIMD2<Float>
    public var lastActivity: TimeInterval
}

public struct SenseConfiguration: Sendable {
    public var gripCorrection: SenseGripCorrection   // tilt, pos, pivot, mirrorLeft (ALVR defaults)
    public var predictionCapMs: Double
    public var velocityGate: (linear: Float, angular: Float)
    public var haptics: SenseHapticsConfiguration    // gain, mode (.continuous/.pulse), minPulseMs
}

public final class SenseControllers: @unchecked Sendable {   // locked inside; render thread polls
    public init(configuration: SenseConfiguration = .init())
    public var configuration: SenseConfiguration { get set }  // live tuning
    public func makeTrackingProvider() async -> AccessoryTrackingProvider?
    public func consumeAnchors(from provider: AccessoryTrackingProvider) async
    public func controllersChanged() -> Bool       // call per frame; true → rebuild provider
    public func forgetPoses()
    public func state(_ hand: SenseHand, at time: TimeInterval) -> SenseHandState
    public func ghostSample(_ hand: SenseHand, at time: TimeInterval) -> SenseGhostSample?
    public func rumble(_ hand: SenseHand, amplitude: Float, seconds: Double)
    public func pumpHaptics()
    public var logger: ((String) -> Void)?
}
```

The adapter then becomes roughly: `state(.left/.right, at:)` → map `SenseButtons` to `OVRPRawButton` →
`kl_ovrp_set_controller_input`, and `kl_ovrp_haptics_pull` → `rumble`.

## Plan

1. **Verify first**: the pending headset tests (mid-game power-on, hands open, IEYTD+FXAA), so that
   verified behaviour is what gets moved.
2. Create the repo with the package skeleton, licences, types, and unit tests for the pure maths
   (grip correction, mirror, velocity gate, prediction cap, button mapping). This is the port of the
   relevant `t_haptics.c` cases.
3. Move the code in one cut, behaviour unchanged: the same defaults and the same logs on the
   `[cp]` channel, via the adapter.
4. Repoint `gen_xcodeproj.py` and the four xcodeprojs at the pinned package, then build every target.
5. Headset A/B: poses, buttons, hot-plug and haptics should all match the pre-move build.

## Decisions
- Repo: `NSCabezon/SenseKit`; skeleton pushed (fe4945a).
- Hand-tracking fallback: **not** in phase 1; stays in Klepton.
- Minimum OS: **visionOS 26+** (decided 2026-10-13). The package drops the `#available(visionOS 26.0, *)` guards.


## 2026-10-15: ghost controllers

The scope grows by one thing that was Klepton-only in `KleptonHUD.swift`: the **ghost controllers**,
the in-code PSVR2 Sense model drawn at a resting controller's real pose so it can be found in full VR,
hidden the moment it is picked up. Moved into SenseKit so another visionOS app can reuse it (the Mac
streaming client, a guest of its own), in three pieces:

- `SenseGhost.swift`: `SenseGhostConfiguration` (every threshold, window, the fade, the model's fit
  and the colours), `SenseGhostHandState` (the per-hand in-hand state machine with its hysteresis,
  a straight port of `KLGhostHand`), `SenseGhosts` (both hands plus the frame clock) and
  `SenseGhostHands.palm(_:)` (the palm centre off a `HandAnchor`).
- `SenseGhostMesh.swift`: the pure geometry (capsule grip, tracking ring, top disc; interleaved
  position/normal/uv and a UInt16 triangle list, winding checked against the normals), API-neutral
  so a RealityKit app can build a `MeshResource` from it.
- `SenseGhostRenderer.swift`: the Metal drawing (`import Metal`), body then rim with front-face
  culling, premultiplied blend, reverse-Z depth with the `depthOverScene` swap, vertex amplification,
  into an encoder the app already has open.

Behaviour on the headset is unchanged: same thresholds, hysteresis, fade, colours, rim trick, depth
handling and `[ghost]` log lines. The package still reads **no environment variables**: Klepton's HUD
maps `KL_GHOST_INPUT_S`, `KL_GHOST_SHOW_S`, `KL_GHOST_PLATFORM_HELD`, `KL_GHOST_ROT` and
`KL_GHOST_POS` into a `SenseGhostConfiguration`, keeps `KL_GHOST_CTRL` (live on/off) and
`depthOverScene` for itself, and routes `SenseGhosts.logger` to `NSLog("[ghost] …")`. Metal joins the
package's framework list (GameController + ARKit + CoreHaptics + Metal); the state machine and the
mesh are covered by unit tests in `SenseGhostTests.swift`.
