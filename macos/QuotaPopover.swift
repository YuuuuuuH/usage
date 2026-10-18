import AppKit
import SwiftUI

final class QuotaPanelPresentation: ObservableObject {
    @Published var quotaStates = QuotaProvider.allCases.map { QuotaProviderState(provider: $0, snapshot: nil, message: nil) }
    @Published var claudeQuotaConnected = false
    @Published var expandedProvider: QuotaProvider?
    @Published var preferences = TopBarPreferences.load()

    func states(for providers: [QuotaProvider]) -> [QuotaProviderState] {
        providers.compactMap { provider in quotaStates.first { $0.provider == provider } }
    }
}

struct TopBarSettingsView: View {
    @ObservedObject var presentation: QuotaPanelPresentation
    let setVisible: (QuotaProvider, Bool) -> Void
    let move: (IndexSet, Int) -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拖动组件调整顺序，选择要显示的账户额度。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            List {
                ForEach(presentation.preferences.order) { component in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .help("拖动调整顺序")
                        Text(component.title)
                        Spacer()
                        if let provider = component.provider {
                            Toggle("显示 \(provider.title) 额度", isOn: Binding(
                                get: { !presentation.preferences.hiddenProviders.contains(provider) },
                                set: { setVisible(provider, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        } else {
                            Text("始终显示").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)
            .frame(height: 242)
            HStack {
                Text("关闭额度组件后，也会暂停它的额度查询。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认", action: reset).controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 440, height: 340)
    }
}

struct QuotaPopover: View {
    @ObservedObject private var theme = AtlasTheme.shared
    @ObservedObject var presentation: QuotaPanelPresentation
    let providers: [QuotaProvider]
    let refresh: () -> Void
    let connectClaude: () -> Void
    let openAntigravity: () -> Void
    let expand: (QuotaProvider) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text("剩余额度")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                icon("arrow.clockwise", help: "更新额度", action: refresh)
            }
            .frame(height: 20)
            VStack(spacing: 4) {
                ForEach(presentation.states(for: providers), id: \.provider) { state in
                    CompactQuotaRow(state: state, expanded: presentation.expandedProvider == state.provider,
                                    claudeConnected: presentation.claudeQuotaConnected, connectClaude: connectClaude,
                                    openAntigravity: openAntigravity, expand: { expand(state.provider) })
                }
            }
        }
        .padding(12)
        .frame(width: QuotaPanelLayout.width, height: QuotaPanelLayout.height(states: presentation.states(for: providers), expanded: presentation.expandedProvider))
        .foregroundStyle(Color(nsColor: AtlasColor.ink))
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
        .help(help)
    }
}

private struct CompactQuotaRow: View {
    let state: QuotaProviderState
    let expanded: Bool
    let claudeConnected: Bool
    let connectClaude: () -> Void
    let openAntigravity: () -> Void
    let expand: () -> Void

    private var windows: [QuotaWindow] { state.snapshot?.windows ?? [] }
    private var needsClaudeConnection: Bool { state.provider == .claude && !claudeConnected }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.provider.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 2)
                    if needsClaudeConnection {
                        Button("连接", action: connectClaude).buttonStyle(.plain).foregroundStyle(Color(nsColor: AtlasColor.teal))
                    } else {
                        Text(state.compactSummary())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if !windows.isEmpty {
                        Button(action: expand) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(state.provider.title)额度明细")
                        .help("额度明细")
                    }
                }
                .frame(height: 18)
                HStack(spacing: 4) {
                    Text(detail).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 0)
                    if state.provider == .antigravity && state.currentWindows().isEmpty {
                        Button("打开", action: openAntigravity).buttonStyle(.plain)
                            .font(.system(size: 10)).foregroundStyle(Color(nsColor: AtlasColor.teal))
                    }
                }
                .frame(height: 14)
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
            }
            .padding(.horizontal, 10)
            .frame(height: QuotaPanelLayout.rowHeight)
            if expanded && !windows.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(windows) { window in detailRow(window) }
                    }
                }
                .frame(height: QuotaPanelLayout.detailHeight(windowCount: windows.count))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: AtlasColor.ink).opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var detail: String {
        if let value = state.compactDetail() { return value }
        if let message = state.message { return message }
        if needsClaudeConnection { return "通过 Claude Code 连接账户" }
        if state.provider == .claude { return "等待 Claude Code 返回额度" }
        if state.snapshot != nil { return "等待额度更新" }
        return "正在读取额度…"
    }

    private func detailRow(_ window: QuotaWindow) -> some View {
        let valid = state.currentWindows().contains(where: { $0.id == window.id })
        return HStack(spacing: 6) {
            Text(window.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(valid ? "\(Int(window.remainingPercent.rounded(.down)))%" : "—")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
            Text(window.resetsAt > Date() ? quotaDuration(window.resetsAt.timeIntervalSinceNow) + "后重置" : "待更新")
                .font(.system(size: 9))
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)
        }
        .font(.system(size: 10))
        .frame(height: 26)
        .help("\(window.title)\n重置：\(window.resetsAt.formatted(date: .abbreviated, time: .shortened))")
    }
}
