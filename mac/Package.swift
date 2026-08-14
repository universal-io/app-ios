// swift-tools-version: 5.9
import PackageDescription

// The companion starts as a command-line tool rather than an app on purpose.
// The first thing M4 has to establish is whether frames can be captured and
// carried at a usable rate, and that question is answered by numbers printed to
// a terminal — no window, no menu bar, nothing to mistake a UI problem for a
// transport problem. The app shell comes after the measurement says the
// transport is worth building on.
let package = Package(
    name: "Broadcaster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Broadcaster", path: "Sources/Broadcaster")
    ]
)
