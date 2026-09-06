// swift-tools-version: 5.9
import PackageDescription

// A test harness for the platform-independent half of Twinzo Scan, so the
// geometry and registration maths can be exercised on Windows or Linux without
// an Apple toolchain.
//
// This package is NOT how the app is built. The iOS app is generated from
// project.yml with XcodeGen — see README.md. Building this package on macOS is
// not supported and will fail on the `simd` shim below, which deliberately
// shadows Apple's real `simd` module.
//
// What it covers: the BVH, point-to-plane ICP, and the scan cloud — everything
// with no Apple framework dependency, and the code most likely to be subtly
// wrong in ways a compiler cannot catch.
let package = Package(
    name: "TwinzoScanCore",
    targets: [
        // Stands in for Apple's `simd` module so the production sources compile
        // unmodified. Naming the target `simd` is what lets `import simd` in
        // BVH.swift and PointToPlaneICP.swift resolve here instead.
        .target(
            name: "simd",
            path: "Testing/SIMDShim"
        ),

        // The production sources themselves, compiled verbatim. No copies, no
        // forks: a test that passes here tested the code the app ships.
        .target(
            name: "TwinzoCore",
            dependencies: ["simd"],
            path: "TwinzoScan/Sources",
            sources: [
                "Geometry",
                "Alignment/PointToPlaneICP.swift",
                "Deviation/DeviationStatistics.swift",
            ]
        ),

        .testTarget(
            name: "TwinzoCoreTests",
            dependencies: ["TwinzoCore", "simd"],
            path: "Testing/Tests"
        ),
    ]
)
