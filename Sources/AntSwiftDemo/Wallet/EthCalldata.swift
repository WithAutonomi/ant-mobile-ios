import Foundation

/// Minimal, dependency-free EVM ABI calldata encoding — just enough for the
/// two Autonomi payment calls. This is the Swift counterpart to what the
/// desktop app builds with viem (`ant-ui/utils/payment.ts`).
///
/// Function selectors are hard-coded (precomputed keccak256 of the signature)
/// so we don't need a keccak implementation in the demo:
///   approve(address,uint256)                                  -> 0x095ea7b3
///   payForQuotes((address,uint256,bytes32)[])                 -> 0xb6c2141b
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
