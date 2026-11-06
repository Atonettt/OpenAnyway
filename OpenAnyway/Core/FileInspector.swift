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
            summary: L("检查完成", "Check complete"), level: .information
        )

        guard FileManager.default.fileExists(atPath: url.path) else {
            report.exists = false
            add(&report, L("文件访问", "File access"), .failed, L("文件不存在或无法访问", "File not found or not accessible"), url.path)
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
            add(&report, L("文件位置", "Location"), .warning, L("位于只读卷（通常是已挂载的 DMG）", "On a read-only volume (usually a mounted DMG)"),
                L("只读位置无法修改。修复时会先把它复制到“应用程序”文件夹。", "Read-only locations can't be changed. Fixing will first copy it to the Applications folder."))
        } else if !report.writable || report.ownedByOtherUser {
            add(&report, L("文件权限", "Permissions"), .information, L("修改需要管理员权限", "Changes need administrator rights"),
                L("文件属于其他用户（例如 root）。修复时会弹出系统密码框请求授权。", "The file belongs to another user (e.g. root). macOS will ask for your password when fixing."))
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
            add(&report, L("下载隔离标记", "Quarantine flags"), .passed, L("未检测到 com.apple.quarantine", "No com.apple.quarantine found"),
                isDir.boolValue ? L("已扫描包内全部文件。", "Every file inside the bundle was checked.") : "")
        } else {
            var detail = L("共 \(tagged.count) 个文件带有隔离标记（此标记由浏览器/聊天工具在下载时添加，不等于恶意软件）。", "\(tagged.count) files carry a quarantine flag (added by browsers or chat apps on download; it doesn't mean malware).")
            if let raw = rootInfo?.raw { detail += L("\n根目录标记值：\(raw)", "\nFlag on the item itself: \(raw)") }
            let sample = tagged.prefix(8).map { "  " + $0 }.joined(separator: "\n")
            detail += L("\n\n示例：\n", "\n\nExamples:\n") + sample + (tagged.count > 8 ? "\n  …" : "")
            add(&report, L("下载隔离标记", "Quarantine flags"), .warning,
                L("检测到 \(tagged.count) 个文件带隔离标记", "\(tagged.count) files have a quarantine flag") + (rootInfo?.agent.map { L("（来源：\($0)）", " (from \($0))") } ?? ""),
                detail)
        }
        if !report.downloadSources.isEmpty {
            add(&report, L("下载来源", "Downloaded from"), .information, report.downloadSources.first ?? "",
                L("系统记录的下载地址（kMDItemWhereFroms）：\n", "Download address recorded by macOS (kMDItemWhereFroms):\n") + report.downloadSources.joined(separator: "\n")
                + L("\n\n请自行判断该网址是否为官方来源。", "\n\nCheck for yourself whether this is an official source."))
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

        add(&report, L("代码签名完整性", "Code signature"), report.signatureValid == true ? .passed : .failed,
            report.signatureValid == true ? L("签名校验通过", "Signature is valid") : (kind == .unsigned ? L("应用没有签名", "The app isn't signed") : L("签名校验未通过（文件与签名不符）", "Signature invalid (files don't match the signature)")),
            sig.output.isEmpty ? L("codesign 未返回更多信息。", "codesign returned no details.") : sig.output)

        let team = detail.output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })
        let identityLevel: CheckLevel = kind == .developerID || kind == .appStore || kind == .apple ? .passed : .warning
        add(&report, L("签名类型", "Signature type"), identityLevel, kind.title,
            "\(team.map(String.init) ?? L("未读取到 TeamIdentifier", "No TeamIdentifier"))\n\n" + detail.output)

        let ent = CommandRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path])
        report.entitlementKeys = entitlementKeys(from: ent.output)
        if !report.entitlementKeys.isEmpty {
            add(&report, L("特殊权限（Entitlements）", "Entitlements"), .information, L("声明了 \(report.entitlementKeys.count) 项权限", "\(report.entitlementKeys.count) entitlements declared"),
                report.entitlementKeys.joined(separator: "\n") + L("\n\n重签名会使依赖这些权限的功能失效。", "\n\nRe-signing disables features that depend on these entitlements."))
        }

        if report.kind == .app {
            assessGatekeeper(url, type: "execute", report: &report)
            inspectStapledTicket(url, report: &report)
        }
        inspectRuntime(url, report: &report)
        if let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier {
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            add(&report, L("应用信息", "App info"), .information, "\(identifier) · \(version)", L("此项仅用于识别应用，不构成安全证明。", "For identification only; not proof of safety."))
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
            add(&report, L("处理器架构", "Architecture"), level, report.executableArchs.joined(separator: " / "),
                L("本机：\(report.hostArch)", "This Mac: \(report.hostArch)") + (report.needsRosetta ? L("\n需要 Rosetta 2，但尚未安装。", "\nRequires Rosetta 2, which isn't installed.") : ""))
        }
        if report.systemTooOld, let min = report.minimumSystemVersion {
            add(&report, L("系统版本要求", "macOS version"), .failed, L("需要 macOS \(min) 或更高", "Requires macOS \(min) or later"),
                L("当前系统：\(ProcessInfo.processInfo.operatingSystemVersionString)", "This Mac: \(ProcessInfo.processInfo.operatingSystemVersionString)"))
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
        add(&report, L("磁盘映像校验", "Disk image check"), verify.succeeded ? .passed : .failed,
            verify.succeeded ? L("DMG 自身校验通过", "DMG verified") : L("DMG 校验失败", "DMG verification failed"),
            verify.output.isEmpty ? L("hdiutil 未返回更多信息。", "hdiutil returned no details.") : verify.output)
        inspectHash(url, report: &report)
        assessGatekeeper(url, type: "open", report: &report)
        inspectStapledTicket(url, report: &report)
    }

    private static func inspectPKG(_ url: URL, report: inout InspectionReport) {
        let signature = CommandRunner.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 60)
        let lower = signature.output.lowercased()
        let signed = signature.succeeded && lower.contains("status: signed") && !lower.contains("not signed")
        report.pkgSigned = signed
        add(&report, L("安装包签名", "Installer signature"), signed ? .passed : .warning,
            signed ? L("安装包具有可验证的签名", "Installer has a valid signature") : L("无法确认安装包签名有效", "Installer signature could not be verified"),
            signature.output.isEmpty ? L("pkgutil 未返回更多信息。", "pkgutil returned no details.") : signature.output)
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
            add(&report, L("签名类型", "Signature type"), kind.isCertificateSigned ? .passed : .information, kind.title, detail.output)
        }
        inspectHash(url, report: &report)
    }

    private static func inspectStapledTicket(_ url: URL, report: inout InspectionReport) {
        let result = CommandRunner.run("/usr/bin/xcrun", ["stapler", "validate", url.path], timeout: 60)
        add(&report, L("附加公证票据（可选）", "Stapled notarization ticket (optional)"), result.succeeded ? .passed : .information,
            result.succeeded ? L("检测到可验证的附加公证票据", "Valid stapled ticket found") : L("未能验证附加票据（不能据此判定未公证）", "No stapled ticket (doesn't mean it isn't notarized)"),
            (result.output.isEmpty ? L("stapler 未返回更多信息，可能未安装命令行工具。", "stapler returned no details; Command Line Tools may not be installed.") : result.output)
            + L("\n\n注意：未附加票据的应用也可能通过联网公证验证；本项不是完整公证状态判断。", "\n\nNote: apps without a stapled ticket can still pass online notarization checks; this is not a full notarization check."))
    }

    private static func inspectHash(_ url: URL, report: inout InspectionReport) {
        let digest = Checksum.sha256(of: url)
        report.sha256 = digest
        if let actual = digest {
            if let expected = report.expectedSHA256 {
                report.hashMatched = expected == actual
                add(&report, L("官方 SHA-256 对比", "Official SHA-256"), expected == actual ? .passed : .failed,
                    expected == actual ? L("哈希值完全一致", "Hashes match") : L("哈希不一致，文件可能不完整或被替换", "Hashes differ — the file may be incomplete or replaced"),
                    L("本地：\(actual)\n输入：\(expected)\n请自行确认输入值确实来自官方发布页面。", "Local: \(actual)\nExpected: \(expected)\nMake sure the expected value comes from the official release page."))
            } else {
                add(&report, "SHA-256", .information, L("已计算本地哈希（可选：填写官方值核对）", "Local hash calculated"), actual)
            }
        } else {
            add(&report, "SHA-256", .warning, L("无法计算文件校验值", "Could not calculate the checksum"), L("检查文件是否已完全下载、可读取。", "Check that the file finished downloading and is readable."))
        }
    }

    private static func assessGatekeeper(_ url: URL, type: String, report: inout InspectionReport) {
        var args = ["--assess", "--type", type]
        if type == "open" { args += ["--context", "context:primary-signature"] }
        args += ["--verbose=4", url.path]
        let result = CommandRunner.run("/usr/sbin/spctl", args, timeout: 75)
        report.gatekeeperAccepted = result.succeeded
        add(&report, L("Gatekeeper 系统评估", "Gatekeeper"), result.succeeded ? .passed : .warning,
            result.succeeded ? L("系统安全评估接受", "Accepted by Gatekeeper") : L("未通过系统安全评估", "Rejected by Gatekeeper"),
            result.output.isEmpty ? L("spctl 未返回更多信息。", "spctl returned no details.") : result.output)
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
