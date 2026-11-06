import Foundation

enum RepairService {
    static var backupFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OpenAnyway/Backups", isDirectory: true)
    }

    /// Runs the selected fixes in a fixed, safe order and re-inspects afterwards.
    static func perform(_ actions: Set<FixAction>, on fileURL: URL, expectedSHA: String,
                        backupBeforeResign: Bool) -> RepairOutcome {
        var target = fileURL
        var log: [String] = []
        var replacedCertificateSignature = false

        func fail(_ message: String) -> RepairOutcome {
            log.append("✗ " + message)
            return RepairOutcome(succeeded: false, message: log.joined(separator: "\n"), finalURL: target,
                                 latestReport: FileInspector.inspect(target, expectedSHA: expectedSHA))
        }

        for action in actions.sorted(by: { $0.order < $1.order }) {
            switch action {
            case .copyToApplications:
                let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(target.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    return fail(L("“应用程序”中已存在 \(destination.lastPathComponent)。请先手动删除或改名旧版本后再试。", "\(destination.lastPathComponent) already exists in Applications. Delete or rename the old copy first, then try again."))
                }
                let result = runWithFallback("/usr/bin/ditto", [target.path, destination.path], needsAdmin: false)
                guard result.ok else { return fail(L("复制到“应用程序”失败：\(result.output)", "Copying to Applications failed: \(result.output)")) }
                target = destination
                log.append(L("✓ 已复制到 \(destination.path)", "✓ Copied to \(destination.path)"))

            case .clearQuarantine:
                let paths = isDirectory(target)
                    ? ExtendedAttributes.paths(with: ExtendedAttributes.quarantine, under: target)
                    : (ExtendedAttributes.has(ExtendedAttributes.quarantine, at: target.path) ? [target.path] : [])
                let failed = ExtendedAttributes.remove(ExtendedAttributes.quarantine, from: paths)
                if !failed.isEmpty {
                    // Only the files that really failed, each named explicitly; -s acts on symlinks themselves.
                    let admin = PrivilegedRunner.run("/usr/bin/xattr", ["-d", "-s", ExtendedAttributes.quarantine] + failed)
                    if PrivilegedRunner.userCancelled(admin) { return fail(L("已取消管理员授权。", "Administrator authorization was cancelled.")) }
                }
                let remaining = isDirectory(target)
                    ? ExtendedAttributes.paths(with: ExtendedAttributes.quarantine, under: target)
                    : (ExtendedAttributes.has(ExtendedAttributes.quarantine, at: target.path) ? [target.path] : [])
                guard remaining.isEmpty else {
                    return fail(L("仍有 \(remaining.count) 个文件带隔离标记（权限不足或受系统保护）：\n", "\(remaining.count) files still have a quarantine flag (no permission or protected by macOS):\n")
                                + remaining.prefix(5).joined(separator: "\n"))
                }
                log.append(L("✓ 已移除 \(paths.count) 个文件的隔离标记", "✓ Removed quarantine flags from \(paths.count) files"))

            case .clearAllAttributes:
                if let error = stripAllAttributes(target) { return fail(error) }
                log.append(L("✓ 已清除全部扩展属性", "✓ Cleared all extended attributes"))

            case .adhocResign:
                if backupBeforeResign {
                    if let backup = backup(target) {
                        log.append(L("✓ 已备份原应用到 \(backup.path)", "✓ Backed up the original app to \(backup.path)"))
                    } else {
                        return fail(L("备份失败，为安全起见未执行重签名。可在界面中取消“修改前备份”后重试。", "Backup failed, so re-signing was skipped to be safe. You can turn off the backup option and try again."))
                    }
                }
                // codesign refuses bundles whose files carry Finder info, resource forks or
                // similar metadata ("detritus not allowed"), so strip them first.
                if !actions.contains(.clearAllAttributes) {
                    if let error = stripAllAttributes(target) { return fail(L("重签名前清理扩展属性失败：", "Clearing extended attributes before re-signing failed: ") + error) }
                    log.append(L("✓ 已清除扩展属性（重签名前置步骤）", "✓ Cleared extended attributes (needed for re-signing)"))
                }
                let originalKind = FileInspector.signatureKind(
                    from: CommandRunner.run("/usr/bin/codesign", ["-dv", "--verbose=2", target.path]).output)
                let result = runWithFallback("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", target.path],
                                             needsAdmin: !canModify(target))
                guard result.ok else { return fail(L("重签名失败：\(result.output)", "Re-signing failed: \(result.output)")) }
                log.append(L("✓ 已完成本地 ad-hoc 重签名", "✓ Re-signed locally (ad-hoc)"))
                if originalKind.isCertificateSigned {
                    replacedCertificateSignature = true
                }
            }
        }

        let after = FileInspector.inspect(target, expectedSHA: expectedSHA)
        let stillQuarantined = after.quarantinedItemCount > 0
            && (actions.contains(.clearQuarantine) || actions.contains(.clearAllAttributes))
        let signatureBroken = after.kind.hasCodeSignature && after.signatureValid == false
        var ok = !stillQuarantined
        if actions.contains(.adhocResign) && signatureBroken { ok = false; log.append(L("✗ 复查：签名仍未通过校验", "✗ Re-check: the signature is still invalid")) }
        if ok && replacedCertificateSignature {
            log.append(L("⚠️ 此应用原本由厂商正式签名，双击仍会被 macOS 拦截，需要在“隐私与安全性”里点“仍要打开”放行。", "⚠️ This app was originally signed by its developer. macOS will still block it until you click “Open Anyway” in Privacy & Security."))
        } else if ok {
            log.append(L("复查完成，可以尝试打开了。", "Re-check done. Try opening it now."))
        }
        return RepairOutcome(succeeded: ok, message: log.joined(separator: "\n"), finalURL: target, latestReport: after,
                             needsOpenAnyway: ok && replacedCertificateSignature)
    }

    // MARK: Helpers

    /// Removes every extended attribute from the item and everything inside it.
    /// Returns an error message, or nil on success.
    private static func stripAllAttributes(_ target: URL) -> String? {
        var all = [target.path]
        if isDirectory(target), let e = FileManager.default.enumerator(atPath: target.path) {
            for case let rel as String in e { all.append(target.appendingPathComponent(rel).path) }
        }
        let failed = ExtendedAttributes.removeAll(from: all)
        guard !failed.isEmpty else { return nil }
        let admin = PrivilegedRunner.run("/usr/bin/xattr", ["-c", "-s"] + failed)
        if PrivilegedRunner.userCancelled(admin) { return L("已取消管理员授权。", "Administrator authorization was cancelled.") }
        // com.apple.provenance is managed by the system and does not block codesign.
        let left = failed.filter { !ExtendedAttributes.names(at: $0).filter { $0 != "com.apple.provenance" }.isEmpty }
        guard left.isEmpty else {
            return L("仍有 \(left.count) 个文件无法清除扩展属性：\n", "\(left.count) files still have extended attributes:\n") + left.prefix(5).joined(separator: "\n")
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func canModify(_ url: URL) -> Bool {
        guard FileManager.default.isWritableFile(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }

    /// Tries as the current user first; on permission errors asks for administrator rights.
    private static func runWithFallback(_ tool: String, _ args: [String], needsAdmin: Bool) -> (ok: Bool, output: String) {
        if !needsAdmin {
            let first = CommandRunner.run(tool, args, timeout: 600)
            if first.succeeded { return (true, first.output) }
            let lower = first.output.lowercased()
            let permission = lower.contains("permission denied") || lower.contains("operation not permitted")
                || lower.contains("not permitted") || lower.contains("read-only")
            if !permission { return (false, first.output) }
        }
        let admin = PrivilegedRunner.run(tool, args)
        if PrivilegedRunner.userCancelled(admin) { return (false, L("已取消管理员授权。", "Administrator authorization was cancelled.")) }
        return (admin.succeeded, admin.output)
    }

    private static func backup(_ url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = backupFolder.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        // APFS clone first (instant, no extra disk space), plain copy otherwise.
        if CommandRunner.run("/bin/cp", ["-cR", url.path, destination.path], timeout: 600).succeeded { return destination }
        if CommandRunner.run("/usr/bin/ditto", [url.path, destination.path], timeout: 900).succeeded { return destination }
        return nil
    }
}
