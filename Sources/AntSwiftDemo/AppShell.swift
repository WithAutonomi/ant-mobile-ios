import SwiftUI

/// App shell: a bottom tab bar (standard mobile pattern) over the four screens,
/// mirroring the Android demo's AppShell. Nodes is intentionally omitted — nodes
/// can't run on mobile — so it's Uploads / Downloads / Wallet / Settings.
///
/// Owns the shared state (theme, files store, and on iOS the WalletConnect
/// manager), injects it via the environment, applies the Autonomi theme, and
/// routes `autonomi://` deep links to the Downloads tab.
struct AppShell: View {
    @StateObject private var theme = ThemeController()
    @StateObject private var store = FilesStore()
    #if os(iOS)
    @StateObject private var wallet = WalletConnectManager()
    // Dedicated Reown project (dashboard.reown.com); the desktop app has its own.
    private let reownProjectId = "2cd5b44944e27d5234557a9183dc1cdd"
    #endif
    @State private var selection: Tab = .uploads

    private enum Tab: Hashable { case uploads, downloads, wallet, settings }

    private struct WalletUnavailable: LocalizedError {
        var errorDescription: String? { "No wallet connected" }
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { UploadsScreen() }
                .tabItem { Label("Uploads", systemImage: "arrow.up.circle") }
                .tag(Tab.uploads)
            NavigationStack { DownloadsScreen() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)
            NavigationStack { WalletScreen() }
                .tabItem { Label("Wallet", systemImage: "creditcard") }
                .tag(Tab.wallet)
            NavigationStack { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(AntColors.blue)
        .environmentObject(theme)
        .environmentObject(store)
        #if os(iOS)
        .environmentObject(wallet)
        #endif
        .preferredColorScheme(theme.colorScheme)
        .onAppear(perform: setup)
        .onOpenURL(perform: handleDeepLink)
    }

    private func setup() {
        store.refreshNetwork()
        store.seedSampleDocuments()
        #if os(iOS)
        wallet.configure(projectId: reownProjectId)
        store.walletAddress = { [weak wallet] in wallet?.address }
        store.externalSigner = { [weak wallet] to, data, chainId in
            guard let wallet else { throw WalletUnavailable() }
            return try await wallet.sendTransaction(to: to, data: data, chainId: chainId)
        }
        #endif
    }

    /// `autonomi://<addr>?name=…&filetype=…` → jump to Downloads and fetch, using
    /// ant-webex's filename fallbacks (see AntUri).
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "autonomi" else { return }
        selection = .downloads
        store.download(input: url.absoluteString)
    }
}
