import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Copy text to the system clipboard (cross-platform).
func copyToClipboard(_ s: String) {
    #if os(iOS)
    UIPasteboard.general.string = s
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}

/// Uploads tab — file picker + a list of upload rows. Picking a file stages it
/// and opens the confirm sheet (quote → Approve), mirroring the desktop
/// UploadConfirmDialog.
struct UploadsScreen: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button { importing = true } label: {
                    Label("Upload a file", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)

                if store.uploads.isEmpty {
                    EmptyState(title: "No uploads yet",
                               subtitle: "Tap “Upload a file” to store data on the network")
                } else {
                    ForEach(store.uploads) { FileRow(entry: $0) }
                }
            }
            .padding(16)
        }
        .antBackground()
        .navigationTitle("Uploads")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                store.stageUpload(name: url.lastPathComponent, data: data)
            }
        }
        .sheet(item: Binding(
            get: { store.pendingUpload },
            set: { if $0 == nil { store.cancelPending() } }
        )) { _ in UploadConfirmSheet() }
    }
}

/// Downloads tab — one input + one Download button, with two ways in: paste an
/// address / `autonomi://` link, or attach a datamap file (📎). Whichever is
/// set drives the single Download action.
struct DownloadsScreen: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore
    @State private var input = ""
    @State private var pickingDatamap = false
    @State private var datamapHex: String?
    @State private var datamapName: String?

    private var canDownload: Bool {
        datamapHex != nil || !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // URL-bar style: address/link field with an attach affordance.
                HStack(spacing: 8) {
                    TextField("Address or autonomi:// link", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .disabled(datamapHex != nil)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button { pickingDatamap = true } label: {
                        Image(systemName: "paperclip").font(.body)
                    }
                    .buttonStyle(.bordered)
                    .help("Attach a datamap file")
                }

                // Attached-datamap chip.
                if let name = datamapName {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(AntColors.blue)
                        Text(name).font(.footnote).foregroundStyle(theme.text).lineLimit(1)
                        Spacer()
                        Button { datamapHex = nil; datamapName = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.muted)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                }

                Button { performDownload() } label: {
                    Label("Download", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDownload)

                if store.downloads.isEmpty {
                    EmptyState(title: "No downloads yet",
                               subtitle: "Paste an address or autonomi:// link, or 📎 attach a datamap file")
                } else {
                    ForEach(store.downloads) { FileRow(entry: $0) }
                }
            }
            .padding(16)
        }
        .antBackground()
        .navigationTitle("Downloads")
        .fileImporter(isPresented: $pickingDatamap, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            // Read the datamap hex now, while security-scoped access is valid.
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let hex = (try? String(contentsOf: url, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty {
                datamapHex = hex
                datamapName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func performDownload() {
        if let hex = datamapHex {
            store.downloadFromDatamap(hex: hex, suggestedName: datamapName)
            datamapHex = nil; datamapName = nil
        } else {
            store.download(input: input)
            input = ""
        }
    }
}

// MARK: - shared row rendering

private struct EmptyState: View {
    @EnvironmentObject private var theme: ThemeController
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline)
            Text(subtitle).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(theme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct FileRow: View {
    @EnvironmentObject private var theme: ThemeController
    let entry: FileEntry

    /// Shareable link for a public upload (`autonomi://<data-map address>`).
    private var autonomiLink: String? {
        (entry.kind == .upload) ? entry.address.map { "autonomi://\($0)" } : nil
    }

    var body: some View {
        AntCard {
            Text(entry.name).font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
            HStack(spacing: 10) {
                StatusBadge(entry: entry)
                if entry.sizeBytes > 0 {
                    Text(formatSize(entry.sizeBytes)).font(.caption).foregroundStyle(theme.muted)
                }
                Text(formatDate(entry.createdAt)).font(.caption).foregroundStyle(theme.muted)
            }
            if entry.status.inProgress {
                if let p = entry.progress {
                    ProgressView(value: p).progressViewStyle(.linear).tint(AntColors.blue)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(AntColors.blue)
                }
                if let detail = entry.stageDetail {
                    Text(detail).font(.caption2).foregroundStyle(theme.muted)
                }
            }
            if let cost = entry.cost {
                Text("Cost: \(cost)").font(.caption).foregroundStyle(theme.muted)
            }
            if let link = autonomiLink {
                Text(link).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AntColors.blue).textSelection(.enabled).lineLimit(1)
            }
            if let dataMapFile = entry.dataMapFile {
                ShareLink(item: URL(fileURLWithPath: dataMapFile)) {
                    Label("Open file", systemImage: "square.and.arrow.up").font(.caption)
                }.tint(AntColors.blue)
            }
            if let savedTo = entry.savedTo {
                Text("Saved to: \(savedTo)").font(.caption).foregroundStyle(theme.muted)
                    .textSelection(.enabled)
            }
        }
        // Long-press → copy the shareable reference.
        .contextMenu {
            if let link = autonomiLink {
                Button { copyToClipboard(link) } label: {
                    Label("Copy autonomi:// link", systemImage: "doc.on.doc")
                }
            }
            if let dataMapFile = entry.dataMapFile {
                Button { copyToClipboard(dataMapFile) } label: {
                    Label("Copy datamap path", systemImage: "doc.on.doc")
                }
                ShareLink(item: URL(fileURLWithPath: dataMapFile)) {
                    Label("Open datamap file", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let entry: FileEntry
    private var colors: (bg: Color, fg: Color) {
        switch entry.status {
        case .complete, .downloaded: return (AntColors.success.opacity(0.22), AntColors.success)
        case .failed:                return (AntColors.error.opacity(0.18), AntColors.error)
        default:                     return (AntColors.blue.opacity(0.18), AntColors.blue)
        }
    }
    var body: some View {
        Text(entry.statusText)
            .font(.caption2).fontWeight(.medium)
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(colors.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
