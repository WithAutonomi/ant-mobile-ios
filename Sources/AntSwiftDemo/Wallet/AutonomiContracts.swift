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

    var caip2: String { "eip155:\(chainId)" }

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
