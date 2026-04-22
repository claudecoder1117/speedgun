# speedgun

Ultrasonic Doppler speed gun. Emits an ~18 kHz tone from a phone/laptop
speaker and measures the frequency shift of the reflection off a moving
object to compute its speed.

## Try it

Web version (no install): **https://claudecoder1117.github.io/speedgun/**

Works best in Safari on iPhone or Chrome on a laptop. Requires HTTPS
(GitHub Pages provides this) for microphone access.

## Layout

- `docs/index.html` — web tester, served by GitHub Pages.
- `python/doppler_prototype.py` — DSP prototype with synthetic signals.
  Proves the math before porting to native.
- `ios/SpeedGun.xcodeproj` — native iOS app (SwiftUI + AVAudioEngine +
  Accelerate). Open in Xcode on macOS, select your signing team, run on
  an iPhone. See `ios/README.md` for build instructions and a manual-
  recreate fallback if the project file doesn't open cleanly.

## Physics

Emitted carrier `f0`, target moving at `v` toward the phone:

    f_reflected = f0 * (c + v) / (c - v)     (monostatic round-trip)

Invert from the measured peak:

    v = c * (f_peak - f0) / (f_peak + f0)

Sample rate is 48 kHz → Nyquist 24 kHz → `f0 = 18 kHz` gives ~6 kHz of
headroom for upshifts, which covers speeds up to ~110 mph before aliasing.
