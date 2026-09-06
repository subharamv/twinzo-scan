# Twinzo Scan

An iOS app that overlays a BIM model on the live camera feed, registers it to the
LiDAR point cloud, and computes as-built vs as-designed deviation in real time.

Swift 5.9 / SwiftUI / ARKit / RealityKit, with the distance field evaluated in
Metal Shading Language.

Deployment, device setup and the field test protocol are in
[DEPLOYMENT.md](DEPLOYMENT.md).

## Requirements

- A LiDAR device: iPhone 12 Pro or later Pro, or an iPad Pro from 2020 on.
  There is no useful degraded mode without a depth sensor.
- Xcode 15+, macOS.
- A BIM model converted to USDZ or `.reality`.

## Building

The Xcode project is generated rather than checked in, because `pbxproj` merges
badly and this tree is expected to gain files:

```sh
brew install xcodegen
xcodegen generate
open TwinzoScan.xcodeproj
```

Set your development team in the target's Signing & Capabilities, then run on a
physical device. The Simulator has neither ARKit world tracking nor a Metal
device, and the app will report that rather than showing a blank feed.

## Preparing a model

Revit and IFC do not load natively on iOS, so conversion happens offline:

```
Revit  ->  IFC or FBX  ->  USDZ        (Reality Converter, or usdzconvert)
```

Two things to check on the way out, because both produce silently wrong numbers
rather than visible errors:

- **Units.** Revit commonly exports in millimetres or feet. USDZ is metres. The
  loader rejects anything spanning more than 5 km on its longest axis, which
  catches the millimetre case, but a feet-to-metres error is only a 3.3x scale
  and will pass that check.
- **Scope.** Load the bay or level being inspected, not the whole site model.
  The BVH is built on device at load time and the whole model stays resident in
  GPU memory.

Models are imported through the Files picker, so they can come from iCloud, a
managed drive, or a twin backend that writes into the app's container.

## How to use it

1. **Scan.** Walk the space. The status line shows accumulated scan points.
2. **Place.** Tap the floor to drop the model, two-finger drag to slide it,
   twist to rotate, and the height buttons to lift it onto the right level.
   Only heading and position are adjustable: ARKit's world is gravity-aligned
   and so is the model, so tilt would only add error for ICP to remove.
3. **Align.** Once roughly in place, hit *Align*. Two ICP passes run on a
   background queue — a loose one to absorb placement error, a tight one to
   settle. The result is accepted only if the residual and the inlier ratio both
   pass; otherwise the app says why rather than reporting a confident wrong pose.
4. **Inspect.** Deviation colouring goes live. Green is within tolerance, warm
   colours are material closer to the scanner than designed, cool colours are
   material behind the design surface or absent. Surface with no modelled
   element within the ignore radius is faded out rather than flagged, so
   pallets, people and temporary works do not read as defects.
5. **Export.** The settings sheet lists the worst finding per scanned chunk and
   exports them as CSV in model coordinates.

## Testing

There is no way to compile or preview the iOS app on Windows: Xcode is macOS
only, and ARKit, RealityKit and Metal ship only in Apple's SDKs. Even on a Mac,
the Simulator has neither world tracking nor a Metal device, so the app needs a
physical LiDAR device to run at all.

What *can* be verified without Apple hardware is split across two layers.

### Layer 1 — geometry and registration, locally

**Status: 49 tests, all passing** against Swift 6.0.3. Verified by mutation
testing — see below.

The BVH, point-to-plane ICP and the scan cloud have no Apple dependency beyond
the `simd` module, and `Testing/SIMDShim` supplies that. The SwiftPM target is
named `simd`, so `import simd` in the production sources resolves to the shim
with **no edits to shipped code** — the tests compile the same files the app does.

Run it from WSL (the route that was actually used; see the note below on why not
Swift for Windows):

```sh
bash Testing/setup-wsl.sh     # once: toolchain + compatibility libraries
bash Testing/run-tests.sh     # the suite
bash Testing/run-tests.sh --mutate   # prove the suite can fail
```

| Suite | Tests | Covers |
|---|---|---|
| `MathShimTests` | 8 | The shim itself — composition order, handedness, orthonormality. Everything below is only as trustworthy as this. |
| `BVHTests` | 11 | Closest-point queries against exhaustive search; no triangle lost or duplicated in subdivision; leaf ranges partition the array exactly once. |
| `ICPTests` | 10 | Recovery of known transforms under clean data, 8 mm sensor noise, and 25% mid-air clutter. Plus: a grossly wrong placement must be *reported* as unacceptable. |
| `ScanCloudTests` | 12 | Voxel collapse, negative-coordinate binning, eviction cap, depth-confidence filtering, and that a downsampled cloud still registers. |
| `PointCloudPLYTests` | 5 | The binary PLY export: header count against payload length, exact float round-trip, model-space transform, and that a comment cannot break out into the header. |
| `DeviationStatisticsTests` | 12 | The weighted-mean merge behind the on-screen figures, pass-rate handling of clutter, and tolerance-threshold coherence. |

ICP error is measured as the worst displacement of the room's **corners**, not as
a matrix difference. A residual rotation of a fraction of a degree is invisible
in the matrix and tens of millimetres at the far wall — and the wall is what an
inspector looks at.

#### Mutation testing

A suite that passes on its first run has not been shown to work. Two deliberate
bugs were injected and both were caught:

| Mutation | Result |
|---|---|
| Flip the sign of the ICP residual (`rhs = -r` → `rhs = +r`) | 5 failures across `ICPTests` and `ScanCloudTests` |
| Traverse only the nearer BVH child, skipping the far subtree | 1 failure: `testMatchesBruteForceSearch` |

Restoring the sources returned the suite to 49/49.

#### Why WSL and not Swift for Windows

Swift on Windows has no linker or C runtime of its own: it uses MSVC's
`link.exe`, the UCRT headers and the Windows SDK import libraries. That means
Visual Studio Build Tools (~3 GB) on top of the ~1 GB toolchain. On Linux it is
one ~750 MB download and no MSVC at all.

One wrinkle worth knowing if you repeat this on a recent Ubuntu: releases after
24.04 have moved past the sonames the toolchain links against — `libxml2` is now
`.so.16` (package `libxml2-16`), and the 24.04 `libxml2` in turn wants ICU 74.
`setup-wsl.sh` fetches the 24.04 originals into `/opt/swift-compat/lib` and
exposes them through `LD_LIBRARY_PATH`. It does **not** symlink the new versions
over the old sonames: those bumps are deliberate ABI breaks, and symlinking
would trade an honest load-time failure for a crash inside the parser.

### Layer 2 — the iOS build, in CI

`.github/workflows/ci.yml` runs on push and does the parts Windows cannot:

- **`ios-build`** — XcodeGen plus `xcodebuild` on a macOS runner. This is what
  catches the RealityKit and ARKit API errors flagged under Known limitations.
- **`metal-shader`** — compiles `Deviation.metal` for iOS. A shader that fails to
  compile yields a nil pipeline and takes the whole deviation pass down at
  runtime.
- **`core-tests`** — the same `swift test` suite, on Linux for CI reliability.

Push from Windows, read the build log. No Mac required.

### What remains untested until a device

Everything that needs real hardware, which is most of the AR behaviour: LiDAR
mesh quality, ARKit drift over a long walk, whether the per-frame budget actually
holds 60 fps, and whether the deviation overlay reads clearly under factory
lighting. The Metal kernel's *traversal* is only exercised on device — the CI job
proves it compiles, not that it agrees with the Swift BVH. Keeping those two in
step is on you.

## Architecture

```
ARKit (LiDAR mesh + camera)
        |
        |  ARMeshAnchor, budgeted at 3 chunks/frame
        v
ScanSession  ------->  ScanCloud        voxel-downsampled world cloud, for ICP
        |
        |              AlignmentCoordinator
        |                  coarse: tap/drag/twist, gravity-constrained
        |                  fine:   PointToPlaneICP, 2 passes, background queue
        |                              |
        v                              v
DeviationEngine  <--- worldToModel ----+
        |  Metal compute, 1 thread/vertex
        v
Deviation.metal  -->  BVH traversal, closest point on triangle, band index
        |
        v
DeviationOverlay  -->  RealityKit mesh, per-face material segmentation
DefectLog         -->  worst vertex per chunk, CSV export
```

### Why these choices

**One BVH, two consumers.** `BVH.swift` builds a binned-SAH hierarchy over the
model's triangles once at load. The CPU walks it for ICP correspondences; the GPU
walks the identical flattened arrays for the per-frame distance field. Sharing
the structure is what keeps the alignment and the displayed numbers describing
the same surface. The closest-point-on-triangle routine is duplicated in Swift
and MSL and the two must be kept in step.

**Point-to-plane ICP, not point-to-point.** The target is a mesh, not a cloud.
Point-to-plane lets scan points slide along walls and floors instead of being
pinned to arbitrary nearest vertices, which converges in far fewer iterations on
the large flat surfaces that dominate industrial interiors.

**Coarse placement is mandatory.** ICP is a local optimiser. Cold-started in a
warehouse of near-identical bays it will converge one bay over and report an
excellent residual, which is the worst possible failure mode for an inspection
tool. The operator establishes the pose; ICP only refines it. For a repeatable
workflow, replace the manual step with surveyed reference points or fiducial
markers — the coordinator's `place(at:)` is the seam for that.

**Voxel downsampling before ICP.** Raw mesh anchors run to hundreds of thousands
of vertices, unevenly distributed — dense near the operator, sparse at range. A
5 cm grid caps the working set and equalises density, so distant geometry (which
is what actually constrains rotation) is not outvoted by the floor underfoot.

**Banded materials, not vertex colours.** RealityKit's `MeshDescriptor` exposes
per-face material segmentation but not per-vertex colour on these iOS versions,
so the shader emits one of eight band indices and the overlay is drawn with eight
shared flat materials. A face takes the worst band among its three vertices:
under-reporting is the dangerous direction for defect work.

**Everything is budgeted.** ARKit re-emits mesh chunks far faster than they can
be absorbed. Anchors are queued dirty and three are processed per frame, covering
both the CPU vertex copy and the GPU dispatch.

## Known limitations

- **Accuracy is bounded by the sensor.** Apple's LiDAR is a low-resolution
  time-of-flight sensor with centimetre-scale noise that grows with range and
  degrades on dark, glossy and transparent surfaces. Millimetre readings in the
  UI are the arithmetic of the comparison, not a claim about achievable accuracy.
  Treat this as a triage tool that finds where to bring a total station, not as a
  replacement for one.
- **Drift.** ARKit world tracking drifts over long walks. A registration
  established at one end of a bay degrades at the other; re-align periodically.
  Re-running ICP against a drifted cloud will partly absorb this, but the honest
  fix is re-anchoring against surveyed points.
- **Unverified against a real model.** The code was written without a macOS
  toolchain available, so it has not been compiled or run on device. Expect to
  fix API details on first build, particularly around `MeshDescriptor` and the
  `ARMeshGeometry` buffer accessors.
- **Sign convention** for signed distance relies on BIM face normals pointing
  outward. Models with inconsistent winding will report the sign, though not the
  magnitude, incorrectly.
- **No persistence.** Alignments and findings live for the session only. Wiring
  `ARWorldMap` plus the twin backend is the obvious next step.
