import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CheckLevel {
    var accentColor: Color {
        switch self {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .information: return .blue
        }
    }
}

struct PanelCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color.primary.opacity(0.055)))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct StatusPill: View {
    let level: CheckLevel
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level.symbol)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(level.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(level.accentColor.opacity(0.09), in: Capsule())
    }
}

struct CheckRow: View {
    let check: DiagnosticCheck
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: check.level.symbol)
                        .foregroundStyle(check.level.accentColor)
                        .font(.system(size: 16))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).font(.subheadline.weight(.semibold))
                        Text(check.summary).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text(check.level.title)
                        .font(.caption).foregroundStyle(check.level.accentColor)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(check.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7),
                                in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.vertical, 8)
    }
}

enum FileChooser {
    @MainActor
    static func select(onSelected: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L("选择打不开的应用", "Choose the app that won't open")
        panel.message = L("也可以选择安装包（DMG、PKG）、插件或命令行工具。", "You can also choose installers (DMG, PKG), plug-ins or command-line tools.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onSelected(url)
        }
    }
}
