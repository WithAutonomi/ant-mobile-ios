import Foundation
import AntFfi

/// Bridges the FFI `ProgressListener` callback (fired on a background thread)
/// to a Sendable closure. The closure hops to the main actor before touching
/// store state.
private final class ProgressBridge: ProgressListener, @unchecked Sendable {
    private let handler: @Sendable (ProgressUpdate) -> Void
    init(_ handler: @escaping @Sendable (ProgressUpdate) -> Void) { self.handler = handler }
    func onProgress(update: ProgressUpdate) { handler(update) }
}

/// An upload that has been (or is being) quoted and is waiting for the user to
/// review the cost and Approve — drives the confirm sheet. Mirrors the desktop
/// UploadConfirmDialog's bound state.
struct PendingUpload: Identifiable {
    let id: Int64          // the FileEntry row id
    let name: String
    /// Path to the picked file copied into the app sandbox. The upload streams
    /// from disk (file-path FFI) instead of holding the whole file in memory.
    let path: String
    let sizeBytes: Int64
    var visibility: String // "private" | "public"
    var info: PreparedUploadInfo?  // nil while (re)quoting
    /// Fast sampled cost estimate shown while the full quote is still running.
    var estimate: CostEstimate?
    var quoting: Bool
    var error: String?
}

/// Backing store for the Files screens — the mobile analogue of the desktop
/// app's files store (`ant-ui/stores/files.ts`). Drives real network operations
/// through the bundled AntFfi framework, with a quote → approve two-step upload
/// and live progress via the FFI's ProgressListener.
@MainActor
final class FilesStore: ObservableObject {
    /// Where the devnet manifest lives in the app sandbox. It's fetched from a
    /// devnet host's HTTP API (Developer settings) or — on the simulator with
    /// no host set — copied from the legacy shared path below.
    var manifestPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devnet-manifest.json").path
    }

    /// Simulator convenience: the desktop/CLI writes the manifest under the host
    /// user's `~/Library/Application Support/ant/`, and the simulator shares the
    /// host filesystem. The simulator exposes the host home via the
    /// `SIMULATOR_HOST_HOME` env var, so this resolves per-machine. Returns nil on
    /// a physical device (no shared host FS — use the devnet-host HTTP fetch).
    /// Used only when no devnet host is set.
    private var legacyManifestPath: String? {
        guard let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else {
            return nil
        }
        return "\(hostHome)/Library/Application Support/ant/devnet-manifest.json"
    }

    /// Devnet host serving the manifest API, e.g. `192.168.0.62:8088` (set in
    /// Developer settings). Empty → fall back to the legacy shared path.
    private var devnetHost: String {
        (UserDefaults.standard.string(forKey: "devnetHost") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ensure a manifest file exists at `manifestPath`: fetch it from the devnet
    /// host's HTTP API when configured (so a physical device needs no file
    /// copying), else copy the legacy shared file (simulator).
    func ensureManifest() async {
        if !devnetHost.isEmpty,
           let url = URL(string: "http://\(devnetHost)/api/devnet-manifest.json") {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                try data.write(to: URL(fileURLWithPath: manifestPath))
            } catch {
                // Keep any previously-fetched manifest on a transient failure.
            }
        } else if let legacy = legacyManifestPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: legacy)) {
            try? data.write(to: URL(fileURLWithPath: manifestPath))
        }
    }

    @Published var uploads: [FileEntry] = []
    @Published var downloads: [FileEntry] = []
    /// Non-nil while an upload is being quoted / awaiting the user's Approve.
    @Published var pendingUpload: PendingUpload?

    /// Injected by the iOS shell (see AppShell): the connected wallet address
    /// and a signer. Left unset on macOS → devnet fallback / no external signer.
    var walletAddress: () -> String? = { nil }
    var externalSigner: ((_ to: String, _ data: String, _ chainId: Int) async throws -> String)?

    // ── Network badge state (unchanged) ──
    struct NetworkInfo: Equatable {
        enum Kind { case testnet, mainnet, local, none }
        var label: String
        var chainId: Int?
        var kind: Kind
        static let unknown = NetworkInfo(label: "No devnet", chainId: nil, kind: .none)
    }
    @Published private(set) var network: NetworkInfo = .unknown

    // ── Autonomi network connection status (mirrors the desktop connectionStore:
    //    idle | connecting | connected | failed) ──
    enum ConnectionStatus: Equatable {
        case idle, connecting, connected, failed(String)
    }
    @Published private(set) var connection: ConnectionStatus = .idle

    /// Join the Autonomi network (build + start the P2P client from the devnet
    /// manifest) and track status for the indicator. Idempotent — a no-op while
    /// already connecting or connected. Called at launch and by the Retry action.
    func connectNetwork() {
        switch connection {
        case .connecting, .connected: return
        case .idle, .failed: break
        }
        connection = .connecting
        Task {
            await ensureManifest()
            refreshNetwork()
            do {
                _ = try await externalSignerClient()
                connection = .connected
            } catch {
                connection = .failed("\(error)")
            }
        }
    }

    /// Background liveness: while a devnet host is set, poll its HTTP API so the
    /// badge reflects reality — flips to `.failed` when the devnet dies, and
    /// auto-reconnects when it returns (instead of staying green after the
    /// devnet stops). Started once from the shell. No-op when no host is set.
    private var livenessStarted = false
    func startLivenessPoll() {
        guard !livenessStarted else { return }
        livenessStarted = true
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let host = devnetHost
                guard !host.isEmpty else { continue }
                let alive = await apiAlive(host)
                if !alive, connection == .connected {
                    esClient = nil
                    walletClient = nil
                    connection = .failed("devnet unreachable")
                } else if alive, case .failed = connection {
                    connectNetwork()
                }
            }
        }
    }

    /// Cheap reachability check against the devnet's manifest HTTP API.
    private func apiAlive(_ host: String) async -> Bool {
        guard let url = URL(string: "http://\(host)/api/info") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Force a fresh connection attempt (drops any cached client first so a
    /// previously-failed build is retried, not reused).
    func retryConnection() {
        esClient = nil
        connection = .idle
        connectNetwork()
    }

    private var nextId: Int64 = 1
    private var esClient: Client?
    private var walletClient: Client?

    // MARK: - Setup helpers

    func refreshNetwork() {
        guard let evm = try? parseManifestEvm() else { network = .unknown; return }
        let rpc = evm.rpc.lowercased()
        if rpc.contains("localhost") || rpc.contains("127.0.0.1") {
            network = NetworkInfo(label: "Local EVM", chainId: evm.chainId, kind: .local)
        } else if evm.chainId == 421614 {
            network = NetworkInfo(label: "Arbitrum Sepolia", chainId: 421614, kind: .testnet)
        } else if evm.chainId == 42161 {
            network = NetworkInfo(label: "Arbitrum One", chainId: 42161, kind: .mainnet)
        } else {
            network = NetworkInfo(label: "Chain \(evm.chainId)", chainId: evm.chainId, kind: .local)
        }
    }

    func seedSampleDocuments() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sample = docs.appendingPathComponent("hello-autonomi.txt")
        guard !FileManager.default.fileExists(atPath: sample.path) else { return }
        let text = "Hello from the Autonomi mobile demo!\n" +
            "Uploaded from iOS via the external-signer WalletConnect flow.\n"
        try? text.data(using: .utf8)?.write(to: sample)
    }

    func clearHistory() {
        uploads.removeAll { !$0.status.inProgress }
        downloads.removeAll { !$0.status.inProgress }
    }

    // MARK: - Uploads: quote → approve

    /// Step 1: stage a file for upload and start quoting. Opens the confirm
    /// sheet (`pendingUpload`); the user reviews cost then Approves or Cancels.
    /// With no wallet connected there's nothing to sign, so we fall back to the
    /// devnet single-shot put immediately.
    func stageUpload(name: String, path: String) {
        let id = newId()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let sizeBytes = (attrs?[.size] as? Int64) ?? 0
        uploads.insert(FileEntry(id: id, kind: .upload, name: name,
                                 sizeBytes: sizeBytes, status: .quoting,
                                 createdAt: Date()), at: 0)
        guard walletAddress() != nil, externalSigner != nil else {
            Task { await devnetUpload(id: id, path: path) }
            return
        }
        pendingUpload = PendingUpload(id: id, name: name, path: path, sizeBytes: sizeBytes,
                                      visibility: "private", info: nil, estimate: nil,
                                      quoting: true, error: nil)
        quote(id: id)
    }

    /// Flip the pending upload's visibility and re-quote (public pays for one
    /// extra chunk — the published data map — so the estimate differs). The
    /// sampled cost estimate is visibility-independent, so it's kept.
    func setPendingVisibility(_ vis: String) {
        guard var p = pendingUpload, p.visibility != vis else { return }
        p.visibility = vis; p.info = nil; p.quoting = true; p.error = nil
        pendingUpload = p
        quote(id: p.id)
    }

    private func quote(id: Int64) {
        guard let pending = pendingUpload, pending.id == id else { return }
        let path = pending.path
        updateUpload(id) { $0.status = .quoting }
        Task {
            do {
                let c = try await externalSignerClient()
                // Fast sampled estimate first, so the sheet shows a ballpark cost
                // immediately instead of a bare spinner while the full quote runs.
                // Only fetch it once — it doesn't depend on visibility.
                if pendingUpload?.id == id, pendingUpload?.estimate == nil {
                    if let est = try? await c.estimateFileCost(path: path, paymentMode: "auto"),
                       var p = pendingUpload, p.id == id {
                        p.estimate = est
                        pendingUpload = p
                    }
                }
                let info = try await c.prepareFileUpload(path: path, visibility: pending.visibility)
                guard var p = pendingUpload, p.id == id else { return } // dismissed meanwhile
                p.info = info; p.quoting = false
                pendingUpload = p
                updateUpload(id) {
                    $0.status = .awaitingApproval
                    $0.cost = "\(info.payments.count) quote(s) · \(formatAtto(info.totalAmount)) ANT"
                }
            } catch {
                if var p = pendingUpload, p.id == id { p.quoting = false; p.error = "\(error)"; pendingUpload = p }
                updateUpload(id) { $0.status = .failed; $0.error = "\(error)" }
            }
        }
    }

    /// Public + already-stored: the data-map address is already known from the
    /// quote, so no finalize or transaction is needed — complete the row now.
    func completeAlreadyStored() {
        guard let p = pendingUpload, let info = p.info, let addr = info.dataMapAddress else { return }
        let id = p.id
        cleanupTemp(p.path)
        pendingUpload = nil
        updateUpload(id) {
            $0.status = .complete; $0.stage = nil
            $0.address = addr
            $0.cost = "already stored"
        }
    }

    /// Cancel the pending upload (dismiss the sheet, drop the row).
    func cancelPending() {
        if let p = pendingUpload {
            uploads.removeAll { $0.id == p.id }
            cleanupTemp(p.path)
        }
        pendingUpload = nil
    }

    /// Remove a staged upload's sandbox copy once it's no longer needed
    /// (completed, cancelled, or failed). Best-effort — the temp dir is
    /// OS-reclaimed anyway.
    private func cleanupTemp(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Step 2: the user approved. Ask the SDK for the exact transactions the
    /// wallet must sign (`approve` + the vault payment call), sign each via the
    /// external wallet, wait for each receipt, then finalize with live storing
    /// progress. All ABI encoding, receipt polling, and the merkle-winner lookup
    /// now live in the SDK (AntFfi `paymentTransactions` / `waitForReceipt` /
    /// `merkleWinnerPoolHash`) instead of hand-rolled here.
    func approvePending() {
        guard let p = pendingUpload, let info = p.info else { return }
        let id = p.id
        let visibility = p.visibility
        let tmpPath = p.path
        pendingUpload = nil
        Task {
            defer { cleanupTemp(tmpPath) }
            do {
                let c = try await externalSignerClient()

                if info.alreadyStored {
                    // Finalize must be routed by payment shape even when nothing
                    // is owed — the FFI rejects a mis-routed finalize. Merkle
                    // accepts any valid 32-byte winner hash here.
                    let r: ExternalUploadResult
                    if info.paymentType == "merkle" {
                        r = try await c.finalizeUploadMerkle(uploadId: info.uploadId,
                                                             winnerPoolHash: anyWinnerHash(info))
                    } else {
                        r = try await c.finalizeUpload(uploadId: info.uploadId, txHashes: [:])
                    }
                    completeUpload(id: id, visibility: visibility, address: r.address ?? info.dataMapAddress,
                                   dataMapHex: r.dataMap, cost: "already stored")
                    return
                }

                guard let signer = externalSigner else { throw StoreError.badManifest }
                let evm = try parseManifestEvm()

                // The SDK builds the exact ordered transactions to sign (approve
                // + the payment call), including wave batching and the merkle
                // approve upper-bound. Each `TxRequest` carries its `to`, `data`,
                // and — for wave `pay` txs — the quote hashes it settles.
                updateUpload(id) { $0.status = .awaitingApproval }
                let txs = try await c.paymentTransactions(uploadId: info.uploadId)

                var txHashes: [String: String] = [:]  // quoteHash -> txHash (wave finalize)
                var merklePayTx: String?
                var merkleVault: String?
                var gasWei = 0.0
                for tx in txs {
                    if tx.kind == "pay" { updateUpload(id) { $0.status = .paying } }
                    let hash = try await signer(tx.to, tx.data, evm.chainId)
                    let receipt = try await waitForReceipt(rpcUrl: evm.rpc, txHash: hash, timeoutSecs: 60)
                    guard receipt.success else { throw StoreError.approveReverted }
                    gasWei += weiOf(receipt)
                    if tx.kind == "pay" {
                        for qh in tx.quoteHashes { txHashes[qh] = hash }
                        if info.paymentType == "merkle" { merklePayTx = hash; merkleVault = tx.to }
                    }
                }

                // Finalize by payment shape.
                let storeTotal: Int64 = info.paymentType == "merkle" ? 0 : Int64(info.payments.count)
                updateUpload(id) {
                    $0.status = .uploading
                    $0.stage = "storing"; $0.stageDone = 0; $0.stageTotal = storeTotal
                }
                let listener = ProgressBridge { [weak self] u in
                    Task { @MainActor in self?.applyProgress(id: id, u) }
                }
                let r: ExternalUploadResult
                let costLabel: String
                if info.paymentType == "merkle" {
                    guard let payTx = merklePayTx, let vault = merkleVault else { throw StoreError.noMerkleEvent }
                    // The winning pool is chosen on-chain; the SDK reads it from
                    // the payForMerkleTree receipt's MerklePaymentMade event.
                    let winner = try await merkleWinnerPoolHash(rpcUrl: evm.rpc, vaultAddress: vault, txHash: payTx)
                    r = try await c.finalizeUploadMerkleWithProgress(uploadId: info.uploadId,
                                                                     winnerPoolHash: winner, listener: listener)
                    // Exact ANT pulled by the vault isn't reparsed — label "merkle".
                    costLabel = "\(r.chunksStored) chunk(s) · merkle"
                } else {
                    r = try await c.finalizeUploadWithProgress(uploadId: info.uploadId,
                                                               txHashes: txHashes, listener: listener)
                    costLabel = "\(r.chunksStored) chunk(s) · \(formatAtto(info.totalAmount)) ANT"
                }
                let gas = gasWei > 0 ? String(format: "%.6f", gasWei / 1e18) : nil
                let cost = costLabel + (gas.map { " · \($0) ETH gas" } ?? "")
                completeUpload(id: id, visibility: visibility, address: r.address ?? info.dataMapAddress,
                               dataMapHex: r.dataMap, cost: cost)
            } catch {
                updateUpload(id) { $0.status = .failed; $0.error = "\(error)"; $0.stage = nil }
            }
        }
    }

    /// A valid 32-byte winner hash for the already-stored merkle case, where the
    /// FFI accepts any hash (no payment was made). Prefer a real pool hash.
    private func anyWinnerHash(_ info: PreparedUploadInfo) -> String {
        info.poolCommitments.first?.poolHash ?? "0x" + String(repeating: "0", count: 64)
    }

    private func completeUpload(id: Int64, visibility: String, address: String?, dataMapHex: String, cost: String) {
        // Private uploads: persist the data map so it can be re-downloaded.
        var dataMapFile: String?
        if visibility == "private" {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("datamaps")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = uploads.first(where: { $0.id == id })?.name ?? "upload"
            let out = dir.appendingPathComponent("\(name).datamap")
            try? dataMapHex.data(using: .utf8)?.write(to: out)
            dataMapFile = out.path
        }
        updateUpload(id) {
            $0.status = .complete
            $0.stage = nil
            $0.address = visibility == "public" ? address : nil
            $0.dataMapFile = dataMapFile
            $0.cost = cost
        }
    }

    /// Devnet fallback: the manifest wallet pays inside ant-core (single-shot).
    /// Uploads from the sandbox file path (streams from disk).
    private func devnetUpload(id: Int64, path: String) async {
        defer { cleanupTemp(path) }
        do {
            let c = try await devnetClient()
            updateUpload(id) { $0.status = .uploading }
            let r = try await c.fileUploadPublic(path: path, paymentMode: "auto")
            updateUpload(id) {
                $0.status = .complete; $0.address = r.address
                $0.cost = "uploaded"
            }
        } catch {
            updateUpload(id) { $0.status = .failed; $0.error = "\(error)" }
        }
    }

    // MARK: - Downloads

    /// Download by a pasted address or an `autonomi://<addr>?name=&filetype=`
    /// URI (uses ant-webex's filename fallbacks via AntUri).
    func download(input rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let addr: String
        let suggestedName: String?
        if trimmed.lowercased().hasPrefix("autonomi://") {
            let parsed = AntUri.parse(trimmed)
            addr = parsed.address
            suggestedName = AntUri.resolveFilename(parsed)
        } else {
            addr = trimmed
            suggestedName = nil
        }
        startDownload(addressHex: addr, dataMapHex: nil, suggestedName: suggestedName)
    }

    /// Download a private upload from a datamap (hex read from an attached file).
    func downloadFromDatamap(hex: String, suggestedName: String?) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        startDownload(addressHex: nil, dataMapHex: clean, suggestedName: suggestedName)
    }

    private func startDownload(addressHex: String?, dataMapHex: String?, suggestedName: String?) {
        let key = addressHex ?? "datamap"
        let id = newId()
        let shortAddr = key.count > 10 ? "\(key.prefix(10))…" : key
        let rowName = suggestedName ?? "download-\(shortAddr)"
        let fileName = suggestedName ?? "download-\(key.prefix(16)).bin"
        downloads.insert(FileEntry(id: id, kind: .download, name: rowName, sizeBytes: 0,
                                   status: .downloading, createdAt: Date(), address: addressHex,
                                   stage: "downloading"), at: 0)
        Task {
            do {
                let c = try await externalSignerClient()
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("downloads")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = dir.appendingPathComponent(fileName)
                let listener = ProgressBridge { [weak self] u in
                    Task { @MainActor in self?.applyProgress(id: id, u) }
                }
                let written: UInt64
                if let addressHex {
                    written = try await c.downloadPublicToFile(addressHex: addressHex, destPath: out.path, listener: listener)
                } else {
                    written = try await c.downloadPrivateToFile(dataMapHex: dataMapHex!, destPath: out.path, listener: listener)
                }
                updateDownload(id) {
                    $0.status = .downloaded; $0.stage = nil
                    $0.sizeBytes = Int64(written); $0.savedTo = out.path
                }
            } catch {
                updateDownload(id) { $0.status = .failed; $0.error = "\(error)"; $0.stage = nil }
            }
        }
    }

    // MARK: - Progress

    private func applyProgress(id: Int64, _ u: ProgressUpdate) {
        let mutate: (inout FileEntry) -> Void = {
            $0.stage = u.phase
            $0.stageDone = Int64(u.done)
            $0.stageTotal = Int64(u.total)
        }
        if uploads.contains(where: { $0.id == id }) { updateUpload(id, mutate) }
        else { updateDownload(id, mutate) }
    }

    // MARK: - Clients

    private func externalSignerClient() async throws -> Client {
        if let c = esClient { return c }
        let c = try await Client.connectFromDevnetManifestExternalSigner(path: manifestPath)
        esClient = c
        return c
    }

    private func devnetClient() async throws -> Client {
        if let c = walletClient { return c }
        let c = try await Client.connectFromDevnetManifest(path: manifestPath)
        walletClient = c
        return c
    }

    // MARK: - Manifest / receipts / helpers

    private struct DevnetEvm { let rpc: String; let chainId: Int }

    private enum StoreError: LocalizedError {
        case badManifest, approveReverted, noMerkleEvent
        var errorDescription: String? {
            switch self {
            case .badManifest: return "Could not read devnet manifest EVM section"
            case .approveReverted: return "A payment transaction reverted on-chain"
            case .noMerkleEvent: return "Merkle payment produced no signed transaction"
            }
        }
    }

    /// Read the devnet RPC + chain id from the manifest. Token/vault addresses no
    /// longer come from here — the SDK's `paymentTransactions` supplies each tx's
    /// `to`. The chain id is taken from the manifest when present, else defaults
    /// to Arbitrum Sepolia (the external-signer devnet), replacing the old
    /// RPC-string guess.
    private func parseManifestEvm() throws -> DevnetEvm {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evm = json["evm"] as? [String: Any],
              let rpc = evm["rpc_url"] as? String
        else { throw StoreError.badManifest }
        let chainId = (evm["chain_id"] as? Int) ?? 421614
        return DevnetEvm(rpc: rpc, chainId: chainId)
    }

    /// Gas spent (wei) for a receipt: `gasUsed × effectiveGasPrice` (decimal
    /// strings from the SDK's `TxReceipt`). Double is fine — display only.
    private func weiOf(_ r: TxReceipt) -> Double {
        (Double(r.gasUsed) ?? 0) * (Double(r.effectiveGasPrice) ?? 0)
    }

    private func newId() -> Int64 { defer { nextId += 1 }; return nextId }

    private func updateUpload(_ id: Int64, _ transform: (inout FileEntry) -> Void) {
        if let i = uploads.firstIndex(where: { $0.id == id }) { transform(&uploads[i]) }
    }
    private func updateDownload(_ id: Int64, _ transform: (inout FileEntry) -> Void) {
        if let i = downloads.firstIndex(where: { $0.id == id }) { transform(&downloads[i]) }
    }
}

/// A safe over-estimate of the merkle payment in atto-tokens:
/// `max(all candidate amounts across all pools) · 2^depth`. The contract charges
/// `median16(winnerPool)·2^depth` and median16 ≤ max, so this is always enough
/// to approve — no need to reimplement the on-chain winner/median selection.
func merkleApproveUpperBound(_ info: PreparedUploadInfo) -> String {
    var maxAmt = "0"
    for pc in info.poolCommitments {
        for c in pc.candidates where decimalGreater(c.amount, maxAmt) {
            maxAmt = normalizeDecimal(c.amount)
        }
    }
    return mulDecimalByPowerOfTwo(maxAmt, info.depth)
}

/// Strip leading zeros from a base-10 integer string (keeps one digit).
func normalizeDecimal(_ s: String) -> String {
    let t = s.drop(while: { $0 == "0" })
    return t.isEmpty ? "0" : String(t)
}

/// `a > b` for non-negative base-10 integer strings.
func decimalGreater(_ a: String, _ b: String) -> Bool {
    let na = normalizeDecimal(a), nb = normalizeDecimal(b)
    if na.count != nb.count { return na.count > nb.count }
    return na > nb  // equal length → lexicographic order matches numeric order
}

/// Multiply a non-negative base-10 integer string by `2^power` (schoolbook
/// doubling — no BigInt dependency; `power` is a small merkle depth).
func mulDecimalByPowerOfTwo(_ decimal: String, _ power: UInt32) -> String {
    var digits = Array(normalizeDecimal(decimal)).map { $0.wholeNumberValue ?? 0 }
    for _ in 0..<power {
        var carry = 0
        for i in stride(from: digits.count - 1, through: 0, by: -1) {
            let v = digits[i] * 2 + carry
            digits[i] = v % 10
            carry = v / 10
        }
        if carry > 0 { digits.insert(carry, at: 0) }
    }
    return normalizeDecimal(digits.map(String.init).joined())
}

/// Format an atto-token amount (1e18 = 1 ANT) as a short ANT string.
func formatAtto(_ atto: String) -> String {
    guard let value = Double(atto) else { return atto }
    let ant = value / 1e18
    if ant == 0 { return "0" }
    if ant < 0.0001 { return String(format: "%.8f", ant) }
    return String(format: "%.6f", ant)
}
