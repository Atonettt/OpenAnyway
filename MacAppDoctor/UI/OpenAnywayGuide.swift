import SwiftUI

/// Walks the user through macOS's own per-app approval:
/// System Settings → Privacy & Security → "Open Anyway".
/// The app never clicks that button itself; the user approves it with their password / Touch ID.
struct OpenAnywayGuide: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private var appName: String {
        (state.report?.name ?? "该应用").replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 26)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("手动放行步骤").font(.title3.weight(.semibold))
                    Text("只放行“\(appName)”这一个应用，不会关闭 Gatekeeper。")
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

            stepRow(1, title: "先尝试打开一次",
                    detail: "macOS 会弹出“已损坏”或“无法打开”的提示，点 **取消**（千万不要点“移到废纸篓”）。这一步会让系统设置里出现放行按钮。",
                    button: "尝试打开", symbol: "play") {
                state.openItem()
            }
            stepRow(2, title: "打开“隐私与安全性”",
                    detail: "向下滚动到 **安全性** 一栏，会看到“已阻止‘\(appName)’以保护 Mac”。",
                    button: "打开系统设置", symbol: "gearshape") {
                state.openSecuritySettings()
            }
            stepRow(3, title: "点“仍要打开”",
                    detail: "输入开机密码或使用触控 ID 确认。按钮只在被拦截后约一小时内出现，没看到就回到第 1 步再试一次。",
                    button: nil, symbol: nil, action: nil)
            stepRow(4, title: "再次打开应用",
                    detail: "弹出确认框时点 **打开**。之后就可以像普通应用一样直接双击打开了。",
                    button: "再次打开", symbol: "arrow.clockwise") {
                state.openItem()
            }

            Label("如果打开后虚拟化、网络、系统扩展等功能出错，说明重签名去掉了这些特殊权限，请从官网重新下载安装。",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
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
