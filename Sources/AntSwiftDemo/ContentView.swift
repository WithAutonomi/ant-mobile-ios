import SwiftUI

/// Root view — the bottom-nav app shell (Uploads / Downloads / Wallet /
/// Settings), a facsimile of the desktop app + the Android demo.
struct ContentView: View {
    var body: some View { AppShell() }
}

#Preview { ContentView() }
