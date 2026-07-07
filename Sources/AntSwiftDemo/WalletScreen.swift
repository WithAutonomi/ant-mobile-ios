import SwiftUI

/// Wallet — external-signer connect + a payment test, plus mock balances
/// (mirrors ant-ui/pages/wallet.vue and the Android demo). Connect opens the
/// Reown AppKit modal; "Send test approve tx" has the wallet sign a real
/// payment-vault approve. iOS-only feature — macOS shows a note.
struct WalletScreen: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var store: FilesStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                #if os(iOS)
                WalletContent()
                #else
                AntCard {
                    Text("Wallet").font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
                    Text("WalletConnect is available in the iOS app.")
                        .font(.caption).foregroundStyle(theme.muted)
                }
                #endif
            }
            .padding(16)
        }
        .antBackground()
        .navigationTitle("Wallet")
        .onAppear { store.refreshNetwork() }
    }
}

#if os(iOS)
private struct WalletContent: View {
    @EnvironmentObject private var theme: ThemeController
    @EnvironmentObject private var wallet: WalletConnectManager

    var body: some View {
        // Connection
        AntCard {
            HStack {
                Text("Connection").font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
                Spacer()
                NetworkBadge()
            }
            if let address = wallet.address {
                Text(address).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.text).textSelection(.enabled)
                Text("Chain: \(wallet.chainCaip2 ?? "?")").font(.caption).foregroundStyle(theme.muted)
                Button("Disconnect") { Task { await wallet.disconnect() } }
                    .buttonStyle(.bordered).tint(AntColors.error)
            } else {
                Button("Connect Wallet") { wallet.connect() }
                    .buttonStyle(.borderedProminent)
                Button("Copy pairing URI (cross-device QR)") {
                    Task { await wallet.copyPairingUri() }
                }
                .buttonStyle(.bordered)
            }
            Text(wallet.status).font(.caption).foregroundStyle(theme.muted)
        }

        // Mock balances (as the desktop wallet page shows token holdings).
        AntCard {
            Text("Balances").font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
            BalanceRow(symbol: "ANT", amount: "715.17361")
            BalanceRow(symbol: "ETH", amount: "0.01396")
        }

        // Payment test (only when connected).
        if wallet.address != nil {
            AntCard {
                Text("Payment test").font(.subheadline).fontWeight(.medium).foregroundStyle(theme.text)
                Text("Signs a real payment-vault approve (amount 0 → gas only).")
                    .font(.caption).foregroundStyle(theme.muted)
                Button("Send test approve tx (Arbitrum One)") {
                    Task { _ = try? await wallet.sendApprove(chain: .arbitrumOne, amount: "0") }
                }
                .buttonStyle(.borderedProminent)
                if let hash = wallet.lastTxHash {
                    Text("tx: \(hash)").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.text).textSelection(.enabled)
                }
            }
        }
    }
}

private struct BalanceRow: View {
    @EnvironmentObject private var theme: ThemeController
    let symbol: String
    let amount: String
    var body: some View {
        HStack {
            Text(symbol).font(.subheadline).foregroundStyle(theme.text)
            Spacer()
            Text(amount).font(.system(.subheadline, design: .monospaced)).foregroundStyle(theme.text)
        }
    }
}
#endif
