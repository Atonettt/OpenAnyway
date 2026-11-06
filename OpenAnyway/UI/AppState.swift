import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var report: InspectionReport? {
        didSet { resetSelection() }
    }
    @Published var isInspecting = false
    @Published var isRepairing = false
    @Published var selectedFixes: Set<FixAction> = []
    @Published var backupBeforeResign = true
    @Published var showRepairConfirmation = false
    @Published var lastRepairSucceeded = false
    /// Result of the last repair, shown inline on the page.
    @Published var repairMessage: String?
    @Published var repairMessageLevel: CheckLevel = .information
    @Published var showOpenAnywayGuide = false
    @Published var guideIntro: String?
    @Published var autoApproveRunning = false
    @Published var autoApproveStatus: String?
    @Published var autoApproveResult: CheckLevel?

    private var inspectionID = UUID()

    var currentURL: URL? { report.map { URL(fileURLWithPath: $0.filePath) } }
    var diagnosis: Diagnosis? { report.map(DiagnosisEngine.diagnose) }

    var selectedSuggestions: [FixSuggestion] {
        (diagnosis?.suggestions ?? []).filter { selectedFixes.contains($0.action) }
    }
    var selectedRisk: FixRisk { selectedSuggestions.map(\.risk).max() ?? .low }
    var hasRecommendedFix: Bool { diagnosis?.suggestions.contains(where: \.recommended) ?? false }
    var isBusy: Bool { isInspecting || isRepairing || autoApproveRunning }

    var canRepair: Bool { !isBusy && !selectedFixes.isEmpty }

    private func resetSelection() {
        selectedFixes = Set((diagnosis?.suggestions ?? []).filter(\.recommended).map(\.action))
    }

    func inspect(_ selected: URL) {
        guard !isRepairing, !autoApproveRunning else { return }
        let token = UUID()
        inspectionID = token
        isInspecting = true
        report = nil
        lastRepairSucceeded = false
        repairMessage = nil
        autoApproveStatus = nil
        autoApproveResult = nil
        runInspection(url: selected.standardizedFileURL, token: token)
    }

    func recheck() {
        guard let url = currentURL, !isBusy else { return }
        let token = UUID()
        inspectionID = token
        isInspecting = true
        runInspection(url: url, token: token)
    }

    func reset() {
        guard !isBusy else { return }
        report = nil
        repairMessage = nil
        autoApproveStatus = nil
        autoApproveResult = nil
        lastRepairSucceeded = false
    }

    private func runInspection(url: URL, token: UUID) {
        Task.detached(priority: .userInitiated) {
            let result = FileInspector.inspect(url, expectedSHA: "")
            await MainActor.run {
                guard token == self.inspectionID else { return }
                self.isInspecting = false
                self.report = result
            }
        }
    }

    func repair() {
        guard canRepair, let url = currentURL else { return }
        isRepairing = true
        repairMessage = nil
        let actions = selectedFixes
        let backup = backupBeforeResign
        Task.detached(priority: .userInitiated) {
            let outcome = RepairService.perform(actions, on: url, expectedSHA: "", backupBeforeResign: backup)
            await MainActor.run {
                self.isRepairing = false
                if let latest = outcome.latestReport { self.report = latest }
                self.lastRepairSucceeded = outcome.succeeded
                self.repairMessageLevel = outcome.succeeded ? (outcome.needsOpenAnyway ? .warning : .passed) : .failed
                self.repairMessage = outcome.succeeded
                    ? (outcome.needsOpenAnyway ? L("修复完成，还需要在系统设置里放行一次。", "Fixed. It still needs to be approved once in System Settings.") : L("修复完成，可以打开了。", "Fixed. You can open it now."))
                    : outcome.message
            }
        }
    }

    /// Clicks through "Open Anyway" automatically; the user only authenticates.
    func autoApprove() {
        guard let url = currentURL, !autoApproveRunning else { return }
        autoApproveRunning = true
        autoApproveResult = nil
        autoApproveStatus = L("准备中…", "Getting ready…")
        let automator = OpenAnywayAutomator(appURL: url) { [weak self] text in
            self?.autoApproveStatus = text
        }
        Task {
            let outcome = await automator.run()
            autoApproveRunning = false
            switch outcome {
            case .launched:
                autoApproveResult = .passed
                autoApproveStatus = L("已放行并打开，以后可以直接双击打开。", "Approved and opened. From now on you can just double-click it.")
            case .needsAccessibility:
                autoApproveResult = .warning
                autoApproveStatus = L("需要“辅助功能”权限：在 系统设置 → 隐私与安全性 → 辅助功能 中允许 OpenAnyway。如果开关已经打开，请先用“−”删掉 OpenAnyway 再重新添加，然后再点一次。", "Accessibility permission needed: allow OpenAnyway in System Settings → Privacy & Security → Accessibility. If it's already on, remove OpenAnyway with “−”, add it again, then click once more.")
            case .buttonNotFound:
                autoApproveResult = .warning
                autoApproveStatus = L("没有找到“仍要打开”按钮。它可能已经放行了，试试直接打开；或者在“高级选项”里按手动步骤操作。", "Couldn't find the “Open Anyway” button. The app may already be approved — try opening it, or follow the manual steps under Advanced.")
            case .notApproved:
                autoApproveResult = .warning
                autoApproveStatus = L("没有完成放行（可能取消了密码或触控 ID）。可以再点一次。", "Approval wasn't completed (the password or Touch ID prompt may have been cancelled). Click again to retry.")
            case .foundButton:
                autoApproveResult = .information
                autoApproveStatus = L("测试模式：已找到按钮，未点击。", "Test mode: button found, not clicked.")
            }
        }
    }

    func presentOpenAnywayGuide() {
        guideIntro = nil
        showOpenAnywayGuide = true
    }

    func openItem() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openSecuritySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?General"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    func showInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openBackupFolder() {
        try? FileManager.default.createDirectory(at: RepairService.backupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(RepairService.backupFolder)
    }
}
