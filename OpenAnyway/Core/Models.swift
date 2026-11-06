import Foundation

enum ItemKind: String, Codable, CaseIterable {
    case app, bundle, dmg, pkg, other

    static let bundleExtensions: Set<String> = [
        "bundle", "plugin", "component", "vst", "vst3", "aaxplugin", "framework",
        "prefpane", "qlgenerator", "saver", "appex", "mdimporter", "xpc"
    ]

    /// Every existing file or folder is accepted; unknown types fall back to `.other`.
    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "app": self = .app
        case "dmg": self = .dmg
        case "pkg", "mpkg": self = .pkg
        default: self = ItemKind.bundleExtensions.contains(ext) ? .bundle : .other
        }
    }

    var title: String {
        switch self {
        case .app: return L("应用程序 APP", "Application")
        case .bundle: return L("插件 / 扩展包", "Plug-in / bundle")
        case .dmg: return L("磁盘映像 DMG", "Disk image (DMG)")
        case .pkg: return L("安装程序 PKG", "Installer (PKG)")
        case .other: return L("其他文件 / 命令行工具", "Other file / CLI tool")
        }
    }

    var symbol: String {
        switch self {
        case .app: return "app.badge.checkmark"
        case .bundle: return "puzzlepiece.extension"
        case .dmg: return "externaldrive"
        case .pkg: return "shippingbox"
        case .other: return "doc.badge.gearshape"
        }
    }

    /// Kinds whose code signature can be meaningfully checked with codesign.
    var hasCodeSignature: Bool { self == .app || self == .bundle }
}

enum CheckLevel: String, Codable {
    case passed, warning, failed, information

    var title: String {
        switch self {
        case .passed: return L("通过", "Passed")
        case .warning: return L("注意", "Warning")
        case .failed: return L("未通过", "Failed")
        case .information: return L("信息", "Info")
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .information: return "info.circle.fill"
        }
    }
}

enum SignatureKind: String, Codable {
    case unsigned, adhoc, developerID, appStore, apple, otherCertificate, unknown

    var title: String {
        switch self {
        case .unsigned: return L("未签名", "Unsigned")
        case .adhoc: return L("临时签名（ad-hoc）", "Ad-hoc signed")
        case .developerID: return L("Developer ID 开发者签名", "Developer ID signed")
        case .appStore: return L("Mac App Store 签名", "Mac App Store signed")
        case .apple: return L("Apple 系统签名", "Apple signed")
        case .otherCertificate: return L("其他证书签名", "Signed (other certificate)")
        case .unknown: return L("无法识别", "Unknown")
        }
    }

    /// Signed by a real certificate (as opposed to unsigned / ad-hoc).
    var isCertificateSigned: Bool {
        self == .developerID || self == .appStore || self == .apple || self == .otherCertificate
    }
}

struct DiagnosticCheck: Identifiable, Codable {
    var id = UUID()
    let title: String
    let level: CheckLevel
    let summary: String
    let detail: String
}

struct InspectionReport: Identifiable, Codable {
    var id = UUID()
    let inspectedAt: Date
    let filePath: String
    let kind: ItemKind
    var checks: [DiagnosticCheck]
    var sha256: String?
    var expectedSHA256: String?
    var hashMatched: Bool?
    var quarantinePresent: Bool
    var signatureValid: Bool?
    var developerSigned: Bool?
    var gatekeeperAccepted: Bool?
    var imageVerified: Bool?
    var pkgSigned: Bool?
    var writable: Bool
    var summary: String
    var level: CheckLevel

    // Extended facts used by the diagnosis engine.
    var exists = true
    var signatureKind: SignatureKind?
    var entitlementKeys: [String] = []
    /// Number of files inside the item (including the root) that carry com.apple.quarantine.
    var quarantinedItemCount = 0
    var quarantineAgent: String?
    var downloadSources: [String] = []
    var onReadOnlyVolume = false
    var executableArchs: [String] = []
    var hostArch = InspectionReport.currentArch
    var rosettaInstalled = true
    var minimumSystemVersion: String?
    var systemTooOld = false
    var ownedByOtherUser = false

    var name: String { URL(fileURLWithPath: filePath).lastPathComponent }

    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// True when the binary cannot run on this Mac at all (not a Gatekeeper problem).
    var architectureUnsupported: Bool {
        guard !executableArchs.isEmpty else { return false }
        if executableArchs.contains(where: { $0.hasPrefix(hostArch) }) { return false }
        if hostArch == "arm64" && executableArchs.contains("x86_64") { return false }
        return true
    }

    var needsRosetta: Bool {
        hostArch == "arm64" && !executableArchs.contains(where: { $0.hasPrefix("arm64") })
            && executableArchs.contains("x86_64") && !rosettaInstalled
    }
}

// MARK: - Diagnosis

enum FixRisk: Int, Codable, Comparable {
    case low = 0, medium, high

    static func < (lhs: FixRisk, rhs: FixRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .low: return L("低风险", "Low risk")
        case .medium: return L("中风险", "Medium risk")
        case .high: return L("高风险", "High risk")
        }
    }

    var level: CheckLevel {
        switch self {
        case .low: return .passed
        case .medium: return .warning
        case .high: return .failed
        }
    }
}

enum FixAction: String, Codable, CaseIterable, Identifiable {
    case copyToApplications
    case clearQuarantine
    case clearAllAttributes
    case adhocResign

    var id: String { rawValue }

    /// Execution order when several actions are selected.
    var order: Int {
        switch self {
        case .copyToApplications: return 0
        case .clearQuarantine: return 1
        case .clearAllAttributes: return 2
        case .adhocResign: return 3
        }
    }

    var title: String {
        switch self {
        case .copyToApplications: return L("复制到“应用程序”文件夹", "Copy to the Applications folder")
        case .clearQuarantine: return L("移除下载隔离标记（含内部所有文件）", "Remove quarantine flags (all files inside)")
        case .clearAllAttributes: return L("清除全部扩展属性", "Clear all extended attributes")
        case .adhocResign: return L("本地重新签名（ad-hoc）", "Re-sign locally (ad-hoc)")
        }
    }

    var symbol: String {
        switch self {
        case .copyToApplications: return "square.and.arrow.down.on.square"
        case .clearQuarantine: return "tag.slash"
        case .clearAllAttributes: return "eraser"
        case .adhocResign: return "signature"
        }
    }

    func command(for path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .copyToApplications: return "ditto \(quoted) /Applications/…"
        case .clearQuarantine: return "xattr -dr com.apple.quarantine \(quoted)"
        case .clearAllAttributes: return "xattr -cr \(quoted)"
        case .adhocResign: return "xattr -cr \(quoted) && codesign --force --deep --sign - \(quoted)"
        }
    }
}

struct FixSuggestion: Identifiable, Codable {
    var id: String { action.rawValue }
    let action: FixAction
    let risk: FixRisk
    let reason: String
    let recommended: Bool
}

struct Diagnosis: Codable {
    let title: String
    let explanation: String
    let level: CheckLevel
    let suggestions: [FixSuggestion]
    /// Advice that cannot be automated (re-download, install Rosetta, etc.).
    let advice: [String]
    /// Whether "Privacy & Security → Open Anyway" is a sensible alternative.
    let suggestOpenAnyway: Bool
}

struct RepairOutcome {
    let succeeded: Bool
    let message: String
    let finalURL: URL
    let latestReport: InspectionReport?
    /// The app will still be blocked on launch and must be approved in Privacy & Security.
    var needsOpenAnyway = false
}
