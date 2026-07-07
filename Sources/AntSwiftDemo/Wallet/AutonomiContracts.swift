import Foundation

/// On-chain coordinates for Autonomi payments, mirroring the desktop app's
/// `utils/wallet-config.ts`. Uploads are paid by approving the payment-vault
/// contract to spend the network token, then calling `payForQuotes` /
/// `payForMerkleTree` on the vault.
///
/// Spike scope: only the Arbitrum One (mainnet) addresses are known here —
/// they come straight from the desktop config. For Arbitrum Sepolia the
/// token/vault addresses differ per devnet; fill `sepolia` from your devnet
/// manifest (or the ant-ui Sepolia config) before testing against testnet.
enum AutonomiChain {
    case arbitrumOne
    case arbitrumSepolia

    /// EVM chain id used to build a WalletConnect `eip155:<id>` blockchain.
    var chainId: Int {
        switch self {
        case .arbitrumOne: return 42161
        case .arbitrumSepolia: return 421614
        }
    }

    /// Map a connected wallet's chain id back to a known Autonomi chain, so we
    /// can read balances from the right RPC / token. Nil for unknown chains.
    init?(chainId: Int) {
        switch chainId {
        case 42161: self = .arbitrumOne
        case 421614: self = .arbitrumSepolia
        default: return nil
        }
    }

    var caip2: String { "eip155:\(chainId)" }

    /// Public JSON-RPC endpoint for read-only balance queries on this chain.
    var rpcUrl: String {
        switch self {
        case .arbitrumOne: return "https://arb1.arbitrum.io/rpc"
        case .arbitrumSepolia: return "https://sepolia-rollup.arbitrum.io/rpc"
        }
    }

    /// Whether the ERC-20 token address is a real (non-zero) deployment — the
    /// Sepolia address is a per-devnet placeholder, so ANT balance is unknown there.
    var hasKnownToken: Bool {
        tokenAddress != "0x0000000000000000000000000000000000000000"
    }

    /// ERC-20 network token ("ANT") address.
    var tokenAddress: String {
        switch self {
        case .arbitrumOne: return "0xa78d8321B20c4Ef90eCd72f2588AA985A4BDb684"
        // TODO(spike): set from your devnet manifest before testing on Sepolia.
        case .arbitrumSepolia: return "0x0000000000000000000000000000000000000000"
        }
    }

    /// PaymentVault contract — the `approve` spender and `payForQuotes` target.
    var paymentVaultAddress: String {
        switch self {
        case .arbitrumOne: return "0x9A3EcAc693b699Fc0B2B6A50B5549e50c2320A26"
        // TODO(spike): set from your devnet manifest before testing on Sepolia.
        case .arbitrumSepolia: return "0x0000000000000000000000000000000000000000"
        }
    }
}
