import SwiftUI
import AntFfi

/// The quote → approve screen, mirroring the desktop `UploadConfirmDialog`:
/// shows the network's cost estimate + a Private/Public selector, and only
/// spends money when the user taps Approve. Reads the live pending-upload state
/// from the store so the cost fills in as the quote arrives.
struct UploadConfirmSheet: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore

    var body: some View {
        Group {
            if let pending = store.pendingUpload {
                content(pending)
            } else {
                Color.clear
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    @ViewBuilder private func content(_ pending: PendingUpload) -> some View {
        let info = pending.info
        VStack(alignment: .leading, spacing: 18) {
            Text("Confirm Upload").font(.title3).fontWeight(.semibold).foregroundStyle(theme.text)

            // Info banner
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(AntColors.blue)
                Text("Review the cost below. Nothing is spent until you Approve — that's when your wallet signs the payment.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            .padding(10)
            .background(AntColors.blue.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // File row
            HStack {
                Text(pending.name).font(.subheadline).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Text(formatSize(Int64(pending.data.count))).font(.caption).foregroundStyle(theme.muted)
            }

            // Cost breakdown
            VStack(alignment: .leading, spacing: 8) {
                if let error = pending.error {
                    Text(error).font(.caption).foregroundStyle(AntColors.error)
                } else if pending.quoting || info == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Obtaining quote from network…").font(.subheadline).foregroundStyle(theme.muted)
                    }
                } else if let info, info.alreadyStored {
                    Label("Already stored on the network — free", systemImage: "checkmark.seal")
                        .font(.subheadline).foregroundStyle(AntColors.success)
                    Text("This exact file is already on the network — you'll get the same address. No ANT or gas will be spent.")
                        .font(.caption).foregroundStyle(theme.muted)
                    if pending.visibility == "public", let addr = info.dataMapAddress {
                        Text("autonomi://\(addr)").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AntColors.blue).textSelection(.enabled).lineLimit(1)
                    }
                } else if let info {
                    row("Network storage cost", "\(formatAtto(info.totalAmount)) ANT", accent: true)
                    row("Chunks to pay for", "\(info.payments.count)")
                    row("Gas", "paid at signing")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))

            // Visibility
            VStack(alignment: .leading, spacing: 6) {
                Text("VISIBILITY").font(.caption2).fontWeight(.medium).foregroundStyle(theme.muted)
                Picker("", selection: Binding(
                    get: { pending.visibility },
                    set: { store.setPendingVisibility($0) }
                )) {
                    Text("Private").tag("private")
                    Text("Public").tag("public")
                }
                .pickerStyle(.segmented)
                Text(pending.visibility == "private"
                     ? "Encrypted; only retrievable with your data map."
                     : "Data map is published — share one address to let anyone retrieve it.")
                    .font(.caption2).foregroundStyle(theme.muted)
            }

            Spacer(minLength: 0)

            // Actions
            HStack {
                Button("Cancel", role: .cancel) { store.cancelPending() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(approveLabel(info, pending.visibility)) { primaryAction(info, pending.visibility) }
                    .buttonStyle(.borderedProminent)
                    .disabled(info == nil || pending.quoting)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.bg.ignoresSafeArea())
        .tint(AntColors.blue)
    }

    private func approveLabel(_ info: PreparedUploadInfo?, _ visibility: String) -> String {
        guard let info, info.alreadyStored else { return "Approve & Pay" }
        return visibility == "public" ? "Copy link" : "Get datamap"
    }

    /// Public + already-stored shortcut: copy the link and finish with no
    /// finalize/tx. Everything else goes through the normal approve/finalize.
    private func primaryAction(_ info: PreparedUploadInfo?, _ visibility: String) {
        if let info, info.alreadyStored, visibility == "public", let addr = info.dataMapAddress {
            copyToClipboard("autonomi://\(addr)")
            store.completeAlreadyStored()
        } else {
            store.approvePending()
        }
    }

    @ViewBuilder private func row(_ key: String, _ value: String, accent: Bool = false) -> some View {
        HStack {
            Text(key).font(.subheadline).foregroundStyle(theme.text)
            Spacer()
            Text(value).font(.subheadline).fontWeight(accent ? .medium : .regular)
                .foregroundStyle(accent ? AntColors.blue : theme.muted)
        }
    }
}
