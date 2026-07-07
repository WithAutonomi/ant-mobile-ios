import SwiftUI

/// Compact Autonomi-network connection pill, the mobile counterpart of the
/// desktop `AppHeader` indicator (see ant-ui `components/AppHeader.vue` +
/// `stores/connection.ts`): a spinner "Connecting", a green "● Network" when
/// connected, and a tappable red "● Offline · Retry" on failure.
struct NetworkIndicator: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore

    // The navigation bar already frames toolbar items with their own
    // (Liquid Glass) background, so this draws NO box of its own — otherwise the
    // two nest and look like a button inside a button. Connecting/connected are
    // plain status content; only the failure state is an interactive button.
    var body: some View {
        Group {
            switch store.connection {
            case .idle, .connecting:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Connecting").foregroundStyle(theme.muted)
                }
            case .connected:
                HStack(spacing: 5) {
                    Text("●").foregroundStyle(AntColors.success)
                    Text("Network").foregroundStyle(theme.text)
                }
            case .failed:
                Button { store.retryConnection() } label: {
                    HStack(spacing: 5) {
                        Text("●")
                        Text("Offline · Retry")
                    }
                    .foregroundStyle(AntColors.error)
                }
            }
        }
        .font(.caption2)
    }
}

extension View {
    /// Pin the shared `NetworkIndicator` to the navigation bar's trailing edge,
    /// so every screen shows the same connection status (like the desktop header).
    func networkToolbar() -> some View {
        toolbar { ToolbarItem(placement: .primaryAction) { NetworkIndicator() } }
    }
}
