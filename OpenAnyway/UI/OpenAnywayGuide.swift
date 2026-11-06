import SwiftUI

/// Walks the user through macOS's own per-app approval:
/// System Settings → Privacy & Security → "Open Anyway".
/// The app never clicks that button itself; the user approves it with their password / Touch ID.
struct OpenAnywayGuide: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private var appName: String {
        (state.report?.name ?? L("该应用", "this app")).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 26)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("手动放行步骤", "Manual Open Anyway steps")).font(.title3.weight(.semibold))
                    Text(L("只放行“\(appName)”这一个应用，不会关闭 Gatekeeper。", "Approves only “\(appName)”. Gatekeeper stays on."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let intro = state.guideIntro {
                Text(intro)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }

            stepRow(1, title: L("先尝试打开一次", "Try to open it once"),
                    detail: L("macOS 会弹出“已损坏”或“无法打开”的提示，点 **取消**（千万不要点“移到废纸篓”）。这一步会让系统设置里出现放行按钮。", "macOS shows a “damaged” or “can't be opened” alert. Click **Cancel** (never “Move to Trash”). This makes the approval button appear in System Settings."),
                    button: L("尝试打开", "Try to Open"), symbol: "play") {
                state.openItem()
            }
            stepRow(2, title: L("打开“隐私与安全性”", "Open Privacy & Security"),
                    detail: L("向下滚动到 **安全性** 一栏，会看到“已阻止‘\(appName)’以保护 Mac”。", "Scroll down to **Security**. You'll see ““\(appName)” was blocked to protect your Mac”."),
                    button: L("打开系统设置", "Open System Settings"), symbol: "gearshape") {
                state.openSecuritySettings()
            }
            stepRow(3, title: L("点“仍要打开”", "Click “Open Anyway”"),
                    detail: L("输入开机密码或使用触控 ID 确认。按钮只在被拦截后约一小时内出现，没看到就回到第 1 步再试一次。", "Confirm with your password or Touch ID. The button only appears for about an hour after a block — if it's missing, repeat step 1."),
                    button: nil, symbol: nil, action: nil)
            stepRow(4, title: L("再次打开应用", "Open the app again"),
                    detail: L("弹出确认框时点 **打开**。之后就可以像普通应用一样直接双击打开了。", "Click **Open** in the confirmation. From then on it opens with a normal double-click."),
                    button: L("再次打开", "Open Again"), symbol: "arrow.clockwise") {
                state.openItem()
            }

            Label(L("如果打开后虚拟化、网络、系统扩展等功能出错，说明重签名去掉了这些特殊权限，请从官网重新下载安装。", "If virtualization, networking or system extensions fail after opening, re-signing removed those special permissions. Reinstall from the official website."),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func stepRow(_ number: Int, title: String, detail: String,
                         button: String?, symbol: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(step >= number ? Color.green : Color.blue, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(.init(detail)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button, let symbol, let action {
                Button {
                    action()
                    step = max(step, number)
                } label: {
                    Label(button, systemImage: symbol)
                }
            }
        }
    }
}
