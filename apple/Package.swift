// swift-tools-version: 6.0
import PackageDescription

// LynxCore: pure Foundation — models, local store, repeat rules, notification planner, sync engine
// (against a RemoteStore protocol), trigger matching, smart lists, quick add. No UI, no Supabase.
// LynxSync: the Supabase-backed RemoteStore, auth and realtime (supabase-swift).
// The SwiftUI app (macOS + iOS) lives in App/ and is built by LynxReminders.xcodeproj (project.yml).
let package = Package(
    name: "LynxKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LynxCore", targets: ["LynxCore"]),
        .library(name: "LynxSync", targets: ["LynxSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.6"),
    ],
    targets: [
        .target(name: "LynxCore"),
        .target(
            name: "LynxSync",
            dependencies: [
                "LynxCore",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "LynxCoreTests", dependencies: ["LynxCore"]),
        // Live checks against a local Supabase (backend/): skipped unless LYNX_LIVE=1.
        .testTarget(name: "LynxSyncTests", dependencies: ["LynxSync", "LynxCore"]),
    ],
    swiftLanguageModes: [.v6]
)
