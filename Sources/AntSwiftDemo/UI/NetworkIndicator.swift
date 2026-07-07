import SwiftUI

/// Compact Autonomi-network connection pill, the mobile counterpart of the
/// desktop `AppHeader` indicator (see ant-ui `components/AppHeader.vue` +
/// `stores/connection.ts`): a spinner "Connecting", a green "● Network" when
/// connected, and a tappable red "● Offline · Retry" on failure.
struct NetworkIndicator: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore

    var body: some View {
        switch store.connection {
        case .idle, .connecting:
            pill(border: theme.border) {
                ProgressView().controlSize(.mini)
                Text("Connecting").foregroundStyle(theme.muted)
            }
        case .connected:
            pill(border: theme.border) {
                Text("●").foregroundStyle(AntColors.success)
                Text("Network").foregroundStyle(theme.text)
            }
        case .failed:
            Button { store.retryConnection() } label: {
                pill(border: AntColors.error.opacity(0.35)) {
                    Text("●").foregroundStyle(AntColors.error)
                    Text("Offline · Retry").foregroundStyle(AntColors.error)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func pill<Content: View>(border: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
    }
}

extension View {
    /// Pin the shared `NetworkIndicator` to the navigation bar's trailing edge,
    /// so every screen shows the same connection status (like the desktop header).
    func networkToolbar() -> some View {
        toolbar { ToolbarItem(placement: .primaryAction) { NetworkIndicator() } }
    }
}
