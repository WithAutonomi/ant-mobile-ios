import SwiftUI

/// Settings — mirrors ant-ui/pages/settings.vue and the Android demo: a centered
/// column of bordered cards. The Screen mode selector is functional (drives the
/// ThemeController); the rest are faithful mock controls for the demo.
struct SettingsScreen: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore
    @State private var alertSound = false
    @AppStorage("devnetHost") private var devnetHost = ""
    @State private var showDeveloper = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingCard(title: "Alert Sound", subtitle: "Bell on critical errors.") {
                    HStack {
                        Spacer()
                        Toggle("", isOn: $alertSound).labelsHidden().tint(AntColors.blue)
                    }
                }

                // The one live control.
                SettingCard(title: "Screen mode", subtitle: "Switch between dark and light themes.") {
                    Picker("", selection: Binding(
                        get: { theme.dark ? 0 : 1 },
                        set: { theme.dark = ($0 == 0) }
                    )) {
                        Text("Dark").tag(0)
                        Text("Light").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                SettingCard(title: "Upload history",
                            subtitle: "\(settledCount) settled upload\(settledCount == 1 ? "" : "s").") {
                    Button("Clear history") { store.clearHistory() }
                        .buttonStyle(.bordered)
                }

                SettingCard(title: "About", subtitle: nil) {
                    HStack {
                        Text("App").font(.caption).foregroundStyle(theme.muted)
                        Spacer()
                        Text("AntFfi Demo 0.1").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(theme.text)
                    }
                    Text("autonomi.com  ·  github.com/WithAutonomi")
                        .font(.caption).foregroundStyle(AntColors.blue)
                }

                // Developer — collapsed by default. Point the app at a LAN
                // devnet's manifest HTTP API (ant-devnet --serve-port) so a
                // physical device (or the sim) needs no file copying.
                AntCard {
                    DisclosureGroup(isExpanded: $showDeveloper) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Devnet host")
                                .font(.caption).foregroundStyle(theme.muted)
                            TextField("192.168.0.62:8088", text: $devnetHost)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                #endif
                            Text("Fetches the manifest from http://<host>/api/devnet-manifest.json. Leave blank on the simulator to use the shared file.")
                                .font(.caption2).foregroundStyle(theme.muted)
                            Button("Apply & reconnect") { store.retryConnection() }
                                .buttonStyle(.borderedProminent)
                                .tint(AntColors.blue)
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Developer").font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(theme.text)
                    }
                    .tint(theme.muted)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .antBackground()
        .navigationTitle("Settings")
        .networkToolbar()
    }

    private var settledCount: Int { store.uploads.filter { !$0.status.inProgress }.count }
}

private struct SettingCard<Content: View>: View {
    @EnvironmentObject private var theme: ThemeController
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        AntCard {
            Text(title).font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(theme.muted) }
            content
        }
    }
}
