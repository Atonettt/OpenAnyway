import Foundation

@main
struct CoreSmokeTests {
    static func report(_ kind: ItemKind, _ configure: (inout InspectionReport) -> Void) -> InspectionReport {
        var r = InspectionReport(inspectedAt: Date(), filePath: "/tmp/x", kind: kind, checks: [],
            quarantinePresent: false, signatureValid: nil, developerSigned: nil, gatekeeperAccepted: nil,
            imageVerified: nil, pkgSigned: nil, writable: true, summary: "", level: .information)
        configure(&r)
        return r
    }

    static func check(_ condition: Bool, _ name: String) {
        if !condition { print("FAIL: \(name)"); exit(1) }
        print("ok  \(name)")
    }

    static func main() {
        UserDefaults.standard.set("zh", forKey: "OpenAnywayLanguage")
        let official = String(repeating: "a", count: 64)
        check(Checksum.normalize(official.uppercased()) == official, "checksum normalize")
        check(Checksum.normalize("incorrect") == nil, "checksum reject")

        check(ItemKind(url: URL(fileURLWithPath: "/a/X.app")) == .app, "kind app")
        check(ItemKind(url: URL(fileURLWithPath: "/a/X.vst3")) == .bundle, "kind bundle")
        check(ItemKind(url: URL(fileURLWithPath: "/a/tool")) == .other, "kind other")
        check(FileInspector.signatureKind(from: "Signature=adhoc") == .adhoc, "sig adhoc")
        check(FileInspector.signatureKind(from: "Authority=Developer ID Application: X") == .developerID, "sig devid")
        check(FileInspector.signatureKind(from: "x: code object is not signed at all") == .unsigned, "sig unsigned")
        check(FileInspector.entitlementKeys(from: "<dict><key>a.b</key><true/><key>c</key></dict>") == ["a.b", "c"], "entitlements")

        // Unsigned app downloaded from the web: the classic "已损坏" case.
        let unsigned = DiagnosisEngine.diagnose(report(.app) {
            $0.quarantinePresent = true; $0.quarantinedItemCount = 120
            $0.signatureKind = .adhoc; $0.signatureValid = false; $0.gatekeeperAccepted = false
        })
        let unsignedActions = Set(unsigned.suggestions.filter(\.recommended).map(\.action))
        check(unsignedActions == [.clearQuarantine, .adhocResign], "unsigned app → clear + resign")

        // Signed but not notarized: only clearing quarantine is needed.
        let notarized = DiagnosisEngine.diagnose(report(.app) {
            $0.quarantinePresent = true; $0.quarantinedItemCount = 1
            $0.signatureKind = .developerID; $0.signatureValid = true; $0.gatekeeperAccepted = false
        })
        check(notarized.suggestions.map(\.action) == [.clearQuarantine], "signed app → clear only")
        check(notarized.suggestOpenAnyway, "signed app → open anyway offered")

        // Developer-signed app with broken signature and entitlements (e.g. VMware Fusion).
        let broken = DiagnosisEngine.diagnose(report(.app) {
            $0.quarantinePresent = true; $0.quarantinedItemCount = 3
            $0.signatureKind = .developerID; $0.signatureValid = false; $0.gatekeeperAccepted = false
            $0.entitlementKeys = ["com.apple.security.hypervisor"]
        })
        check(broken.level == .failed, "broken dev sig → failed")
        check(broken.suggestions.first { $0.action == .adhocResign }?.recommended == false, "entitlements → resign not preselected")
        check(broken.advice.first?.contains("重新下载") == true, "broken dev sig → redownload advice")
        check(broken.suggestions.first { $0.action == .adhocResign }?.reason.contains("仍要打开") == true, "dev-signed resign → Open Anyway warning")
        let brokenNoEnt = DiagnosisEngine.diagnose(report(.app) {
            $0.quarantinedItemCount = 1; $0.signatureKind = .developerID; $0.signatureValid = false
        })
        check(brokenNoEnt.suggestions.first { $0.action == .adhocResign }?.recommended == false, "dev-signed resign never preselected")
        let resigned = DiagnosisEngine.diagnose(report(.app) {
            $0.signatureKind = .adhoc; $0.signatureValid = true; $0.gatekeeperAccepted = false
        })
        check(resigned.title != "未发现拦截原因" && resigned.level == .warning, "re-signed app → no false all-clear")
        check(resigned.suggestOpenAnyway, "re-signed app → Open Anyway guide offered")
        check(broken.suggestOpenAnyway, "broken dev sig → Open Anyway guide offered")

        // App inside a mounted DMG.
        let mounted = DiagnosisEngine.diagnose(report(.app) {
            $0.onReadOnlyVolume = true; $0.quarantinedItemCount = 1
            $0.signatureKind = .developerID; $0.signatureValid = true; $0.gatekeeperAccepted = false
        })
        check(mounted.suggestions.first?.action == .copyToApplications, "read-only → copy first")

        // Intel-only app on Apple Silicon without Rosetta / PowerPC app.
        let ppc = DiagnosisEngine.diagnose(report(.app) { $0.executableArchs = ["ppc"]; $0.hostArch = "arm64" })
        check(ppc.suggestions.isEmpty && ppc.level == .failed, "unsupported arch → no fix")

        // DMG with mismatching hash must not be "fixed".
        let badDMG = DiagnosisEngine.diagnose(report(.dmg) { $0.quarantinePresent = true; $0.imageVerified = true; $0.hashMatched = false })
        check(badDMG.suggestions.isEmpty, "bad hash dmg → no fix")
        let goodDMG = DiagnosisEngine.diagnose(report(.dmg) { $0.quarantinePresent = true; $0.quarantinedItemCount = 1; $0.imageVerified = true; $0.hashMatched = true })
        check(goodDMG.suggestions.first?.risk == .low, "verified dmg → low risk")

        check(FixAction.clearQuarantine.command(for: "/a/it's.app") == "xattr -dr com.apple.quarantine '/a/it'\\''s.app'", "command quoting")
        // English UI
        UserDefaults.standard.set("en", forKey: "OpenAnywayLanguage")
        check(DiagnosisEngine.diagnose(report(.other) { _ in }).title == "No problems found", "English title")
        check(FixAction.clearQuarantine.title.hasPrefix("Remove quarantine"), "English fix title")
        check(notarized.title == "被 macOS 拦截了", "Chinese title kept from earlier run")
        UserDefaults.standard.removeObject(forKey: "OpenAnywayLanguage")
        print("PASS")
    }
}
