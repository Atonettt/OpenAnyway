import Foundation

/// Direct (no subprocess) access to extended attributes.
enum ExtendedAttributes {
    static let quarantine = "com.apple.quarantine"
    /// System-managed; cannot be removed by users and does not affect codesign/Gatekeeper.
    static let provenance = "com.apple.provenance"
    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"

    static func value(_ name: String, at path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data.prefix(read) : nil
    }

    static func has(_ name: String, at path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Paths (root first) that carry the attribute. Capped to keep huge bundles fast.
    static func paths(with name: String, under root: URL, limit: Int = 250_000) -> [String] {
        var found: [String] = []
        if has(name, at: root.path) { found.append(root.path) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [], errorHandler: { _, _ in true }) else {
            return found
        }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit { break }
            if has(name, at: url.path) { found.append(url.path) }
        }
        return found
    }

    /// Removes the attribute from every path. Returns paths that could not be changed.
    @discardableResult
    static func remove(_ name: String, from paths: [String]) -> [String] {
        paths.filter { path in
            !withTemporaryWriteAccess(path) {
                removexattr(path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR
            }
        }
    }

    /// Removes every extended attribute from every path. Returns paths that could not be changed.
    @discardableResult
    static func removeAll(from paths: [String]) -> [String] {
        paths.filter { path in
            !withTemporaryWriteAccess(path) {
                names(at: path).filter { $0 != provenance }.allSatisfy { removexattr(path, $0, XATTR_NOFOLLOW) == 0 || errno == ENOATTR }
            }
        }
    }

    static func names(at path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer[0..<read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// Read-only files (e.g. mode 444) reject attribute changes even for their owner.
    /// If the operation fails with a permission error on a file we own, temporarily add the
    /// owner-write bit, retry, then restore the original mode.
    private static func withTemporaryWriteAccess(_ path: String, _ operation: () -> Bool) -> Bool {
        if operation() { return true }
        guard errno == EACCES || errno == EPERM else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) != S_IFLNK, (info.st_mode & S_IWUSR) == 0 else { return false }
        let original = info.st_mode & 0o7777
        guard chmod(path, original | S_IWUSR) == 0 else { return false }
        let ok = operation()
        chmod(path, original)
        return ok
    }

    /// Parses "flags;timestamp;agent;uuid".
    static func quarantineAgent(at path: String) -> (raw: String, agent: String?)? {
        guard let data = value(quarantine, at: path) else { return nil }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        let agent = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
        return (raw, agent)
    }

    static func downloadSources(at path: String) -> [String] {
        guard let data = value(whereFroms, at: path),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return list.filter { !$0.isEmpty }
    }
}
