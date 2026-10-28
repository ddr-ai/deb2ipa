#if canImport(SwiftUI)
import SwiftUI
import DebKit

// The M8 app shell: `@main` + a single scene hosting the M6 RootView.
// Everything else (screens, stores, bootstrap) lives in DebKit.Views.
// This file is compiled only by Xcode on Apple platforms (the deb2ipa
// executable target exists only where SwiftUI exists, see Package.swift),
// which is exactly the M6 architecture: logic compiles and is tested on
// the Linux CI; the shell compiles on the macOS build-app runner.

@main
struct Deb2IPAApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
#endif
