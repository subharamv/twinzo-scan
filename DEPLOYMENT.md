# Getting Twinzo Scan onto a device

Everything below assumes you are starting on the Windows machine the code was
written on. The app cannot be built or run on Windows — see [Testing](README.md#testing)
for what can be verified there. This document covers getting it onto a Mac,
onto a phone, and then proving it actually works.

---

## 1. Export the code off Windows

### Option A — Git (recommended)

The repo is small (~2,700 lines, no binaries). Git is preferable to a zip
because CI runs on push, so the macOS build errors get caught before you sit
down at a Mac.

```sh
cd c:/Users/admin-it/Downloads/iosapp
git init
git add .
git commit -m "Twinzo Scan: AR BIM deviation analysis"
git branch -M main
git remote add origin https://github.com/<you>/twinzo-scan.git
git push -u origin main
```

`.gitignore` already excludes the generated `.xcodeproj`, `.build/`, and any
`.usdz` models. **Do not commit BIM models** — they are large, and usually
client-confidential.

Then on the Mac:

```sh
git clone https://github.com/<you>/twinzo-scan.git
cd twinzo-scan
```

### Option B — Zip

If there is no GitHub account in play:

```powershell
Compress-Archive -Path c:\Users\admin-it\Downloads\iosapp\* `
                 -DestinationPath c:\Users\admin-it\Downloads\twinzo-scan.zip
```

Transfer by AirDrop, USB drive, or cloud storage. Note you lose the CI safety
net this way, so expect to fix any build errors interactively at the Mac.

---

## 2. Set up the Mac

Required:

| | |
|---|---|
| macOS | Sonoma 14 or later |
| Xcode | 15 or later, from the Mac App Store |
| Command line tools | `xcode-select --install` |
| Homebrew | https://brew.sh |
| XcodeGen | `brew install xcodegen` |

Generate and open the project:

```sh
xcodegen generate
open TwinzoScan.xcodeproj
```

`TwinzoScan.xcodeproj` is generated, not committed. Regenerate it any time you
add source files — Xcode will not pick them up otherwise.

---

## 3. First build — expect errors here

This code has never been compiled. The likeliest failures are in the RealityKit
and ARKit API surface:

- `MeshDescriptor.materials = .perFace(...)` — API name may differ by SDK version
- `ARMeshGeometry` buffer accessors (`vertices.stride`, `faces.bytesPerIndex`)
- `UnlitMaterial.blending` opacity construction

Build for a generic device first, which surfaces compile errors without needing
a phone plugged in:

Product → Destination → **Any iOS Device (arm64)**, then ⌘B.

Work through the errors before going near hardware. They are type and naming
issues, not logic — the algorithms are covered by the test suite.

---

## 4. Signing

In Xcode: select the **TwinzoScan** target → **Signing & Capabilities**.

- Tick **Automatically manage signing**
- Pick your **Team**
- Change the bundle ID if `com.twinzo.scan` is taken:
  `com.<yourcompany>.twinzoscan`

| Account type | Install duration | Devices |
|---|---|---|
| Free Apple ID | **7 days**, then the app stops launching | 3 apps at a time |
| Apple Developer Program ($99/yr) | 1 year | 100 devices, TestFlight |

A free account is fine for evaluating this. For anyone doing real site work,
the 7-day expiry becomes intolerable quickly.

---

## 5. Install on the device

Requires a **LiDAR** device — iPhone 12 Pro/Pro Max or later Pro, or iPad Pro
2020 onward. A non-Pro iPhone will install and then refuse to start the session,
reporting exactly that.

1. Connect by USB-C/Lightning, unlock, **Trust This Computer**
2. Select the device in Xcode's destination menu
3. ⌘R
4. First run only: on the phone, Settings → General → VPN & Device Management →
   trust your developer certificate
5. Accept the camera permission prompt

Once installed, unplug it. The app does not need Xcode attached to run.

---

## 6. Prepare a test model

Do **not** start with a real site model. Start with something whose true answer
you already know.

### Bench model

In any CAD tool, model a **single flat wall panel matching a real wall you have
access to** — an office wall, a garage wall. Export as USDZ:

```
Revit / SketchUp / Blender  →  IFC or FBX  →  USDZ
```

Reality Converter (free from Apple's developer downloads) handles FBX/OBJ→USDZ
by drag and drop. `usdzconvert` from Apple's USD tools does it on the command
line.

Check before loading:

- **Units are metres.** Revit commonly exports millimetres or feet. The loader
  rejects anything over 5 km on its longest axis, which catches millimetres, but
  a feet→metres error is only 3.3x and passes silently.
- **Model the bay, not the site.** The BVH is built on device at load and the
  whole model stays in GPU memory.

---

## 7. Bench test — before going to site

This is the sequence that tells you whether the app works. Do it somewhere you
can put a tape measure on things.

### 7a. Does it scan?

Launch, walk a room slowly. The status line should show scan points climbing
into the thousands. If it stays at zero, LiDAR is not producing mesh — check the
device is genuinely a Pro model.

### 7b. Does it align?

1. Import your wall USDZ
2. Tap the floor near the real wall to drop the model
3. Two-finger drag to slide, twist to rotate, height buttons to lift
4. Get it visually close — within ~10 cm and a few degrees
5. Tap **Align**

Expect: status turns green, "Aligned — N mm RMS", with N in single or low double
digits.

If it reports a rejection instead, that is the app working correctly. Read the
reason — it will say whether the residual was too high or too little of the scan
matched.

### 7c. **The test that actually matters — known deviation**

Colours looking plausible proves nothing. Measure something.

1. Tape a **known thickness** to the wall — a 20 mm book, a 50 mm block of wood.
   Measure it with calipers or a tape.
2. Do **not** put it in the model. The model stays a flat wall.
3. Scan the wall including the object, align, and read the app.

**Pass:** the object shows as a warm/red patch, and the settings sheet's worst
finding reports within roughly ±10 mm of your measured thickness.

**Fail:** the reading is wildly off, or the whole wall lights up. See
troubleshooting below.

Until this test passes, treat every number the app produces as unverified.

### 7d. Does it hold up?

- Walk the full room. Does it stay at a usable frame rate?
- Walk 10 m away and back. Does the model still sit on the wall, or has ARKit
  drift pulled it off? Some drift is expected and is why re-alignment exists.
- Set tolerance to 10 mm, then 50 mm. The colouring should change accordingly.
- Point at a chair or a person. They should fade to near-transparent, not turn
  red — that is the rejection radius doing its job.

---

## 8. Site test

Only after the bench test passes.

1. **Scan first, align second.** Walk the bay before touching alignment. ICP
   needs geometry to work with, and the *Align* button stays disabled until
   there are enough points.
2. **Place the model against something unambiguous** — a corner, a column base,
   a door reveal. Not a long blank wall: it slides along its own length and
   leaves the fit unconstrained in that axis.
3. **Re-align when you move to a new area.** ARKit drift over a long walk is
   real. An alignment established at one end of a bay degrades at the other.
4. **Read the inlier percentage, not just the RMS.** A low residual over 40% of
   the scan is worse than a slightly higher one over 95%.
5. **Export** from the settings sheet → *Export findings as CSV*. Coordinates
   come out in model space, so they line up with the BIM model rather than with
   wherever the AR session happened to start.

---

## 9. Sharing it with colleagues

### TestFlight (needs paid account)

```sh
xcodebuild archive \
  -project TwinzoScan.xcodeproj \
  -scheme TwinzoScan \
  -destination 'generic/platform=iOS' \
  -archivePath build/TwinzoScan.xcarchive
```

Then Xcode → Window → Organizer → select the archive → **Distribute App** →
App Store Connect → Upload. Invite testers by email in App Store Connect.
This is the only sane route for more than one or two people.

### Direct install

Simplest alternative: have them bring the device, plug it in, ⌘R. Subject to the
same 7-day/1-year expiry as above.

---

## 10. Troubleshooting

| Symptom | Likely cause |
|---|---|
| "This device has no LiDAR scanner" | Non-Pro iPhone, or Simulator. No workaround. |
| Camera feed but no scan points | Camera permission denied, or too far from surfaces. LiDAR range is ~5 m. |
| *Align* button greyed out | Fewer than 500 scan points, or no model loaded. Keep walking. |
| "Only N% of the scan matched" | Coarse placement too far off, or the model covers a different area than you scanned. |
| "Residual too high to trust" | Wrong bay, wrong level, or wrong units on export. |
| Model is enormous or microscopic | Unit error on export. Millimetres and feet are the usual culprits. |
| Everything is red | Alignment is wrong, or tolerance is set absurdly tight. |
| Everything is transparent grey | Rejection radius too small, or model nowhere near the scan. |
| Colours look right, numbers are wrong | Do the 7c known-deviation test before trusting anything. |
| Drops frames while scanning | Lower `anchorBudgetPerFrame` in [ScanSession.swift](TwinzoScan/Sources/AR/ScanSession.swift), or load a smaller model. |
| App expires after a week | Free Apple ID. Re-install, or get a paid account. |

---

## 11. What this tool is and is not

Apple's LiDAR is a low-resolution time-of-flight sensor with centimetre-scale
noise that grows with range and degrades badly on dark, glossy and transparent
surfaces. The millimetre figures the app displays are the arithmetic of the
comparison — they are not a claim about achievable accuracy.

Use it to find **where** to bring a total station. Do not use it to sign off a
tolerance.
