import AppKit
import ApplicationServices

/// Thin helpers around the Accessibility (AX) API.
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func app(bundleID: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let v = value(element, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Visible text of an element (title, description or value).
    static func text(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { string(element, $0) }
            .joined(separator: " ")
    }

    static func descendants(_ root: AXUIElement, limit: Int = 6000) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        while !queue.isEmpty && result.count < limit {
            let next = queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: children(next))
        }
        return result
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Scrolls every scroll area to the bottom so lazily built rows get created.
    static func scrollToBottom(_ root: AXUIElement) {
        for element in descendants(root) where role(element) == kAXScrollBarRole {
            if string(element, kAXOrientationAttribute) == kAXVerticalOrientationValue {
                AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, 1.0 as CFNumber)
            }
        }
    }
}

/// Automates the clicks of System Settings → Privacy & Security → "Open Anyway".
/// The user still authenticates (Touch ID / password) themselves; that step cannot be automated.
final class OpenAnywayAutomator {
    enum Outcome {
        case launched
        case needsAccessibility
        case buttonNotFound
        case notApproved
        /// Dry run only: the button was found but not pressed.
        case foundButton
    }

    /// When true, stops right before pressing "Open Anyway" (used for testing).
    var dryRun = false

    private static let settingsID = "com.apple.systempreferences"
    private static let uiAgentID = "com.apple.coreservices.uiagent"
    private static let openAnywayTitles = ["仍要打开", "Open Anyway"]
    private static let dismissTitles = ["取消", "Cancel", "完成", "Done", "好", "OK"]
    private static let confirmOpenTitles = ["打开", "Open", "仍要打开", "Open Anyway"]
    private static let neverPress = ["移到废纸篓", "Move to Trash", "移到垃圾桶"]

    let appURL: URL
    let names: [String]
    let bundleID: String?
    let progress: @MainActor (String) -> Void

    init(appURL: URL, progress: @escaping @MainActor (String) -> Void) {
        self.appURL = appURL
        let bundle = Bundle(url: appURL)
        var names = [appURL.deletingPathExtension().lastPathComponent]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = bundle?.object(forInfoDictionaryKey: key) as? String, !n.isEmpty { names.append(n) }
        }
        self.names = Array(Set(names))
        self.bundleID = bundle?.bundleIdentifier
        self.progress = progress
    }

    func run() async -> Outcome {
        guard AX.isTrusted(prompt: true) else { return .needsAccessibility }

        if await isStablyRunning() { return .launched }

        await say(L("① 尝试打开一次，让 macOS 记录这次拦截…", "① Opening the app once so macOS records the block…"))
        await open()
        // Dismiss the "damaged / cannot be opened" alert with its safe button.
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isStablyRunning() { return .launched }
            if pressAgentButton(Self.dismissTitles) { break }
        }

        await say(L("② 打开“隐私与安全性”，寻找“仍要打开”按钮…", "② Opening Privacy & Security and looking for “Open Anyway”…"))
        await MainActor.run { openPrivacySecurity() }
        var button: AXUIElement?
        for attempt in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let settings = AX.app(bundleID: Self.settingsID) else { continue }
            if attempt % 4 == 3 { AX.scrollToBottom(settings) }
            if let found = openAnywayButton(in: settings) { button = found; break }
        }
        guard let button else { return .buttonNotFound }
        if dryRun { return .foundButton }

        await say(L("③ 已点击“仍要打开”，请用触控 ID 或开机密码确认…", "③ Clicked “Open Anyway”. Confirm with Touch ID or your password…"))
        AX.press(button)

        // Wait for the user to authenticate. Approval removes the button or launches the app.
        for tick in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isStablyRunning() { return .launched }
            pressAgentButton(Self.confirmOpenTitles)
            let stillBlocked = AX.app(bundleID: Self.settingsID).flatMap { openAnywayButton(in: $0) } != nil
            if !stillBlocked && tick > 2 {
                await say(L("④ 已放行，正在打开应用…", "④ Approved. Opening the app…"))
                await open()
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if await isStablyRunning() { return .launched }
                    pressAgentButton(Self.confirmOpenTitles)
                }
                return await isStablyRunning() ? .launched : .notApproved
            }
        }
        return .notApproved
    }

    // MARK: Helpers

    /// A blocked or broken app can appear for a split second before macOS kills it,
    /// so only count it as opened if it is still alive a few seconds later.
    private func isStablyRunning() async -> Bool {
        guard isRunning else { return false }
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !isRunning { return false }
        }
        return true
    }

    private var isRunning: Bool {
        guard let bundleID else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    private func say(_ text: String) async { await progress(text) }

    @MainActor private func openPrivacySecurity() {
        for string in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                       "x-apple.systempreferences:com.apple.preference.security?General"] {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func open() async {
        await MainActor.run {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        }
    }

    private func mentionsApp(_ text: String) -> Bool {
        names.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// The "Open Anyway" button whose row mentions this app (never another blocked app).
    private func openAnywayButton(in settings: AXUIElement) -> AXUIElement? {
        for element in AX.descendants(settings) where AX.role(element) == kAXButtonRole {
            guard Self.openAnywayTitles.contains(AX.text(element).trimmingCharacters(in: .whitespaces)) else { continue }
            var ancestor: AXUIElement? = AX.parent(element)
            for _ in 0..<4 {
                guard let current = ancestor else { break }
                let texts = AX.descendants(current, limit: 200).map(AX.text).joined(separator: " ")
                if mentionsApp(texts) { return element }
                ancestor = AX.parent(current)
            }
        }
        return nil
    }

    /// Presses a button in a CoreServicesUIAgent alert that is about this app.
    /// Destructive buttons (move to trash) are never pressed.
    @discardableResult
    private func pressAgentButton(_ titles: [String]) -> Bool {
        guard let agent = AX.app(bundleID: Self.uiAgentID) else { return false }
        for window in AX.children(agent) {
            let all = AX.descendants(window, limit: 300)
            guard mentionsApp(all.map(AX.text).joined(separator: " ")) else { continue }
            for element in all where AX.role(element) == kAXButtonRole {
                let title = AX.text(element).trimmingCharacters(in: .whitespaces)
                if Self.neverPress.contains(title) { continue }
                if titles.contains(title) { return AX.press(element) }
            }
        }
        return false
    }
}
