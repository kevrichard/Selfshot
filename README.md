# SelfShot

A small iOS camera app built for one job: taking good photos of yourself when
nobody else is holding the phone.

Built to be compiled **without a Mac** — GitHub Actions does the macOS build,
you sign and install from Windows.

---

## What it does

- **Front camera by default**, because you need to see the preview when the
  phone is propped up across the room. Lens distortion comes from *proximity*,
  not from which camera you use — so front camera at 6 feet is flattering,
  while rear camera at arm's length is not.
- **Rear 1x / 2x / 4x** when you do have a place to stand the phone. 4x is
  roughly a 100mm equivalent, the classic portrait focal length.
- **A countdown you can actually read from across the room** — 260pt digits.
- **Burst instead of single shots.** Default is 10 frames at ~0.35s spacing.
  You get expressions mid-movement instead of one frozen pose.
- **Max-resolution capture.** Queries `supportedMaxPhotoDimensions` and
  requests the largest the active format offers (48MP on Pro rear cameras,
  18MP on the iPhone 17 front camera), with quality prioritization and
  deferred processing so the burst doesn't stall.
- **Tap to focus, then lock.** Tap the spot you'll be standing in, hit the
  lock chip, and focus/exposure/white-balance freeze. Without this the camera
  refocuses on the wall behind you the moment you step out of frame, and
  exposure drifts between burst frames.
- **Audio countdown.** Ticks on the final three seconds, a tone at zero, a
  shutter click per frame, and a chime between rounds — so you can shoot with
  your back to the phone instead of squinting at it.
- **Interval mode.** Set Rounds to 5 and it fires a burst every ~6 seconds.
  Change pose or position between rounds; one press gets you 50 frames across
  5 setups. For solo shooting this is the most useful thing in the app.
- **Grid + horizon level.** Rule-of-thirds guides and a level bar that turns
  yellow within a degree of flat. Tilt is the classic propped-phone giveaway.
- **4K video mode** — record 30 seconds of yourself moving, then scrub and
  export the best frames. Usually beats any photo you'd have posed for.
- **Real lens switching, not digital crop.** On a virtual multi-camera device
  raw zoom 1.0 is the *ultra-wide*, so a naive `videoZoomFactor = 4` lands in
  the wrong place. SelfShot reads `virtualDeviceSwitchOverVideoZoomFactors`
  and snaps to them, so 4x genuinely engages the telephoto. 8x is there too
  (200mm — needs about 20 feet, so situational).

## The APIs it demonstrates

| Thing | API |
|---|---|
| Max resolution | `AVCaptureDevice.activeFormat.supportedMaxPhotoDimensions`, `AVCapturePhotoOutput.maxPhotoDimensions` |
| Quality vs. speed | `photoQualityPrioritization = .quality` |
| Burst without stalling | `isAutoDeferredPhotoDeliveryEnabled`, `didFinishCapturingDeferredPhotoProxy` |
| No first-shot lag | `setPreparedPhotoSettingsArray` |
| Lens switching | `.builtInTripleCamera` virtual device + `videoZoomFactor` |
| iPhone 17 front camera | `.builtInUltraWideCamera` at `.front` (the square Center Stage sensor) |
| Preview mirroring | `AVCaptureConnection.isVideoMirrored` |
| True optical lens snapping | `virtualDeviceSwitchOverVideoZoomFactors`, `constituentDevices` |
| Tap to focus / AE-AF lock | `focusPointOfInterest`, `exposurePointOfInterest`, `.locked` modes |
| Screen-to-sensor coordinates | `captureDevicePointConverted(fromLayerPoint:)` |
| Horizon level | `CMMotionManager.deviceMotion.gravity` |

---

## Setup (Windows, ~30 minutes, $0)

### 1. Push this to GitHub

Create a **public** repo (macOS runner minutes bill at 10x on private repos)
and push these files. The Actions workflow fires on push to `main`.

### 2. Grab the build

Actions tab → latest run → download the `SelfShot-ipa` artifact → unzip it.
You now have `SelfShot.ipa`, unsigned. Build takes roughly 5–8 minutes.

### 3. Install Sideloadly (one time)

1. Install Apple's **Apple Devices** app from the Microsoft Store (provides the
   USB driver).
2. Install **Sideloadly**.
3. Plug in the iPhone, trust the computer.
4. On the phone: **Settings → Privacy & Security → Developer Mode → on**,
   then reboot.

### 4. Sign and install

Drop `SelfShot.ipa` into Sideloadly, enter your Apple ID, hit Start. It signs
with a free development certificate and installs over the cable.

First launch: **Settings → General → VPN & Device Management** → trust your
developer certificate.

### 5. Deal with the 7-day expiry

Free certificates die after 7 days. Two options:

- Re-run Sideloadly weekly (30 seconds, cable required), or
- Install **AltStore** + AltServer on Windows — AltServer re-signs silently
  over WiFi whenever the phone is on the same network. Set once, forget.

---

## Known caveats

**This code has never been compiled.** It was written without a Mac or an iOS
SDK available, so treat the first CI run as the real test — expect one or two
build errors to fix. The APIs used are all stable and long-standing, which is
deliberate: newer iOS 26/27 camera APIs (`AVCaptureSmartFramingMonitor`,
`dynamicAspectRatio`, cinematic capture) were left out on purpose so the first
build has the best chance of succeeding. They're easy to add once it's green.

**Free-account limits.** No push notifications, no iCloud, no App Groups
(so no widgets). Camera, Photos and HealthKit all work fine.

**Iteration is slow.** ~10 minutes per change through CI, and no debugger.
Fine for occasional tweaks, painful for real development. That's the argument
for a Mac mini later, if this turns into something you actually use.

## Possible v2

- HealthKit read access, to correlate whatever you want with your own data
- Apple's on-device Foundation Models (iOS 26+) for free local inference
- Auto-export best frames from a 4K clip
- ProRAW toggle, if you ever want to edit seriously
- Voice trigger via the Speech framework
