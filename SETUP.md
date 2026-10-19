# AR SMPL — iOS port setup

iOS port of `ar_core_demo` (SwiftUI + ARKit + SceneKit). Streams BAMM motion
frames onto a rigged GLB humanoid in either an AR scene (anchored to a tapped
plane) or a 3D scene (orbit camera over a baked sci-fi backdrop).

## One-time setup

This machine currently has `xcode-select` pointing at the Command Line Tools,
which can't load Xcode's IDE plugins. Switch to the Xcode.app developer dir:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then verify:

```sh
xcodebuild -version            # should print "Xcode 26.x"
xcrun --sdk iphoneos --show-sdk-path
```

## Generate / regenerate the Xcode project

The project is driven by `project.yml`. Re-run after any `project.yml` edit:

```sh
xcodegen
```

This produces `ARSmpl.xcodeproj`. The first build will resolve the
[GLTFSceneKit](https://github.com/magicien/GLTFSceneKit) Swift package — that
takes a minute on cold start.

## Build & run

Open in Xcode:

```sh
open ARSmpl.xcodeproj
```

Pick your device or a simulator and hit ⌘R.

**ARKit needs a real device** — the camera passthrough won't work in the
simulator. The 3D mode (orbit camera over the baked scene) does work in the
simulator, which is useful for verifying GLB load + pose math without needing
to point a phone at the floor.

Or build from CLI:

```sh
xcodebuild -project ARSmpl.xcodeproj -scheme ARSmpl \
           -destination 'generic/platform=iOS' \
           CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
           build
```

## BAMM backend

The app calls a BAMM Flask server at `http://localhost:7860` by default.

- **iOS Simulator:** `localhost` reaches your Mac directly. Just run `python
  app.py` in `BAMM_Replication/` and you're done.
- **Physical device:** `localhost` resolves to the phone, not your Mac. Get
  your Mac's LAN IP (`ipconfig getifaddr en0`) and enter
  `http://<that-ip>:7860` in the in-app "Change server URL" dialog from the
  welcome screen.

The Info.plist sets `NSAppTransportSecurity > NSAllowsArbitraryLoads = true`
to allow cleartext HTTP to the dev server (matches the Android side's
`usesCleartextTraffic="true"`).

## Project layout

```
project.yml                              XcodeGen spec
ARSmpl/
  Info.plist
  ARSmplApp.swift                        @main, WindowGroup
  ContentView.swift                      Welcome ↔ ARMain switch + AppState
  Welcome/
    WelcomeScreen.swift                  mode picker + server-status dot
    BackendUrlDialog.swift
  AR/
    RigAndScene.swift                    enums + BODY_COLORS + MOTION_PRESETS
    RigLoader.swift                      GLTFSceneKit loader + tint capture
    SceneCoordinator.swift               shared scene/render-loop driver
    ARSceneViewRepresentable.swift       UIViewRepresentable wrapping ARSCNView
    SceneKit3DViewRepresentable.swift    UIViewRepresentable wrapping SCNView
  Bamm/
    JointFrame.swift                     SOMA 77-joint frame value type (absent joints = NaN)
    PendingFrameBox.swift                OSAllocatedUnfairLock<JointFrame?>
    BammClient.swift                     URLSession async/await
    BammSession.swift                    @Observable state + polling/playback Tasks
  Pose/
    SkeletonTopology.swift               SKELETON_PARENT, UPDATE_ORDER, aliases
    BoneBinder.swift                     SCNNode tree walk + name dictionary
    RigPoseApplier.swift                 simd port of RigPoseApplier.kt
  UI/
    ARMainView.swift                     scene + overlays orchestrator
    SettingsSheet.swift
    TransformEditor.swift                rot/scale/pos editor
    StatusOverlay.swift
    IntroOverlay.swift
    LoadingOverlay.swift
    MotionChipsStrip.swift
    ScaleFAB.swift
    ErrorBar.swift
  Storage/
    TransformStore.swift                 UserDefaults key→Float
    BackendUrlStore.swift                UserDefaults string + recents
  Resources/
    Models/                              smpl.glb, soldier.glb, scene.glb,
                                         scene_gallery.glb (folder reference)
    Textures/                            sky.jpg, ground.jpg
```

## Avatars

| Rig | File | Bones the pose driver binds to |
|---|---|---|
| SMPL | `Resources/Models/smpl.usdz` | `Pelvis`, `L_Hip`, … |
| Soldier | `Resources/Models/soldier.usdz` | `mixamorig:*` |
| Miyako | `Resources/Models/miyako.usdz` (20 MB) | Rigify deform bones `DEF-spine`, `DEF-thigh.L`, … (`SkeletonTopology.aliases`) |

Miyako is a Sketchfab "Blue Archive Miyako" character. Its USDZ/FBX downloads carry the
armature without skin weights, so the app's copy is re-exported from the source `.blend`
with `GEMX_ONNX/tools/blender_export_usdz.py` (Blender ≥ 4.2, installed via
`brew install --cask blender`):

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b miyako_release.blend \
  -P ~/Developer/GEMX_ONNX/tools/blender_export_usdz.py -- miyako.usdz
```

The script keeps the generated Rigify armature + skinned meshes, re-parents every DEF bone
to its nearest DEF ancestor (Rigify parents them to ORG/MCH control bones the driver never
rotates), exports deform bones only, Y-up, with textures. Any Rigify character exported
this way should bind the same bones (body, `DEF-spine.005` neck, eyes and the 30 finger
phalanges; Rigify has no finger-tip bones, so the distal phalanges stay at bind). The pose
driver reads every bone's real SceneKit parent transform (Blender's Y-up export adds a −90° X
rotation on `root`; Rigify adds `.001` segment and palm helper bones) and ignores `outline`
materials when tinting.

## Playback transport

Any finished motion (GEM-X results in every mode, hosted/on-device BAMM clips) shows a
video-player style scrubber above the input row in AR, 3D and Overlay views
(`UI/PlaybackScrubber.swift`): play/pause, position slider, time/duration and a loop
button. Auto replay is the default; with loop off playback stops on the last frame. The
session owns the transport (`BammSession.seek(frame:)`, `playbackPaused`, `playbackLoop`,
`playbackFrame/Count`); in the Overlay view the video player is the clock, so the overlay
coordinator implements `PlaybackTransport` (seek/pause/loop on the AVPlayer) and reports the
current frame back to the session.

## GEM-X (video → motion)

Pick **GEM-X** in the model picker. The input is a video clip (Photos or Files)
instead of a text prompt; the result is the SOMA 77-joint skeleton, which is also the
app's canonical skeleton (`SkeletonTopology`): all 77 joints, fingers included, drive the
rig where the avatar has the bones (Soldier: 40 finger bones, Miyako: 30, SMPL: none).
BAMM/MMM sources only provide the 22 HumanML3D body joints (`JointFrame.fromHumanml22`);
their finger/neck2/toe-end bones stay in the bind pose. GEM-X motion faces the video
camera (-Z); the parser turns it 180° so the avatar faces the viewer.

| Mode | What runs | URL |
|---|---|---|
| Local | `BAMM_API/services/csgpu_serve.py` with `SERVICE=gemx` (port 8000) on a LAN box or this Mac | `http://<lan-ip>:8000` |
| Hosted | Modal deployment of `services/gemx/service.py` | `https://…modal.run` |
| On-device | `OnDeviceGemxClient` (ONNX Runtime, no network) | — |

Local/Hosted both use `HostedGemxClient` (`POST /generate` multipart with
`frames=global,incam`, progress from `GET /progress/<job_id>`); the service answers
JSON `{bvh, bvh_incam, width, height, K}` so the overlay view has the camera-frame
motion (an older server that returns plain BVH still works, minus the overlay).

**Views.** AR and 3D as before; with GEM-X selected a third **Overlay** view is
offered (welcome screen / Settings → View): the clip plays full-screen and the
avatar is drawn over the person from the in-camera motion
(`AR/OverlaySceneViewRepresentable.swift`: AVPlayerLayer + transparent SceneKit view
with a projection built from K; frames follow the video clock). The color button on
the main screen is a menu of body colors (tap cycles). Settings → GEM-X exposes static-camera, server
denoiser (pytorch/onnx), skip-image-features, and for on-device the denoiser
tier (fp16/int8), where the 2D pose model runs (Neural Engine / CPU), the flip
test, the 2D-pose stride (per 30 fps; scaled to the clip's rate) and the decode resolution.
Clips at other frame rates are solved on a 30 fps timeline (the denoiser's training rate)
and clips longer than 900 frames go through the denoiser in overlapping windows.

On-device artefacts live in `ARSmpl/Resources/Gemx/` (~1 GB, folder reference,
produced by the GEMX_ONNX step-3 script and `tools/export_vitpose_coreml.py`):

```
vitpose_w8.mlmodelc/                           ViT-H 2D pose as CoreML, int8 weights (810 MB; ≈45 ms/frame on an M2 Neural Engine)
gem_denoiser_no_imgfeat_fp16_band_u8.onnx      denoiser fp16, band mask as uint8 (90 MB)
gem_denoiser_no_imgfeat_int8_band_u8.onnx      denoiser int8 (54 MB)
x_mean.f32 x_std.f32 lut_*.f32 joint_*.{i32,txt}  tables (3 MB)
```

Pipeline files: `Bamm/GemxVideo.swift` (AVFoundation decode, Vision person
boxes), `Bamm/GemxPipeline.swift` (crop, flip test, heatmap decode, interpolation, 30 fps
timeline, band mask, decode, skeleton LUT, FK, grounding, BVH writer), `Bamm/GemxMath.swift`,
`Bamm/GemxVitPoseCoreML.swift` (CoreML pose model), `Bamm/OnDeviceGemxClient.swift`
(sessions, pipelined VitPose, windowed denoiser, orchestration). The old CPU int8 ONNX
VitPose path is still in the code (`GemxPoseBackend.onnx`, harness `GEMX_POSE=onnx`) but
its 877 MB model is no longer bundled.

### On-device benchmark (real iPhone)

`Bamm/GemxBenchmark.swift` runs the on-device pipeline over the clips bundled in
`Resources/BenchClips/` with a matrix of pose model (CoreML w8 / fp16) × compute units ×
flip test × denoiser tier × stride, writes `Documents/gemx_bench/<runId>/results.jsonl`
(+ one BVH per run) and logs `[GemxBench] RESULT …` lines. Launch arguments:
`-gemxBench full|quick|<name,name,…>` and `-gemxBenchResume <runId>` (skips finished runs).
`~/Developer/gem-x-ondevice-benchmarks/run_device_bench.sh [full|quick] [install]` builds
nothing: it installs the current device build, launches with `--console`, relaunches with
resume if the app dies, and pulls the results with `devicectl device copy from`;
`make_report.py <runId>` turns them into `report.md`. The device build needs a team:
`xcodebuild … -destination 'id=<udid>' DEVELOPMENT_TEAM=4WBRQ9P4WH CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`
(the personal team that already has a profile for `com.example.arsmpl`). `BenchClips` (40 MB) are in the bundle
only for benchmarking. The fp16-weight pose model and the GPU compute-unit choice were removed
after the first device run (wrong output on the ANE; 2.5 s/frame and overheating respectively).
The video reader survives app suspension: on "Operation Interrupted" it waits for the app to be
active again and resumes from the last delivered frame (`GemxVideoReader.forEachFrame`).

### Smoke test without touching the UI

```sh
# Simulator: runs the clip on launch in 3D mode, logs "[GemxAuto] …" lines, grabs a screenshot.
# The Simulator has no Neural Engine (CoreML ≈1.2 s/frame on its CPU path): use the 6 fps clips,
# FLIP=0 (default) and STEP=3; -gemxAutoStep / -gemxAutoFlip are the launch arguments behind them.
~/Developer/GEMX_ONNX/swift/sim_smoke.sh ~/Developer/GEM-X/sample_inputs/test3_demo_6fps.mp4 onDevice
~/Developer/GEMX_ONNX/swift/sim_smoke.sh clip.mp4 hosted http://127.0.0.1:8000
# 5th argument picks the view: 3d (default) or overlay
~/Developer/GEMX_ONNX/swift/sim_smoke.sh clip.mp4 onDevice "" 60 overlay
```

The same Swift sources are compiled into a macOS harness
(`~/Developer/GEMX_ONNX/swift/GemxHarness`, `./sync.sh && swift build -c release`)
that checks every stage against the Python reference pipeline.
