#if os(iOS)
import Foundation
import Combine
import UIKit  // UIPasteboard — to surface the pairing URI for cross-device QR
// Reown AppKit (product/module `ReownAppKit`). iOS-only: the connect modal and
// some transitive deps (CoinbaseWalletSDK) are iOS-oriented, so the whole
// feature is gated with #if os(iOS) and excluded from the macOS build.
import ReownAppKit
// WalletConnectNetworking re-exports WalletConnectRelay (WebSocketFactory /
// WebSocketConnecting). Required to call Networking.configure(...) before
// AppKit.configure — the SDK asserts otherwise.
import WalletConnectNetworking

/// A `WebSocketConnecting` backed by Foundation's URLSessionWebSocketTask, so we
/// don't need Starscream (the reown sample's socket dep). Satisfies the relay's
/// WebSocketFactory contract.
private final class URLSessionWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var isConnected: Bool = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(request: URLRequest) { self.request = request; super.init() }

    func connect() {
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receive()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { _ in completion?() }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message { self.onText?(text) }
                self.receive()
            case let .failure(error):
                self.isConnected = false
                self.onDisconnect?(error)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isConnected = true
        onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        onDisconnect?(nil)
    }
}

private struct SwiftSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        URLSessionWebSocket(request: URLRequest(url: url))
    }
}

/// WalletConnect spike: connect an external self-custody wallet (MetaMask,
/// Rainbow, …) via Reown AppKit and have it sign an Autonomi payment
/// transaction. The app never holds a key — the mobile equivalent of the
/// desktop app's Reown AppKit + wagmi external-signer flow.
///
/// API verified against the resolved reown-swift source (sessionsPublisher /
/// sessionResponsePublisher, AppKit.configure, request(.eth_sendTransaction),
/// getAddress/getSelectedChain).
@MainActor
final class WalletConnectManager: ObservableObject {
    @Published var address: String?
    @Published var chainCaip2: String?
    @Published var lastTxHash: String?
    @Published var status: String = "Not connected"

    /// Live ANT / ETH balances for the connected wallet on its current chain,
    /// read directly from that chain's RPC (see `refreshBalances`). Each is nil
    /// when not connected, the chain is unknown, or the read failed. This is a
    /// cosmetic read-only view — nothing depends on it for payments.
    struct Balances: Equatable { var ant: String?; var eth: String? }
    @Published var balances = Balances()

    private var cancellables = Set<AnyCancellable>()
    private var configured = false

    /// Arbitrum Sepolia as an AppKit Chain — the payment chain for the devnet.
    /// Requests route to AppKit's *selected* chain, so we select this after
    /// connecting (the request's own chainId field is ignored by the SDK).
    private let arbitrumSepoliaChain = Chain(
        chainName: "Arbitrum Sepolia",
        chainNamespace: "eip155",
        chainReference: "421614",
        requiredMethods: ["personal_sign", "eth_signTypedData", "eth_sendTransaction"],
        optionalMethods: ["wallet_switchEthereumChain", "wallet_addEthereumChain"],
        events: ["chainChanged", "accountsChanged"],
        token: .init(name: "Ether", symbol: "ETH", decimal: 18),
        rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc",
        blockExplorerUrl: "https://sepolia.arbiscan.io",
        imageId: ""
    )

    /// Get a projectId from https://dashboard.reown.com.
    func configure(projectId: String) {
        guard !configured else { return }
        configured = true

        // `native` must match a URL scheme the app handles so wallets can
        // deep-link back after signing. The scheme is well-formed, so the
        // throwing initializer never fails here.
        let metadata = AppMetadata(
            name: "AntSwiftDemo",
            description: "Autonomi mobile bindings demo",
            url: "https://autonomi.com",
            icons: ["https://avatars.githubusercontent.com/u/179229932"],
            redirect: try! AppMetadata.Redirect(native: "antswiftdemo://", universal: nil)
        )

        // MUST run before AppKit.configure — AppKit accesses the Networking
        // layer during configure and fatal-errors if it isn't set up first.
        Networking.configure(
            groupIdentifier: "group.com.autonomi.examples.AntSwiftDemo",
            projectId: projectId,
            socketFactory: SwiftSocketFactory()
        )

        // Propose ONLY the devnet chain (Arbitrum Sepolia). Offering mainnet too
        // let the wallet negotiate a mainnet-only session and silently sign the
        // payment on Arbitrum One, while the app polls the Sepolia RPC for the
        // receipt (→ "timed out waiting for transaction to confirm"). Proposing
        // just Sepolia forces the session onto the manifest's chain.
        let namespaces: [String: ProposalNamespace] = [
            "eip155": ProposalNamespace(
                chains: [Blockchain("eip155:421614")!],
                methods: ["personal_sign", "eth_signTypedData", "eth_sendTransaction",
                          "wallet_switchEthereumChain", "wallet_addEthereumChain"],
                events: ["chainChanged", "accountsChanged"]
            )
        ]

        AppKit.configure(
            projectId: projectId,
            metadata: metadata,
            crypto: SpikeCryptoProvider(), // only used by SIWE, which we don't use
            sessionParams: SessionParams(namespaces: namespaces),
            authRequestParams: nil
        )

        AppKit.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
        status = "Configured — tap Connect Wallet"
    }

    /// Present the Reown connect modal (QR + installed-wallet deep links).
    func connect() { AppKit.present() }

    /// Disconnect the current session (WalletConnect persists sessions, so this
    /// is needed to drop a stale one — e.g. one stuck on the wrong chain — and
    /// pair fresh).
    func disconnect() async {
        if let session = AppKit.instance.getSessions().first {
            try? await AppKit.instance.disconnect(topic: session.topic)
        }
        refresh()
    }

    /// Cross-device pairing: generate a WalletConnect pairing URI + session
    /// proposal and copy it to the clipboard. Used when the wallet is on a
    /// different device (e.g. the app runs in the iOS Simulator and the wallet
    /// is a physical phone) — the URI is turned into a QR to scan.
    func copyPairingUri() async {
        do {
            let uri = try await AppKit.instance.connect(walletUniversalLink: nil)
            if let s = uri?.absoluteString {
                UIPasteboard.general.string = s
                status = "Pairing URI copied — scan the QR"
            } else {
                status = "No pairing URI returned"
            }
        } catch {
            status = "Pairing URI failed: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        address = AppKit.instance.getAddress()
        if address != nil {
            // Route requests to Arbitrum Sepolia (the payment chain).
            AppKit.instance.selectChain(arbitrumSepoliaChain)
        }
        if let chain = AppKit.instance.getSelectedChain() {
            chainCaip2 = "\(chain.chainNamespace):\(chain.chainReference)"
        } else {
            chainCaip2 = nil
        }
        status = address == nil ? "Not connected" : "Connected"
        if address != nil { refreshBalances() } else { balances = Balances() }
    }

    /// Read the connected wallet's ANT + ETH balances from its current chain's
    /// public RPC (`eth_getBalance` for the gas token, ERC-20 `balanceOf` for
    /// ANT). Cosmetic and read-only — unknown chains / tokens leave a field nil
    /// (the UI shows "—"). No effect on the payment flow.
    func refreshBalances() {
        guard let address,
              let idPart = chainCaip2?.split(separator: ":").last,
              let chainId = Int(idPart),
              let chain = AutonomiChain(chainId: chainId) else {
            balances = Balances()
            return
        }
        Task {
            async let ethHex = Self.rpcResult(rpc: chain.rpcUrl, method: "eth_getBalance",
                                              params: [address, "latest"])
            async let antHex: String? = chain.hasKnownToken
                ? Self.rpcResult(rpc: chain.rpcUrl, method: "eth_call",
                                 params: [["to": chain.tokenAddress, "data": Self.balanceOfData(address)], "latest"])
                : nil
            let eth = (await ethHex).map { Self.formatUnits($0, places: 6) }
            let ant = (await antHex).map { Self.formatUnits($0, places: 4) }
            balances = Balances(ant: ant, eth: eth)
        }
    }

    /// ERC-20 `balanceOf(address)` calldata (selector 0x70a08231 + padded addr).
    private static func balanceOfData(_ address: String) -> String {
        let clean = (address.hasPrefix("0x") ? String(address.dropFirst(2)) : address).lowercased()
        return "0x70a08231" + String(repeating: "0", count: 24) + clean
    }

    /// One read-only JSON-RPC call; returns the `result` hex string or nil.
    private static func rpcResult(rpc: String, method: String, params: [Any]) async -> String? {
        guard let url = URL(string: rpc) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else { return nil }
        return result
    }

    /// Format a 0x hex quantity as a token amount (÷1e18). Accumulates in Double —
    /// fine for a display value (we only show a few decimals).
    private static func formatUnits(_ hex: String, places: Int) -> String {
        var v = 0.0
        for c in hex.lowercased() where c.isHexDigit { v = v * 16 + Double(c.hexDigitValue ?? 0) }
        return String(format: "%.\(places)f", v / 1e18)
    }

    /// Send a raw `eth_sendTransaction` (to, calldata) on `chainId` to the
    /// connected wallet for signing. Returns the broadcast tx hash.
    ///
    /// Retries on the relay's "Invalid Id": the first request after (re)connect
    /// can be rejected before it reaches the wallet while the session
    /// subscription / socket is still warming up. Nothing reaches the wallet in
    /// that case, so a retry is safe (no double prompt).
    func sendTransaction(to: String, data: String, chainId: Int) async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await sendOnce(to: to, data: data, chainId: chainId)
            } catch {
                lastError = error
                if attempt < 2 && isRetriable(error) {
                    status = "Connecting to wallet…"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SpikeError.badResponse
    }

    /// Whether an error looks like a transient relay-delivery failure worth
    /// retrying (vs a genuine wallet rejection).
    private func isRetriable(_ error: Error) -> Bool {
        "\(error)".lowercased().contains("invalid id")
    }

    /// One send attempt: build the request, fire it, await the id-matched response.
    private func sendOnce(to: String, data: String, chainId: Int) async throws -> String {
        guard let from = AppKit.instance.getAddress() else { throw SpikeError.notConnected }
        guard let topic = AppKit.instance.getSessions().first?.topic else { throw SpikeError.notConnected }
        guard let blockchain = Blockchain("eip155:\(chainId)") else { throw SpikeError.badResponse }
        status = "Awaiting wallet signature…"

        // Build the request ourselves rather than via AppKit's W3MJSONRPC enum:
        // its `.eth_sendTransaction` serialization passes the tx object *bare*
        // (params = {from,to,…}) instead of the JSON-RPC-required array
        // ([{from,to,…}]), and leaks a decimal `chainId` into the tx object.
        // MetaMask then does params[0] → undefined → "Cannot convert undefined
        // value to object". We wrap in an array and drop the stray chainId; the
        // real chain is carried by the Request's `chainId` (Blockchain) field.
        // Explicit EIP-1559 gas ceiling. Without it MetaMask underprices on
        // Arbitrum Sepolia (estimates ~0.02 gwei, which drops below base fee when
        // it ticks up → "max fee per gas less than block base fee"). maxFeePerGas
        // is only a ceiling — you're charged base + priority, so a generous cap
        // costs nothing on Arbitrum yet survives base-fee blips.
        //   maxFeePerGas        = 0.5 gwei  (0x1dcd6500 = 500_000_000 wei)
        //   maxPriorityFeePerGas = 0.01 gwei (0x989680  =  10_000_000 wei)
        //
        // We must also set an explicit `gas` (limit): once fee fields are present
        // MetaMask stops auto-estimating the limit on this WalletConnect path and
        // falls back to 21000 → "intrinsic gas too low" for a contract call.
        // Arbitrum folds L1 calldata cost into gas *units*, so estimates run high
        // (hundreds of k); 3,000,000 is safe headroom — you're only charged for
        // gas actually used, the limit is just a ceiling.
        //   gas = 3,000,000 (0x2dc6c0)
        let tx: [String: String] = [
            "from": from, "to": to, "value": "0x0", "data": data,
            "gas": "0x2dc6c0",
            "maxFeePerGas": "0x1dcd6500",
            "maxPriorityFeePerGas": "0x989680"
        ]
        let request = try Request(
            topic: topic,
            method: "eth_sendTransaction",
            params: AnyCodable(any: [tx]),
            chainId: blockchain
        )

        // Subscribe for the response *before* firing the request to avoid a race;
        // request() returns Void and the result arrives on the publisher.
        let hash: String = try await withCheckedThrowingContinuation { cont in
            var token: AnyCancellable?
            token = AppKit.instance.sessionResponsePublisher
                // Match the response to *this* request's id — not just the first
                // response on the stream, which could be a stale/unrelated one.
                .first { $0.id == request.id }
                .sink { response in
                    token?.cancel()
                    switch response.result {
                    case let .response(value):
                        if let h = try? value.get(String.self) {
                            cont.resume(returning: h)
                        } else {
                            cont.resume(throwing: SpikeError.badResponse)
                        }
                    case let .error(rpcError):
                        cont.resume(throwing: SpikeError.wallet(rpcError.message))
                    }
                }
            token?.store(in: &cancellables)

            Task {
                do {
                    try await AppKit.instance.request(params: request)
                } catch {
                    token?.cancel()
                    cont.resume(throwing: error)
                }
            }
        }

        lastTxHash = hash
        status = "Signed. tx: \(hash)"
        return hash
    }

    enum SpikeError: LocalizedError {
        case notConnected, badResponse
        case wallet(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "No wallet connected"
            case .badResponse: return "Unexpected wallet response"
            case let .wallet(msg): return "Wallet rejected/failed: \(msg)"
            }
        }
    }
}

/// Minimal CryptoProvider to satisfy `AppKit.configure`. These are only invoked
/// by SIWE / sign-in-with-ethereum verification, which this spike does not use
/// (authRequestParams: nil). If SIWE is added later, swap in a real keccak256 /
/// secp256k1 recover implementation.
private struct SpikeCryptoProvider: CryptoProvider {
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data { Data() }
    func keccak256(_ data: Data) -> Data { Data() }
}
#endif
