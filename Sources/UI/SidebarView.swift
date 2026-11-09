import SwiftUI

// MARK: - Pages

enum SidebarPage: String, CaseIterable, Identifiable {
    case game
    case keymap
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .game: return "游戏"
        case .keymap: return "键位映射"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .game: return "gamecontroller.fill"
        case .keymap: return "keyboard.fill"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape.fill"
        }
    }

    var shortcut: String {
        switch self {
        case .game: return "1"
        case .keymap: return "2"
        case .logs: return "3"
        case .settings: return "4"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var page: SidebarPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 46)
                .padding(.horizontal, 20)

            gameCard
                .padding(.horizontal, 16)
                .padding(.top, 22)

            navSection
                .padding(.horizontal, 12)
                .padding(.top, 24)

            Spacer(minLength: 12)

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(width: 238)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                PGRTheme.sidebar.opacity(0.86)
                LinearGradient(
                    colors: [Color.white.opacity(0.022), .clear, Color.black.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.11), Color.white.opacity(0.035), Color.white.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 11) {
            PGRAppIcon(size: 38)
            VStack(alignment: .leading, spacing: 2.5) {
                Text("PGR Launcher")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text("战双帕弥什 · macOS 启动器")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(PGRTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Game identity card

    private var gameCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("战双帕弥什")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Spacer(minLength: 0)
                Text(state.gameVersionText)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .lineLimit(1)
            }
            Text("PUNISHING : GRAY RAVEN")
                .font(.system(size: 8, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(PGRTheme.textTertiary.opacity(0.9))

            HStack(spacing: 7) {
                StatusBadge(status: state.status)
                Spacer(minLength: 0)
                MetaPill(systemImage: "cpu", text: state.config.backend == .dxmt ? "DXMT" : "D3DMetal")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.038))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            // Crimson accent line on the game card
            Capsule()
                .fill(PGRTheme.accentGradient)
                .frame(width: 42, height: 2)
                .offset(y: -1)
                .opacity(0.9)
        }
    }

    // MARK: Navigation

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("导航")
                .font(PGRFont.eyebrow)
                .tracking(1.8)
                .foregroundStyle(PGRTheme.textFaint)
                .padding(.leading, 10)
                .padding(.bottom, 6)

            ForEach(SidebarPage.allCases) { item in
                SidebarNavRow(
                    page: item,
                    selected: page == item,
                    errorCount: item == .logs ? errorCount : 0
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        page = item
                    }
                }
            }
        }
    }

    private var errorCount: Int {
        state.logEntries.reduce(0) { $0 + ($1.level == .error ? 1 : 0) }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            PGRDivider()
                .padding(.bottom, 1)

            HStack(spacing: 7) {
                Circle()
                    .fill(state.runtimeInstalled ? PGRTheme.success : PGRTheme.warning)
                    .frame(width: 5.5, height: 5.5)
                Text("Wine 运行时")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PGRTheme.textTertiary)
                Spacer(minLength: 0)
                Text(state.runtimeInstalled ? "已就绪" : "未安装")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(state.runtimeInstalled ? PGRTheme.success : PGRTheme.warning)
            }

            HStack(spacing: 6) {
                Text("v\(AppState.appVersion)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(PGRTheme.textFaint)
                Spacer(minLength: 0)
                Text("Apple Silicon · Retina")
                    .font(.system(size: 9.5))
                    .foregroundStyle(PGRTheme.textFaint.opacity(0.85))
            }
        }
    }
}

// MARK: - Navigation row

private struct SidebarNavRow: View {
    let page: SidebarPage
    let selected: Bool
    let errorCount: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selected ? PGRTheme.accentLight : PGRTheme.textTertiary)
                    .frame(width: 18)

                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? PGRTheme.textPrimary : PGRTheme.textSecondary)

                Spacer(minLength: 0)

                if errorCount > 0 {
                    Text("\(errorCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(PGRTheme.danger)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(PGRTheme.danger.opacity(0.15)))
                } else {
                    Text("⌘\(page.shortcut)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(hovering ? PGRTheme.textTertiary : PGRTheme.textFaint.opacity(0.65))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8.5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected
                          ? Color.white.opacity(0.075)
                          : Color.white.opacity(hovering ? 0.045 : 0))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(PGRTheme.accentGradient)
                    .frame(width: 2.5, height: 16)
                    .opacity(selected ? 1 : 0)
                    .offset(x: -1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut(KeyEquivalent(Character(page.shortcut)), modifiers: .command)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
