import Foundation

/// `autonomi://` URI parsing — a Swift port of ant-webex's `parseAntUri` /
/// `buildFilename` / `sanitizeFilename` (and the Android demo's AntUri), so the
/// app resolves the download filename with the exact same fallbacks the browser
/// extension uses.
///
/// Shape: `autonomi://<64-hex-address>` optionally followed by query params,
/// introduced by `?` **or** `&` (ant-webex accepts either). Recognized params:
///   - `name`     — author-suggested base filename
///   - `filetype` — extension appended to `name` (deduped)
///   - `filename` — explicit full filename (takes precedence)
enum AntUri {
    private static let scheme = "autonomi://"

    struct Parsed { let address: String; let name: String? }

    static func parse(_ uri: String) -> Parsed {
        let body = uri.hasPrefix(scheme) ? String(uri.dropFirst(scheme.count)) : uri
        guard let sepIdx = body.firstIndex(where: { $0 == "?" || $0 == "&" }) else {
            return Parsed(address: body, name: nil)
        }
        let address = String(body[body.startIndex..<sepIdx])
        let params = parseQuery(String(body[body.index(after: sepIdx)...]))
        // Explicit `filename` wins; else combine name + filetype like ant-webex.
        let explicit = params["filename"]?.trimmingCharacters(in: .whitespaces)
        let name = (explicit?.isEmpty == false)
            ? explicit
            : buildFilename(name: params["name"]?.trimmingCharacters(in: .whitespaces),
                            filetype: params["filetype"]?.trimmingCharacters(in: .whitespaces))
        return Parsed(address: address, name: name)
    }

    static func isValidAddress(_ addr: String) -> Bool {
        addr.count == 64 && addr.allSatisfy { $0.isHexDigit }
    }

    /// ant-webex `buildFilename`: both → `name.filetype`; only name → name;
    /// no name → nil. Leading dots stripped; extension not doubled.
    static func buildFilename(name: String?, filetype: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        var ext = filetype ?? ""
        while ext.hasPrefix(".") { ext.removeFirst() }
        ext = ext.trimmingCharacters(in: .whitespaces)
        if ext.isEmpty { return name }
        if name.lowercased().hasSuffix(".\(ext.lowercased())") { return name }
        return "\(name).\(ext)"
    }

    /// ant-webex `sanitizeFilename`: basename, strip control + `<>:"|?*`, strip
    /// leading dots, trim, cap at 200. May return "".
    static func sanitizeFilename(_ name: String) -> String {
        let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        let forbidden = CharacterSet(charactersIn: "<>:\"|?*").union(.controlCharacters)
        var out = String(base.unicodeScalars.filter { !forbidden.contains($0) })
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        return String(out.prefix(200))
    }

    /// Final download filename with ant-webex's address-derived fallback.
    static func resolveFilename(_ parsed: Parsed) -> String {
        let sanitized = parsed.name.map(sanitizeFilename)
        if let sanitized, !sanitized.isEmpty { return sanitized }
        return "autonomi-\(parsed.address.prefix(12))"
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = decode(String(pair[pair.startIndex..<eq]))
            let value = decode(String(pair[pair.index(after: eq)...]))
            result[key] = value
        }
        return result
    }

    private static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }
}
