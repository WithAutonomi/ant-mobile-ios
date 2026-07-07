import Foundation

/// Minimal, dependency-free EVM ABI calldata encoding — just enough for the
/// two Autonomi payment calls. This is the Swift counterpart to what the
/// desktop app builds with viem (`ant-ui/utils/payment.ts`).
///
/// Function selectors are hard-coded (precomputed keccak256 of the signature)
/// so we don't need a keccak implementation in the demo:
///   approve(address,uint256)                                  -> 0x095ea7b3
///   payForQuotes((address,uint256,bytes32)[])                 -> 0xb6c2141b
///   payForMerkleTree(uint8,(bytes32,(address,uint256)[16])[],uint64) -> 0x5460f240
///
/// (Verified with `cast sig`. An earlier value of 0x77a23fd7 was wrong — it
/// matches no function on the deployed PaymentVault, so calls fell through to
/// the fallback and reverted with empty data.)
///
/// All integers are encoded big-endian, left-padded to 32 bytes.
enum EthCalldata {
    // MARK: Selectors
    static let approveSelector = "095ea7b3"
    static let payForQuotesSelector = "b6c2141b"
    static let payForMerkleTreeSelector = "5460f240"

    /// keccak256("MerklePaymentMade(bytes32,uint8,uint256,uint64)") — topic0 of
    /// the event the PaymentVault emits from `payForMerkleTree`. `winnerPoolHash`
    /// is `indexed`, so it lands in `topics[1]` of the matching receipt log;
    /// that hash is what `finalize_upload_merkle` needs.
    static let merklePaymentMadeTopic0 =
        "0x89f0ad3859fec321e325bcc553fe234bcad374789a86f7ba932067f3f05affec"

    /// ERC-20 `approve(spender, amount)`.
    /// `amount` is a base-10 string (atto-token amounts exceed UInt64).
    static func approve(spender: String, amount: String) -> String {
        "0x" + approveSelector
            + word(address: spender)
            + word(uint256Decimal: amount)
    }

    /// A single PaymentVault quote payment.
    struct QuotePayment {
        let rewardsAddress: String   // 0x… address
        let amount: String           // base-10 atto-token amount
        let quoteHash: String        // 0x… 32-byte hash
    }

    /// PaymentVault `payForQuotes((address,uint256,bytes32)[])`.
    ///
    /// The tuple `(address,uint256,bytes32)` is static (3 words), so the
    /// dynamic array encodes as: head offset (0x20) → length → each tuple's
    /// 3 words laid out consecutively.
    static func payForQuotes(_ payments: [QuotePayment]) -> String {
        var body = ""
        body += word(uint256: 0x20)              // offset to array data
        body += word(uint256: UInt64(payments.count))
        for p in payments {
            body += word(address: p.rewardsAddress)
            body += word(uint256Decimal: p.amount)
            body += word(bytes32: p.quoteHash)
        }
        return "0x" + payForQuotesSelector + body
    }

    /// One candidate node inside a pool commitment (matches the FFI
    /// `CandidateNodeEntry`).
    struct MerkleCandidate {
        let rewardsAddress: String   // 0x… address
        let amount: String           // base-10 atto-token amount (node price)
    }

    /// One pool commitment (matches the FFI `PoolCommitmentEntry`). `candidates`
    /// must contain exactly `CANDIDATES_PER_POOL` (16) entries.
    struct PoolCommitment {
        let poolHash: String              // 0x… 32-byte hash
        let candidates: [MerkleCandidate] // exactly 16
    }

    /// PaymentVault `payForMerkleTree(uint8 depth, PoolCommitment[], uint64 ts)`
    /// where `PoolCommitment = (bytes32 poolHash, (address,uint256)[16] candidates)`.
    ///
    /// Encoding note: `PoolCommitment` is a *fully static* tuple — `bytes32`
    /// (1 word) + a fixed `[16]` array of static `(address,uint256)` (32 words)
    /// = 33 words, no dynamic parts. So the dynamic `PoolCommitment[]` needs no
    /// per-element offsets: it's just `length` followed by each element's 33
    /// words laid out consecutively. The top-level arg head is 3 words
    /// (depth · offset · ts); the array's data starts at offset 0x60.
    static func payForMerkleTree(
        depth: UInt8,
        poolCommitments: [PoolCommitment],
        timestamp: UInt64
    ) -> String {
        var body = ""
        body += word(uint256: UInt64(depth))     // head 0: depth (uint8)
        body += word(uint256: 0x60)              // head 1: offset to array (after 3 head words)
        body += word(uint256: timestamp)         // head 2: merklePaymentTimestamp
        body += word(uint256: UInt64(poolCommitments.count)) // array length
        for pc in poolCommitments {
            body += word(bytes32: pc.poolHash)
            precondition(
                pc.candidates.count == 16,
                "each pool commitment must have exactly 16 candidates, got \(pc.candidates.count)"
            )
            for c in pc.candidates {
                body += word(address: c.rewardsAddress)
                body += word(uint256Decimal: c.amount)
            }
        }
        return "0x" + payForMerkleTreeSelector + body
    }

    // MARK: - Word encoders (each returns a 64-hex-char / 32-byte word)

    static func word(address: String) -> String {
        let clean = strip0x(address).lowercased()
        precondition(clean.count == 40, "address must be 20 bytes: \(address)")
        return String(repeating: "0", count: 24) + clean
    }

    static func word(bytes32: String) -> String {
        let clean = strip0x(bytes32)
        precondition(clean.count == 64, "bytes32 must be 32 bytes: \(bytes32)")
        return clean
    }

    static func word(uint256: UInt64) -> String {
        let hex = String(uint256, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }

    /// Encode an arbitrary-precision base-10 integer (as a string) into a
    /// 32-byte big-endian word. Handles values far beyond UInt64 (atto tokens)
    /// via manual base-10 → base-256 conversion, so we need no BigInt dep.
    static func word(uint256Decimal decimal: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32) // big-endian
        for ch in decimal {
            guard let digit = ch.wholeNumberValue, (0...9).contains(digit) else {
                precondition(false, "non-decimal digit in amount: \(decimal)")
                continue
            }
            // bytes = bytes * 10 + digit
            var carry = digit
            for i in stride(from: 31, through: 0, by: -1) {
                let v = Int(bytes[i]) * 10 + carry
                bytes[i] = UInt8(v & 0xff)
                carry = v >> 8
            }
            precondition(carry == 0, "amount overflows uint256: \(decimal)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func strip0x(_ s: String) -> String {
        s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    }
}
