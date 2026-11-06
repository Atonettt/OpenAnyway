import Foundation

// All inspection work is read-only. A mounted DMG's inner APP must be selected separately.
enum FileInspector {
    static func inspect(_ input: URL, expectedSHA: String) -> InspectionReport {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        let kind = ItemKind(url: url)
        var report = InspectionReport(
            inspectedAt: Date(), filePath: url.path, kind: kind, checks: [],
            sha256: nil, expectedSHA256: Checksum.normalize(expectedSHA), hashMatched: nil,
            quarantinePresent: false, signatureValid: nil, developerSigned: nil,
            gatekeeperAccepted: nil, imageVerified: nil, pkgSigned: nil,
            writable: FileManager.default.isWritableFile(atPath: url.path),
            summary: "检查完成", level: .information
        )

        guard FileManager.default.fileExists(atPath: url.path) else {
            report.exists = false
            add(&report, "文件访问", .failed, "文件不存在或无法访问", url.path)
            finish(&report)
            return report
        }

        inspectLocation(url, report: &report)
        inspectQuarantine(url, report: &report)

        switch kind {
        case .app, .bundle:
            inspectCode(url, report: &report)
        case .dmg:
            inspectDMG(url, report: &report)
        case .pkg:
            inspectPKG(url, report: &report)
        case .other:
            inspectOther(url, report: &report)
        }

        finish(&report)
        return report
    }

    // MARK: Common

    private static func inspectLocation(_ url: URL, report: inout InspectionReport) {
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        report.onReadOnlyVolume = values?.volumeIsReadOnly ?? false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let owner = attrs[.ownerAccountID] as? NSNumber {
            report.ownedByOtherUser = owner.uint32Value != getuid()
        }
        if report.onReadOnlyVolume {
            add(&report, "文件位置", .warning, "位于只读卷（通常是已挂载的 DMG）",
                "只读位置无法修改。修复时会先把它复制到“应用程序”文件夹。")
        } else if !report.writable || report.ownedByOtherUser {
            add(&report, "文件权限", .information, "修改需要管理员权限",
                "文件属于其他用户（例如 root）。修复时会弹出系统密码框请求授权。")
        }
    }

    private static func inspectQuarantine(_ url: URL, report: inout InspectionReport) {
        let rootInfo = ExtendedAttributes.quarantineAgent(at: url.path)
        report.quarantinePresent = rootInfo != nil
        report.quarantineAgent = rootInfo?.agent
        report.downloadSources = ExtendedAttributes.downloadSources(at: url.path)

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let tagged = isDir.boolValue
            ? ExtendedAttributes.paths(with: ExtendedAttributes.quarantine, under: url)
            : (report.quarantinePresent ? [url.path] : [])
        report.quarantinedItemCount = tagged.count

        if tagged.isEmpty {
            add(&report, "下载隔离标记", .passed, "未检测到 com.apple.quarantine",
                isDir.boolValue ? "已扫描包内全部文件。" : "")
        } else {
            var detail = "共 \(tagged.count) 个文件带有隔离标记（此标记由浏览器/聊天工具在下载时添加，不等于恶意软件）。"
            if let raw = rootInfo?.raw { detail += "\n根目录标记值：\(raw)" }
            let sample = tagged.prefix(8).map { "  " + $0 }.joined(separator: "\n")
            detail += "\n\n示例：\n" + sample + (tagged.count > 8 ? "\n  …" : "")
            add(&report, "下载隔离标记", .warning,
                "检测到 \(tagged.count) 个文件带隔离标记" + (rootInfo?.agent.map { "（来源：\($0)）" } ?? ""),
                detail)
        }
        if !report.downloadSources.isEmpty {
            add(&report, "下载来源", .information, report.downloadSources.first ?? "",
                "系统记录的下载地址（kMDItemWhereFroms）：\n" + report.downloadSources.joined(separator: "\n")
                + "\n\n请自行判断该网址是否为官方来源。")
        }
    }

    // MARK: APP / bundle

    private static func inspectCode(_ url: URL, report: inout InspectionReport) {
        let sig = CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", url.path], timeout: 120)
        let detail = CommandRunner.run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        let kind = signatureKind(from: detail.output)
        report.signatureKind = kind
        report.signatureValid = kind == .unsigned ? false : sig.succeeded
        report.developerSigned = kind == .developerID

        add(&report, "代码签名完整性", report.signatureValid == true ? .passed : .failed,
            report.signatureValid == true ? "签名校验通过" : (kind == .unsigned ? "应用没有签名" : "签名校验未通过（文件与签名不符）"),
            sig.output.isEmpty ? "codesign 未返回更多信息。" : sig.output)

        let team = detail.output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })
        let identityLevel: CheckLevel = kind == .developerID || kind == .appStore || kind == .apple ? .passed : .warning
        add(&report, "签名类型", identityLevel, kind.title,
            "\(team.map(String.init) ?? "未读取到 TeamIdentifier")\n\n" + detail.output)

        let ent = CommandRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path])
        report.entitlementKeys = entitlementKeys(from: ent.output)
        if !report.entitlementKeys.isEmpty {
            add(&report, "特殊权限（Entitlements）", .information, "声明了 \(report.entitlementKeys.count) 项权限",
                report.entitlementKeys.joined(separator: "\n") + "\n\n重签名会使依赖这些权限的功能失效。")
        }

        if report.kind == .app {
            assessGatekeeper(url, type: "execute", report: &report)
            inspectStapledTicket(url, report: &report)
        }
        inspectRuntime(url, report: &report)
        if let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier {
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            add(&report, "应用信息", .information, "\(identifier) · \(version)", "此项仅用于识别应用，不构成安全证明。")
        }
    }

    private static func inspectRuntime(_ url: URL, report: inout InspectionReport) {
        guard let bundle = Bundle(url: url) else { return }
        if let exe = bundle.executableURL {
            let lipo = CommandRunner.run("/usr/bin/lipo", ["-archs", exe.path])
            if lipo.succeeded {
                report.executableArchs = lipo.output.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            }
        }
        report.rosettaInstalled = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        if let min = bundle.infoDictionary?["LSMinimumSystemVersion"] as? String {
            report.minimumSystemVersion = min
            report.systemTooOld = !systemSatisfies(min)
        }
        if !report.executableArchs.isEmpty {
            let level: CheckLevel = report.architectureUnsupported ? .failed : (report.needsRosetta ? .warning : .passed)
            add(&report, "处理器架构", level, report.executableArchs.joined(separator: " / "),
                "本机：\(report.hostArch)" + (report.needsRosetta ? "\n需要 Rosetta 2，但尚未安装。" : ""))
        }
        if report.systemTooOld, let min = report.minimumSystemVersion {
            add(&report, "系统版本要求", .failed, "需要 macOS \(min) 或更高",
                "当前系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
    }

    static func systemSatisfies(_ minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let v = OperatingSystemVersion(majorVersion: parts.first ?? 0,
                                       minorVersion: parts.count > 1 ? parts[1] : 0,
                                       patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(v)
    }

    static func signatureKind(from output: String) -> SignatureKind {
        if output.contains("not signed at all") { return .unsigned }
        if output.contains("Signature=adhoc") { return .adhoc }
        if output.contains("Authority=Developer ID Application") { return .developerID }
        if output.contains("Authority=Apple Mac OS Application Signing") { return .appStore }
        if output.contains("Authority=Software Signing") { return .apple }
        if output.contains("Authority=") { return .otherCertificate }
        return .unknown
    }

    static func entitlementKeys(from output: String) -> [String] {
        // Lines look like: <key>com.apple.security.hypervisor</key>
        var keys: [String] = []
        var rest = Substring(output)
        while let start = rest.range(of: "<key>"), let end = rest.range(of: "</key>", range: start.upperBound..<rest.endIndex) {
            keys.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return keys
    }

    // MARK: DMG / PKG / other

    private static func inspectDMG(_ url: URL, report: inout InspectionReport) {
        let verify = CommandRunner.run("/usr/bin/hdiutil", ["verify", url.path], timeout: 180)
        report.imageVerified = verify.succeeded
        add(&report, "磁盘映像校验", verify.succeeded ? .passed : .failed,
            verify.succeeded ? "DMG 自身校验通过" : "DMG 校验失败",
            verify.output.isEmpty ? "hdiutil 未返回更多信息。" : verify.output)
        inspectHash(url, report: &report)
        assessGatekeeper(url, type: "open", report: &report)
        inspectStapledTicket(url, report: &report)
    }

    private static func inspectPKG(_ url: URL, report: inout InspectionReport) {
        let signature = CommandRunner.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 60)
        let lower = signature.output.lowercased()
        let signed = signature.succeeded && lower.contains("status: signed") && !lower.contains("not signed")
        report.pkgSigned = signed
        add(&report, "安装包签名", signed ? .passed : .warning,
            signed ? "安装包具有可验证的签名" : "无法确认安装包签名有效",
            signature.output.isEmpty ? "pkgutil 未返回更多信息。" : signature.output)
        inspectHash(url, report: &report)
        assessGatekeeper(url, type: "install", report: &report)
        inspectStapledTicket(url, report: &report)
    }

    private static func inspectOther(_ url: URL, report: inout InspectionReport) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard !isDir.boolValue else { return }
        // Executables (command-line tools) can be signature-checked too.
        if FileManager.default.isExecutableFile(atPath: url.path) {
            let detail = CommandRunner.run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
            let kind = signatureKind(from: detail.output)
            report.signatureKind = kind
            add(&report, "签名类型", kind.isCertificateSigned ? .passed : .information, kind.title, detail.output)
        }
        inspectHash(url, report: &report)
    }

    private static func inspectStapledTicket(_ url: URL, report: inout InspectionReport) {
        let result = CommandRunner.run("/usr/bin/xcrun", ["stapler", "validate", url.path], timeout: 60)
        add(&report, "附加公证票据（可选）", result.succeeded ? .passed : .information,
            result.succeeded ? "检测到可验证的附加公证票据" : "未能验证附加票据（不能据此判定未公证）",
            (result.output.isEmpty ? "stapler 未返回更多信息，可能未安装命令行工具。" : result.output)
            + "\n\n注意：未附加票据的应用也可能通过联网公证验证；本项不是完整公证状态判断。")
    }

    private static func inspectHash(_ url: URL, report: inout InspectionReport) {
        let digest = Checksum.sha256(of: url)
        report.sha256 = digest
        if let actual = digest {
            if let expected = report.expectedSHA256 {
                report.hashMatched = expected == actual
                add(&report, "官方 SHA-256 对比", expected == actual ? .passed : .failed,
                    expected == actual ? "哈希值完全一致" : "哈希不一致，文件可能不完整或被替换",
                    "本地：\(actual)\n输入：\(expected)\n请自行确认输入值确实来自官方发布页面。")
            } else {
                add(&report, "SHA-256", .information, "已计算本地哈希（可选：填写官方值核对）", actual)
            }
        } else {
            add(&report, "SHA-256", .warning, "无法计算文件校验值", "检查文件是否已完全下载、可读取。")
        }
    }

    private static func assessGatekeeper(_ url: URL, type: String, report: inout InspectionReport) {
        var args = ["--assess", "--type", type]
        if type == "open" { args += ["--context", "context:primary-signature"] }
        args += ["--verbose=4", url.path]
        let result = CommandRunner.run("/usr/sbin/spctl", args, timeout: 75)
        report.gatekeeperAccepted = result.succeeded
        add(&report, "Gatekeeper 系统评估", result.succeeded ? .passed : .warning,
            result.succeeded ? "系统安全评估接受" : "未通过系统安全评估",
            result.output.isEmpty ? "spctl 未返回更多信息。" : result.output)
    }

    private static func add(_ report: inout InspectionReport, _ title: String, _ level: CheckLevel,
                            _ summary: String, _ detail: String) {
        report.checks.append(DiagnosticCheck(title: title, level: level, summary: summary, detail: detail))
    }

    private static func finish(_ report: inout InspectionReport) {
        let diagnosis = DiagnosisEngine.diagnose(report)
        report.level = diagnosis.level
        report.summary = diagnosis.title
    }
}
