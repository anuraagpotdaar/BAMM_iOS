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
    JointFrame.swift                     22-joint frame value type
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
