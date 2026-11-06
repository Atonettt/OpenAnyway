import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole app is this one page: drop an app → see what's wrong → one button.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDropTargeted = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if state.isInspecting {
                    checking
                } else if let report = state.report, let diagnosis = state.diagnosis {
                    ScrollView { result(report, diagnosis).padding(24) }
                } else {
                    dropZone.padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $state.showOpenAnywayGuide) {
            OpenAnywayGuide().environmentObject(state)
        }
        .confirmationDialog(L("确定要修复吗？", "Fix this app?"), isPresented: $state.showRepairConfirmation,
                            titleVisibility: .visible) {
            Button(L("修复", "Fix"), role: state.selectedRisk == .high ? .destructive : nil) { state.repair() }
            Button(L("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(confirmationText)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenAnyway").font(.headline)
                Text(L("让打不开的应用重新打开", "Open apps that macOS won't open")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.report != nil && !state.isBusy {
                Button { state.reset() } label: { Label(L("换一个", "Choose Another"), systemImage: "arrow.uturn.left") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Empty / checking

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.blue)
            Text(L("把打不开的应用拖到这里", "Drop an app that won't open here")).font(.title3.weight(.semibold))
            Text(L("比如提示“已损坏，无法打开”或“无法验证开发者”的应用", "For example, apps that are “damaged and can't be opened” or from an “unidentified developer”"))
                .font(.callout).foregroundStyle(.secondary)
            Button {
                FileChooser.select { state.inspect($0) }
            } label: {
                Text(L("选择应用…", "Choose App…")).padding(.horizontal, 8)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.blue.opacity(0.08) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Color.blue.opacity(isDropTargeted ? 0.6 : 0.22),
                          style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
    }

    private var checking: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("正在检查…", "Checking…")).foregroundStyle(.secondary)
        }
    }

    // MARK: Result

    private func result(_ report: InspectionReport, _ diagnosis: Diagnosis) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: report.filePath))
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.name.replacingOccurrences(of: ".app", with: ""))
                        .font(.title3.weight(.semibold)).lineLimit(1)
                    Label(diagnosis.title, systemImage: diagnosis.level.symbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(diagnosis.level.accentColor)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(diagnosis.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(diagnosis.advice, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions(report, diagnosis)

            if let message = state.repairMessage {
                statusLine(message, level: state.repairMessageLevel)
            }
            if let status = state.autoApproveStatus {
                statusLine(status, level: state.autoApproveResult ?? .information, busy: state.autoApproveRunning)
            }

            advanced(report, diagnosis)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actions(_ report: InspectionReport, _ diagnosis: Diagnosis) -> some View {
        HStack(spacing: 10) {
            if state.hasRecommendedFix {
                Button {
                    state.showRepairConfirmation = true
                } label: {
                    busyLabel(state.isRepairing, busy: L("正在修复…", "Fixing…"), idle: L("一键修复", "Fix"), symbol: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canRepair)
            } else if diagnosis.suggestOpenAnyway {
                approveButton(prominent: true)
            } else if report.kind == .app {
                Button { state.openItem() } label: { Label(L("打开应用", "Open App"), systemImage: "play.fill").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent)
            }

            if state.hasRecommendedFix && diagnosis.suggestOpenAnyway {
                approveButton(prominent: false)
            }
            if report.kind == .app && (state.hasRecommendedFix || diagnosis.suggestOpenAnyway) {
                Button(L("打开应用", "Open App")) { state.openItem() }.disabled(state.isBusy)
            }
        }
        .controlSize(.large)
    }

    private func approveButton(prominent: Bool) -> some View {
        Button {
            state.autoApprove()
        } label: {
            busyLabel(state.autoApproveRunning, busy: L("正在放行…", "Approving…"), idle: L("一键放行", "Open Anyway"), symbol: "lock.open")
        }
        .modifier(ProminentIf(prominent))
        .disabled(state.isBusy)
        .help(L("自动点击系统设置里的“仍要打开”，你只需要用触控 ID 或密码确认。", "Clicks “Open Anyway” in System Settings for you. You only confirm with Touch ID or your password."))
    }

    @ViewBuilder
    private func busyLabel(_ busy: Bool, busy busyText: String, idle: String, symbol: String) -> some View {
        if busy {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busyText) }.padding(.horizontal, 6)
        } else {
            Label(idle, systemImage: symbol).padding(.horizontal, 6)
        }
    }

    private func statusLine(_ text: String, level: CheckLevel, busy: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if busy { ProgressView().controlSize(.small) } else {
                Image(systemName: level.symbol).foregroundStyle(level.accentColor)
            }
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Advanced

    private func advanced(_ report: InspectionReport, _ diagnosis: Diagnosis) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                if !diagnosis.suggestions.isEmpty {
                    Text(L("修复时执行", "Fixes to apply")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(diagnosis.suggestions) { fixRow($0) }
                    if state.selectedFixes.contains(.adhocResign) {
                        Toggle(L("重新签名前先备份原应用", "Back up the original app before re-signing"), isOn: $state.backupBeforeResign)
                            .toggleStyle(.checkbox).font(.callout)
                    }
                }
                if diagnosis.suggestOpenAnyway {
                    Button(L("手动放行步骤…", "Manual Open Anyway steps…")) { state.presentOpenAnywayGuide() }.buttonStyle(.link)
                }
                Text(L("详细信息", "Details")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.checks) { item in
                        if item.id != report.checks.first?.id { Divider() }
                        CheckRow(check: item)
                    }
                }
                HStack(spacing: 14) {
                    Button(L("在 Finder 中显示", "Show in Finder")) { state.showInFinder() }
                    Button(L("重新检查", "Check Again")) { state.recheck() }.disabled(state.isBusy)
                    Button(L("备份文件夹", "Backup Folder")) { AppState.openBackupFolder() }
                }
                .buttonStyle(.link).font(.callout)
            }
            .padding(.top, 10)
        } label: {
            Text(L("高级选项", "Advanced")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func fixRow(_ suggestion: FixSuggestion) -> some View {
        let binding = Binding<Bool>(
            get: { state.selectedFixes.contains(suggestion.action) },
            set: { on in
                if on { state.selectedFixes.insert(suggestion.action) } else { state.selectedFixes.remove(suggestion.action) }
            })
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.action.title).font(.callout.weight(.medium))
                    Text(suggestion.risk.title).font(.caption2).foregroundStyle(suggestion.risk.level.accentColor)
                }
                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Helpers

    private var confirmationText: String {
        let lines = state.selectedSuggestions.sorted { $0.action.order < $1.action.order }
            .map { "• " + $0.action.title }.joined(separator: "\n")
        var text = lines + L("\n\n只会修改这一个应用。需要时会请你输入密码。", "\n\nOnly this app is changed. You'll be asked for your password if needed.")
        if state.selectedFixes.contains(.adhocResign), let kind = state.report?.signatureKind, kind.isCertificateSigned {
            text += L("\n\n⚠️ 这是厂商正式签名的应用。重新签名后还需要在系统设置里放行，部分特殊功能可能失效。", "\n\n⚠️ This app is signed by its developer. After re-signing it still has to be approved in System Settings, and some special features may stop working.")
        }
        return text
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard error == nil else { return }
            var url: URL?
            if let received = item as? URL { url = received }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            if let url { Task { @MainActor in state.inspect(url) } }
        }
        return true
    }
}

private struct ProminentIf: ViewModifier {
    let prominent: Bool
    init(_ prominent: Bool) { self.prominent = prominent }
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}
