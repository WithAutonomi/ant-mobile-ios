import Foundation

/// Lifecycle states mirroring the desktop app's file manager
/// (ant-ui `pages/files.vue` statusLabel) and the Android demo's FileStatus.
/// Uploads progress quoting → (awaiting approval / paying) → uploading →
/// complete; downloads downloading → downloaded. Either can end in failed.
enum FileStatus: String {
    case quoting = "Quoting"
    case awaitingApproval = "Awaiting approval"
    case paying = "Paying"
    case uploading = "Uploading"
    case complete = "Complete"
    case downloading = "Downloading"
    case downloaded = "Downloaded"
    case failed = "Failed"

    var inProgress: Bool {
        switch self {
        case .quoting, .awaitingApproval, .paying, .uploading, .downloading: return true
        default: return false
        }
    }
}

enum FileKind { case upload, download }

/// One row in the Uploads or Downloads list — the mobile analogue of a desktop
/// table row (name / status / size / cost|saved-to / date).
struct FileEntry: Identifiable {
    let id: Int64
    let kind: FileKind
    var name: String
    var sizeBytes: Int64
    var status: FileStatus
    let createdAt: Date
    /// Content address (hex) once uploaded, or the address used to download.
    var address: String? = nil
    /// Storage cost summary (e.g. chunk count / atto). Blank until known.
    var cost: String? = nil
    /// Where a downloaded file was written on device.
    var savedTo: String? = nil
    /// For private uploads: path to the saved data-map file (used to re-download).
    var dataMapFile: String? = nil
    var error: String? = nil

    // ── Live transfer progress (from the FFI ProgressListener) ──
    /// Current sub-stage: "encrypting", "quoting", "storing", "resolving",
    /// "downloading" — or nil when no event has arrived yet.
    var stage: String? = nil
    /// Units done / total for the current stage. `total == 0` → indeterminate.
    var stageDone: Int64 = 0
    var stageTotal: Int64 = 0

    /// 0.0–1.0 fraction of the current stage, or nil when the total is unknown
    /// (render an indeterminate bar). Mirrors the desktop's per-stage percent.
    var progress: Double? {
        stageTotal > 0 ? min(1.0, Double(stageDone) / Double(stageTotal)) : nil
    }

    /// Sub-stage detail line under the badge, mirroring desktop files.vue.
    var stageDetail: String? {
        guard let stage else { return nil }
        let pct = progress.map { " · \(Int(($0 * 100).rounded()))%" } ?? "…"
        switch stage {
        case "encrypting":  return "Encrypting…"
        case "quoting":     return "Quoting\(pct)"
        case "storing":     return "Storing\(pct)"
        case "resolving":   return "Resolving datamap\(pct)"
        case "downloading": return "Downloading\(pct)"
        default:            return nil
        }
    }

    /// Human-readable status text, matching the desktop's statusLabel.
    var statusText: String {
        status == .failed ? (error.map { "Failed: \($0)" } ?? "Failed") : status.rawValue
    }
}

func formatSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1024
    var i = 0
    while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
    return String(format: "%.1f %@", value, units[i])
}

private let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d, HH:mm"
    return f
}()

func formatDate(_ date: Date) -> String { dateFmt.string(from: date) }
