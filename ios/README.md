# SpeedGun — iOS app

Native iOS app, same DSP as the web tester but with `AVAudioSession`
configured `.defaultToSpeaker` so output actually goes to the loud main
speaker instead of the earpiece Safari gets stuck with.

## Requirements

- macOS with Xcode 15 or later
- Physical iPhone (iOS 16+). **Simulator won't work** — no real speaker
  or mic at ultrasonic frequencies.
- Apple Developer account, free tier is fine for testing on your own
  iPhone. Paid ($99/year) required to ship to the App Store.

## Build and run

1. `git pull` in `~/speedgun` on your Mac (or clone fresh:
   `git clone https://github.com/claudecoder1117/speedgun`).
2. Open `ios/SpeedGun.xcodeproj` in Xcode.
3. Select the SpeedGun target → Signing & Capabilities → pick your Team.
4. Plug in your iPhone, pick it as the run destination, hit ⌘R.
5. First launch: accept the mic permission prompt. Tap Start.

## If the `.xcodeproj` doesn't open

Xcode project files (`project.pbxproj`) are fussy — the version in this
repo was hand-written and validated structurally, but only actual Xcode
can confirm it loads cleanly. If Xcode refuses to open it, fallback:

1. **File → New → Project → iOS → App.** Name: `SpeedGun`. Interface:
   SwiftUI. Language: Swift. Bundle ID: `com.claudecoder1117.speedgun`
   (or whatever).
2. Delete the auto-generated `ContentView.swift` and `SpeedGunApp.swift`.
3. Drag these files from `speedgun/ios/SpeedGun/` into the Xcode project
   navigator (check "Copy items if needed"):
   - `SpeedGunApp.swift`
   - `ContentView.swift`
   - `DopplerEngine.swift`
4. In the target's Info tab (or Info.plist), add the key
   **Privacy - Microphone Usage Description** with a value like
   "SpeedGun listens for its own ultrasonic reflections to measure speed."
5. Set deployment target to iOS 16.0.
6. Run on your iPhone.

## Layout

```
ios/
├── SpeedGun.xcodeproj/
└── SpeedGun/
    ├── SpeedGunApp.swift      — @main entry point (5 lines of SwiftUI App scaffold)
    ├── ContentView.swift      — SwiftUI UI: big speed, Start/Stop, settings drawer
    ├── DopplerEngine.swift    — AVAudioEngine + Accelerate FFT + Doppler math
    └── Assets.xcassets/       — empty asset catalog (no icon yet; add before App Store)
```

## Known: before App Store submission

- App icon (`Assets.xcassets/AppIcon.appiconset`) is empty. Xcode will
  build fine for device testing, but submission requires a 1024×1024 PNG.
- Privacy policy URL needed in App Store Connect.
- Screenshots (3–5 from an actual device).
