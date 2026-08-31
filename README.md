# Parking Sentry

An iOS/iPadOS app that watches a scene through the front or rear camera and alerts you when a **person** walks into it — with a distance estimate, and without firing on shadows, headlights, blowing trash, or swaying branches.

Everything runs on-device. No video ever leaves the phone.

---

## Build and install

1. Copy the `ParkingSentry` folder to the Mac.
2. `open ParkingSentry/ParkingSentry.xcodeproj`
3. Select the target → **Signing & Capabilities** → check *Automatically manage signing* and pick your Apple ID team. Change the bundle ID if `com.connorsharp.parkingsentry` is taken.
4. Plug in the iPhone or iPad, pick it as the run destination, hit **⌘R**.
5. On the device: Settings → General → VPN & Device Management → trust the developer certificate.

A free Apple ID signs for 7 days before the app needs a re-run from Xcode. A paid developer account signs for a year.

Requires iOS/iPadOS 17 or later.

---

## How it avoids false alarms

The pipeline is four stages, and an alert only fires when all four agree.

**1 — Motion gate with shadow rejection.** Every frame is downsampled to a 64×48 luma grid and compared against a slowly-learned background. A cast shadow scales a pixel's brightness by a roughly constant factor; a real object replaces the pixel outright. Any pixel that merely dimmed to between 38% and 93% of its learned background is classified as shadow and discarded before it can contribute to the motion score. The UI shows a live `shadow-rejected` percentage so you can watch this working.

**2 — Vision human confirmation.** Only when the gate trips does Apple's Vision framework run, and only on a padded crop around the moving region. `VNDetectHumanRectanglesRequest` finds human torsos. A shadow has no torso, a headlight sweep has no torso, and a plastic bag has no torso, so none of them survive this stage at any confidence setting.

**3 — Pose corroboration.** A body-pose pass counts recognizable joints inside the same box. A detection with fewer than two confident joints has to clear an 80% rectangle confidence to be believed at all.

**4 — Temporal persistence.** Detections are matched frame-to-frame by overlap into tracks. A track must be re-seen on N separate frames (default 3) before it can alert. Single-frame flukes — a raindrop on the lens, an insect, a glare frame — never reach the alert path.

Cats and dogs are separately classified and suppressed by default.

## How it measures distance

Two independent methods, best-available:

- **LiDAR** on Pro iPhones and iPad Pros. True measurement, but the sensor tops out around 5 metres — useful for confirming something is right on top of you, not for the far end of a lot.
- **Optical** everywhere else. The app reads the camera's own intrinsic matrix from each sample buffer to get the focal length in pixels, then solves `distance = (person height × focal length) ÷ apparent pixel height`. If the intrinsic matrix is withheld it falls back to deriving focal length from the active format's field of view.

Expect roughly ±10–15% for a fully-visible standing adult. Two things break it, and both are handled explicitly: if the subject is clipped by the top or bottom frame edge the height cue is meaningless, so the app reports *range unknown* rather than inventing a number; and if the person is crouching or sitting, the assumed-height setting is wrong — adjust it in Settings if you're monitoring a specific person.

**Usable range.** At 1080p a person is about 79 pixels tall at 30 m and 47 px at 50 m, which is past what Vision detects reliably. Leave **Long range (4K capture)** on and the same person is ~158 px at 30 m and ~95 px at 50 m. Practical ceiling with 4K and a wide lens is roughly 45–55 m in good light. Optical zoom (the 2× or 5× lens) extends that; digital zoom does not — it just enlarges pixels Vision already couldn't use.

---

## Field setup for a parking lot

- Mount the device landscape on a tripod, lens roughly chest height, aimed down the lot so approaching people grow in frame rather than crossing it.
- Frame so the ground plane fills the lower half. If people enter already clipped at the bottom edge you lose range accuracy on first contact.
- Hit **Arm**, then walk out of frame — the default 15 s arming delay covers that, and the background model finishes learning during it.
- Put a webhook URL in Settings (an `ntfy.sh/some-private-topic` URL works with no account) so the alert reaches the phone in your pocket while the iPad sits out there. Install the ntfy app on the phone and subscribe to the same topic.
- The refresh button re-learns the background. Press it after moving the device, after a lighting change, or if the sun moves enough to shift the whole scene.

**The app must stay in the foreground.** iOS suspends camera access for backgrounded apps, so screen lock is disabled while the app is open. Plug into power for anything longer than an hour or two — 4K capture plus Vision is genuinely demanding.

---

## Tuning

| Symptom | Change |
|---|---|
| Missing people at the far end | Long range mode on; raise optical zoom; lower person confidence to ~0.4 |
| Firing on headlights or reflections | Raise confirm frames to 5; raise person confidence |
| Firing on nothing visible | Raise motion sensitivity; watch the shadow-rejected readout |
| Range reads consistently low or high | Adjust assumed person height |
| Repeat alerts for one loiterer | Raise per-subject cooldown |
| Only care about people coming toward you | Turn on *Only alert when closing in* |

The `motion` and `shadow-rejected` numbers in the top-left are live diagnostics — tune against them rather than guessing.

---

## Known edges

- Depth is opportunistic. The session is configured by preset, not by explicitly selecting a depth-capable `activeFormat`, so on some devices LiDAR may not attach and the app will fall back to optical ranging. The badge in the top-right tells you which is live.
- Vision is trained on upright humans. Someone crawling, prone, or fully behind a car will not be detected.
- Heavy rain or fog degrades both stages; expect shorter effective range.
- None of this has been compiled or run against a device in the session that produced it — the first build on the Mac is the real test.
