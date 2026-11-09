import SwiftUI
import AppKit

// MARK: - Shared log row

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(PGRFormat.time(entry.date))
                .font(PGRFont.mono(10))
                .foregroundStyle(PGRTheme.textFaint)
                .frame(width: 58, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(PGRTheme.levelColor(entry.level))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(PGRTheme.levelColor(entry.level).opacity(0.13))
                )
                .frame(width: 40, alignment: .leading)

            Text(entry.message)
                .font(PGRFont.mono(11))
                .foregroundStyle(entry.level == .error
                                 ? PGRTheme.danger.opacity(0.95)
                                 : PGRTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
    }
}

// MARK: - Auto-scrolling log list

struct LogListView: View {
    let entries: [LogEntry]
    var autoScroll: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    ForEach(entries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear {
                if autoScroll, let last = entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: entries.count) { _, _ in
                guard autoScroll, let last = entries.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Collapsible bottom console

struct LogConsoleBar: View {
    @EnvironmentObject private var state: AppState
    @Binding var expanded: Bool

    @State private var hoveringHeader = false

    private var entries: [LogEntry] { state.logEntries }
    private var errorCount: Int { entries.reduce(0) { $0 + ($1.level == .error ? 1 : 0) } }
    private var warnCount: Int { entries.reduce(0) { $0 + ($1.level == .warn ? 1 : 0) } }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            header

            if expanded {
                Rectangle()
                    .fill(Color.black.opacity(0.30))
                    .frame(height: 1)

                LogListView(entries: entries)
                    .frame(height: 176)
                    .background(PGRTheme.cardInset.opacity(0.82))
                    .transition(.opacity)
            }
        }
        .background(
            VStack(spacing: 0) {
                PGRTheme.bgBase.opacity(0.94)
                Color.black.opacity(0.20)
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(expanded ? PGRTheme.accentLight : PGRTheme.textTertiary)

                    Text("运行日志")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(PGRTheme.textSecondary)

                    if entries.isEmpty {
                        Text("暂无日志")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PGRTheme.textFaint)
                    } else {
                        HStack(spacing: 5) {
                            if errorCount > 0 {
                                countBadge("\(errorCount) 错误", color: PGRTheme.danger)
                            }
                            if warnCount > 0 {
                                countBadge("\(warnCount) 警告", color: PGRTheme.warning)
                            }
                            if errorCount == 0 && warnCount == 0 {
                                countBadge("\(entries.count) 条", color: PGRTheme.textTertiary)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    if !expanded, let latest = entries.last {
                        Text(latest.message)
                            .font(PGRFont.mono(10.5))
                            .foregroundStyle(PGRTheme.levelColor(latest.level).opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.035))
                            )
                            .frame(maxWidth: 460, alignment: .trailing)
                    }

                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(PGRTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringHeader = $0 }
            .background(Color.white.opacity(hoveringHeader ? 0.018 : 0))

            if expanded {
                HStack(spacing: 2) {
                    PGRIconButton(systemImage: "trash", help: "清空日志") {
                        state.logger.clear()
                    }
                    PGRIconButton(systemImage: "doc.text.magnifyingglass", help: "打开日志文件") {
                        PGRSystem.reveal(state.logger.logFileURL)
                    }
                    .padding(.trailing, 12)
                }
                .transition(.opacity)
            }
        }
    }

    private func countBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Full logs page

private enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case info
    case warn
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .info: return "信息"
        case .warn: return "警告"
        case .error: return "错误"
        }
    }
}

struct LogsPage: View {
    @EnvironmentObject private var state: AppState

    @State private var filter: LogFilter = .all
    @State private var autoScroll = true
    @State private var copied = false

    private var allEntries: [LogEntry] { state.logEntries }

    private var filtered: [LogEntry] {
        switch filter {
        case .all: return allEntries
        case .info: return allEntries.filter { $0.level == .info }
        case .warn: return allEntries.filter { $0.level == .warn }
        case .error: return allEntries.filter { $0.level == .error }
        }
    }

    private func count(_ filter: LogFilter) -> Int {
        switch filter {
        case .all: return allEntries.count
        case .info: return allEntries.reduce(0) { $0 + ($1.level == .info ? 1 : 0) }
        case .warn: return allEntries.reduce(0) { $0 + ($1.level == .warn ? 1 : 0) }
        case .error: return allEntries.reduce(0) { $0 + ($1.level == .error ? 1 : 0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PGRPageHeader(
                eyebrow: "DIAGNOSTICS",
                title: "日志",
                subtitle: "运行时、下载与游戏进程的实时诊断信息",
                trailing: AnyView(
                    HStack(spacing: 8) {
                        PGRSecondaryButton(title: copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            copyAll()
                        }
                        .disabled(allEntries.isEmpty)
                        PGRSecondaryButton(title: "打开日志文件", systemImage: "doc.text") {
                            PGRSystem.reveal(state.logger.logFileURL)
                        }
                    }
                )
            )
            .padding(.horizontal, 28)
            .padding(.top, 20)

            HStack(spacing: 8) {
                ForEach(LogFilter.allCases) { item in
                    filterChip(item)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Toggle("自动滚动", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                        .tint(PGRTheme.accent)
                }

                PGRSecondaryButton(title: "打开日志目录", systemImage: "folder") {
                    PGRSystem.open(state.logsDir)
                }
                PGRSecondaryButton(title: "清空", systemImage: "trash") {
                    state.logger.clear()
                }
                .disabled(allEntries.isEmpty)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Text("时间")
                        .frame(width: 58, alignment: .leading)
                    Text("级别")
                        .frame(width: 40, alignment: .leading)
                    Text("消息")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(PGRTheme.textFaint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.025))

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                if filtered.isEmpty {
                    PGREmptyState(
                        systemImage: "text.alignleft",
                        title: allEntries.isEmpty ? "暂无日志" : "该级别暂无日志",
                        subtitle: allEntries.isEmpty ? "启动器运行后，这里会实时显示诊断信息。" : "切换筛选条件查看其他日志。")
                        .frame(maxHeight: .infinity)
                } else {
                    LogListView(entries: filtered, autoScroll: autoScroll)
                        .frame(maxHeight: .infinity)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(PGRTheme.cardInset.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func filterChip(_ item: LogFilter) -> some View {
        LogFilterChip(
            title: item.title,
            count: count(item),
            selected: filter == item,
            tint: item == .error ? PGRTheme.danger : (item == .warn ? PGRTheme.warning : PGRTheme.textSecondary)
        ) {
            withAnimation(.easeOut(duration: 0.15)) { filter = item }
        }
    }

    private func copyAll() {
        let text = allEntries.map { PGRFormat.logLine($0) }.joined(separator: "\n")
        PGRSystem.copyToPasteboard(text)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { copied = false }
        }
    }
}


// MARK: - Filter chip

private struct LogFilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? tint : PGRTheme.textFaint)
            }
            .foregroundStyle(selected ? PGRTheme.textPrimary : PGRTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                Capsule().fill(selected
                               ? Color.white.opacity(0.085)
                               : Color.white.opacity(hovering ? 0.075 : 0.03))
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? tint.opacity(0.45) : Color.white.opacity(hovering ? 0.14 : 0.06),
                    lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
