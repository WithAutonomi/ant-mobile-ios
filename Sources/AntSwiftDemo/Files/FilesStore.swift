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
    let data: Data
    var visibility: String // "private" | "public"
    var info: PreparedUploadInfo?  // nil while (re)quoting
    var quoting: Bool
    var error: String?
}

/// Backing store for the Files screens — the mobile analogue of the desktop
/// app's files store (`ant-ui/stores/files.ts`). Drives real network operations
/// through the bundled AntFfi framework, with a quote → approve two-step upload
/// and live progress via the FFI's ProgressListener.
@MainActor
final class FilesStore: ObservableObject {
    let manifestPath = "/Users/nic/Library/Application Support/ant/devnet-manifest.json"

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
            do {
                _ = try await externalSignerClient()
                connection = .connected
            } catch {
                connection = .failed("\(error)")
            }
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
    func stageUpload(name: String, data: Data) {
        let id = newId()
        uploads.insert(FileEntry(id: id, kind: .upload, name: name,
                                 sizeBytes: Int64(data.count), status: .quoting,
                                 createdAt: Date()), at: 0)
        guard walletAddress() != nil, externalSigner != nil else {
            Task { await devnetUpload(id: id, data: data) }
            return
        }
        pendingUpload = PendingUpload(id: id, name: name, data: data,
                                      visibility: "private", info: nil, quoting: true, error: nil)
        quote(id: id)
    }

    /// Flip the pending upload's visibility and re-quote (public pays for one
    /// extra chunk — the published data map — so the estimate differs).
    func setPendingVisibility(_ vis: String) {
        guard var p = pendingUpload, p.visibility != vis else { return }
        p.visibility = vis; p.info = nil; p.quoting = true; p.error = nil
        pendingUpload = p
        quote(id: p.id)
    }

    private func quote(id: Int64) {
        guard let pending = pendingUpload, pending.id == id else { return }
        updateUpload(id) { $0.status = .quoting }
        Task {
            do {
                let c = try await externalSignerClient()
                let info = try await c.prepareDataUpload(data: pending.data, visibility: pending.visibility)
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
        pendingUpload = nil
        updateUpload(id) {
            $0.status = .complete; $0.stage = nil
            $0.address = addr
            $0.cost = "already stored"
        }
    }

    /// Cancel the pending upload (dismiss the sheet, drop the row).
    func cancelPending() {
        if let id = pendingUpload?.id { uploads.removeAll { $0.id == id } }
        pendingUpload = nil
    }

    /// Step 2: the user approved. Sign the payment (approve + payForQuotes on
    /// the payment chain), then finalize with live storing progress.
    func approvePending() {
        guard let p = pendingUpload, let info = p.info else { return }
        let id = p.id
        let visibility = p.visibility
        pendingUpload = nil
        Task {
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

                // Large uploads settle via a single `payForMerkleTree` call
                // instead of per-quote `payForQuotes`; the flow differs enough to
                // live in its own method.
                if info.paymentType == "merkle" {
                    try await runMerklePayment(id: id, info: info, visibility: visibility,
                                               signer: signer, evm: evm, client: c)
                    return
                }

                updateUpload(id) { $0.status = .awaitingApproval }
                let approveTx = try await signer(evm.token,
                                                 EthCalldata.approve(spender: evm.vault, amount: info.totalAmount),
                                                 evm.chainId)
                try await waitForReceipt(rpc: evm.rpc, txHash: approveTx)

                updateUpload(id) { $0.status = .paying }
                let quotePayments = info.payments.map {
                    EthCalldata.QuotePayment(rewardsAddress: $0.rewardsAddress, amount: $0.amount, quoteHash: $0.quoteHash)
                }
                let payTx = try await signer(evm.vault, EthCalldata.payForQuotes(quotePayments), evm.chainId)
                try await waitForReceipt(rpc: evm.rpc, txHash: payTx)

                updateUpload(id) {
                    $0.status = .uploading
                    $0.stage = "storing"; $0.stageDone = 0; $0.stageTotal = Int64(info.payments.count)
                }
                var txHashes: [String: String] = [:]
                for pay in info.payments { txHashes[pay.quoteHash] = payTx }
                let listener = ProgressBridge { [weak self] u in
                    Task { @MainActor in self?.applyProgress(id: id, u) }
                }
                let r = try await c.finalizeUploadWithProgress(uploadId: info.uploadId, txHashes: txHashes, listener: listener)
                // Gas was paid by the external wallet (not ant-core), so read it
                // back from the approve + payForQuotes receipts.
                let gas = await gasSpentEth(rpc: evm.rpc, txHashes: [approveTx, payTx])
                let cost = "\(r.chunksStored) chunk(s) · \(formatAtto(info.totalAmount)) ANT"
                    + (gas.map { " · \($0) ETH gas" } ?? "")
                completeUpload(id: id, visibility: visibility, address: r.address ?? info.dataMapAddress,
                               dataMapHex: r.dataMap, cost: cost)
            } catch {
                updateUpload(id) { $0.status = .failed; $0.error = "\(error)"; $0.stage = nil }
            }
        }
    }

    /// Merkle payment path: approve → `payForMerkleTree` → read the winning pool
    /// from the `MerklePaymentMade` event → finalize with that winner hash.
    /// Unlike the wave path there's a single vault call and the total cost isn't
    /// known until the contract picks a winner, so we approve a safe upper bound.
    private func runMerklePayment(id: Int64, info: PreparedUploadInfo, visibility: String,
                                  signer: (_ to: String, _ data: String, _ chainId: Int) async throws -> String,
                                  evm: DevnetEvm, client c: Client) async throws {
        let pools = info.poolCommitments.map { pc in
            EthCalldata.PoolCommitment(
                poolHash: pc.poolHash,
                candidates: pc.candidates.map {
                    EthCalldata.MerkleCandidate(rewardsAddress: $0.rewardsAddress, amount: $0.amount)
                }
            )
        }

        // The contract charges `median16(winnerPool)·2^depth` and pulls it via
        // transferFrom, so we must approve at least that. median16 ≤ the largest
        // candidate amount, so `max(all candidates)·2^depth` is always sufficient
        // without reimplementing the on-chain winner/median logic.
        let approveAmount = merkleApproveUpperBound(info)

        updateUpload(id) { $0.status = .awaitingApproval }
        let approveTx = try await signer(evm.token,
                                         EthCalldata.approve(spender: evm.vault, amount: approveAmount),
                                         evm.chainId)
        try await waitForReceipt(rpc: evm.rpc, txHash: approveTx)

        updateUpload(id) { $0.status = .paying }
        let payData = EthCalldata.payForMerkleTree(
            depth: UInt8(info.depth),
            poolCommitments: pools,
            timestamp: info.merklePaymentTimestamp
        )
        let payTx = try await signer(evm.vault, payData, evm.chainId)
        try await waitForReceipt(rpc: evm.rpc, txHash: payTx)

        // The winning pool is selected on-chain — recover its hash from the
        // MerklePaymentMade log; finalize_upload_merkle needs it.
        guard let receipt = await getReceipt(rpc: evm.rpc, txHash: payTx),
              let winnerPoolHash = parseWinnerPoolHash(from: receipt) else {
            throw StoreError.noMerkleEvent
        }

        updateUpload(id) {
            $0.status = .uploading
            $0.stage = "storing"; $0.stageDone = 0; $0.stageTotal = 0
        }
        let listener = ProgressBridge { [weak self] u in
            Task { @MainActor in self?.applyProgress(id: id, u) }
        }
        let r = try await c.finalizeUploadMerkleWithProgress(
            uploadId: info.uploadId, winnerPoolHash: winnerPoolHash, listener: listener)
        // Gas was paid by the external wallet (not ant-core); read it back from
        // the approve + payForMerkleTree receipts. The exact ANT cost is what the
        // vault actually pulled, which we don't reparse — label it "merkle".
        let gas = await gasSpentEth(rpc: evm.rpc, txHashes: [approveTx, payTx])
        let cost = "\(r.chunksStored) chunk(s) · merkle"
            + (gas.map { " · \($0) ETH gas" } ?? "")
        completeUpload(id: id, visibility: visibility, address: r.address ?? info.dataMapAddress,
                       dataMapHex: r.dataMap, cost: cost)
    }

    /// A valid 32-byte winner hash for the already-stored merkle case, where the
    /// FFI accepts any hash (no payment was made). Prefer a real pool hash.
    private func anyWinnerHash(_ info: PreparedUploadInfo) -> String {
        info.poolCommitments.first?.poolHash ?? "0x" + String(repeating: "0", count: 64)
    }

    /// Pull the indexed `winnerPoolHash` (topics[1]) out of the MerklePaymentMade
    /// log in a payForMerkleTree receipt. It's already a 0x-prefixed 32-byte hash.
    private func parseWinnerPoolHash(from receipt: [String: Any]) -> String? {
        guard let logs = receipt["logs"] as? [[String: Any]] else { return nil }
        let topic0 = EthCalldata.merklePaymentMadeTopic0.lowercased()
        for log in logs {
            guard let topics = log["topics"] as? [String], topics.count >= 2 else { continue }
            if topics[0].lowercased() == topic0 { return topics[1] }
        }
        return nil
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
    private func devnetUpload(id: Int64, data: Data) async {
        do {
            let c = try await devnetClient()
            updateUpload(id) { $0.status = .uploading }
            let r = try await c.dataPutPublic(data: data, paymentMode: "auto")
            updateUpload(id) {
                $0.status = .complete; $0.address = r.address
                $0.cost = "\(r.chunksStored) chunk(s) · \(r.paymentModeUsed)"
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

    private struct DevnetEvm { let rpc: String; let token: String; let vault: String; let chainId: Int }

    private enum StoreError: LocalizedError {
        case badManifest, approveReverted, receiptTimeout, noMerkleEvent
        var errorDescription: String? {
            switch self {
            case .badManifest: return "Could not read devnet manifest EVM section"
            case .approveReverted: return "A payment transaction reverted on-chain"
            case .receiptTimeout: return "Timed out waiting for a transaction to confirm"
            case .noMerkleEvent: return "payForMerkleTree receipt had no MerklePaymentMade event"
            }
        }
    }

    private func parseManifestEvm() throws -> DevnetEvm {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evm = json["evm"] as? [String: Any],
              let rpc = evm["rpc_url"] as? String,
              let token = evm["payment_token_address"] as? String,
              let vault = evm["payment_vault_address"] as? String
        else { throw StoreError.badManifest }
        let chainId: Int
        if rpc.range(of: "sepolia", options: .caseInsensitive) != nil { chainId = 421614 }
        else if rpc.contains("arb1") { chainId = 42161 }
        else { chainId = 421614 }
        return DevnetEvm(rpc: rpc, token: token, vault: vault, chainId: chainId)
    }

    private func waitForReceipt(rpc: String, txHash: String, timeout: TimeInterval = 60) async throws {
        guard let url = URL(string: rpc) else { throw StoreError.badManifest }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_getTransactionReceipt", "params": [txHash],
            ])
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let status = result["status"] as? String {
                if status == "0x1" { return }
                if status == "0x0" { throw StoreError.approveReverted }
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw StoreError.receiptTimeout
    }

    /// Total gas spent (ETH) across the given tx hashes, read from their
    /// receipts (`gasUsed × effectiveGasPrice`). Nil if none could be read.
    private func gasSpentEth(rpc: String, txHashes: [String]) async -> String? {
        var totalWei: Double = 0
        for h in txHashes {
            guard let receipt = await getReceipt(rpc: rpc, txHash: h),
                  let usedHex = receipt["gasUsed"] as? String,
                  let priceHex = receipt["effectiveGasPrice"] as? String,
                  let used = UInt64(usedHex.dropFirst(2), radix: 16),
                  let price = UInt64(priceHex.dropFirst(2), radix: 16) else { continue }
            totalWei += Double(used) * Double(price)
        }
        guard totalWei > 0 else { return nil }
        return String(format: "%.6f", totalWei / 1e18)
    }

    private func getReceipt(rpc: String, txHash: String) async -> [String: Any]? {
        guard let url = URL(string: rpc) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionReceipt", "params": [txHash],
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["result"] as? [String: Any]
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
