import SwiftUI
import Combine

/// Autonomi palette, lifted verbatim from the desktop app (ant-ui
/// tailwind.config.cjs + assets/css/main.css) and the Android demo's Theme.kt.
/// blue/muted/status colours are identical across modes; bg/surface/border/text
/// swap between dark (default) and light.
enum AntColors {
    static let blue    = Color(red: 0x4A / 255, green: 0x9F / 255, blue: 0xE5 / 255)
    static let muted   = Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255)
    static let success = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let error   = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)

    static let darkBg      = Color(red: 0x0A / 255, green: 0x0F / 255, blue: 0x1C / 255)
    static let darkSurface = Color(red: 0x14 / 255, green: 0x1B / 255, blue: 0x2D / 255)
    static let darkBorder  = Color(red: 0x1E / 255, green: 0x2A / 255, blue: 0x3F / 255)
    static let darkText    = Color(red: 0xE2 / 255, green: 0xE8 / 255, blue: 0xF0 / 255)

    static let lightBg      = Color(red: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255)
    static let lightSurface = Color.white
    static let lightBorder  = Color(red: 0xCB / 255, green: 0xD5 / 255, blue: 0xE1 / 255)
    static let lightText    = Color(red: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255)
}

/// Theme state — mirrors the desktop `settingsStore.themeMode` ("dark" default),
/// persisted to UserDefaults so it survives relaunch (the Android demo persists
/// to SharedPreferences; the desktop via its Tauri config).
final class ThemeController: ObservableObject {
    private static let key = "dark_mode"

    @Published var dark: Bool {
        didSet { UserDefaults.standard.set(dark, forKey: Self.key) }
    }

    init() {
        dark = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }

    var bg: Color      { dark ? AntColors.darkBg : AntColors.lightBg }
    var surface: Color { dark ? AntColors.darkSurface : AntColors.lightSurface }
    var border: Color  { dark ? AntColors.darkBorder : AntColors.lightBorder }
    var text: Color    { dark ? AntColors.darkText : AntColors.lightText }
    var muted: Color   { AntColors.muted }
    var colorScheme: ColorScheme { dark ? .dark : .light }
}

/// Bordered surface card — the mobile analogue of the desktop's bordered panels
/// (ant-ui) and the Android demo's `Surface` cards.
struct AntCard<Content: View>: View {
    @EnvironmentObject private var theme: ThemeController
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
    }
}

/// Fill the screen with the themed background behind scrolling content.
struct AntBackground: ViewModifier {
    @EnvironmentObject private var theme: ThemeController
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.bg.ignoresSafeArea())
    }
}

extension View {
    func antBackground() -> some View { modifier(AntBackground()) }
}

/// The current payment network an upload will hit (devnet manifest derived),
/// shown as a plain dot + label. Colour signals risk: blue = testnet,
/// amber = mainnet, green = local, grey = none.
struct NetworkBadge: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore

    private var dotColor: Color {
        switch store.network.kind {
        case .testnet: return AntColors.blue
        case .mainnet: return Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255) // amber
        case .local:   return AntColors.success
        case .none:    return AntColors.muted
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(store.network.label).font(.caption).fontWeight(.medium).foregroundStyle(theme.text)
        }
    }
}
