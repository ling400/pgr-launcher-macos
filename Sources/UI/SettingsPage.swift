import SwiftUI
import AppKit

// MARK: - Settings page

struct SettingsPage: View {
    @EnvironmentObject private var state: AppState

    @State private var showReinstallConfirm = false
    @State private var showRestartHint = false

    private var config: AppConfig { state.config }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PGRPageHeader(
                    eyebrow: "CONFIGURATION",
                    title: "设置",
                    subtitle: "所有修改即时生效并保存",
                    trailing: AnyView(
                        PGRSecondaryButton(title: "打开数据目录", systemImage: "internaldrive") {
                            PGRSystem.open(state.appSupportDir)
                        }
                    )
                )
                .padding(.bottom, 2)

                renderingSection
                runtimeSection
                gameSection
                networkSection
                aboutSection

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("需要重新启动游戏", isPresented: $showRestartHint) {
            Button("好", role: .cancel) {}
        } message: {
            Text("渲染后端的更改会在下一次启动游戏时生效。")
        }
    }

    // MARK: Rendering & performance

    private var renderingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            PGRSectionHeader(
                title: "渲染与性能",
                subtitle: "决定游戏在 Wine 中的图形转译方式与画面表现",
                systemImage: "cpu.fill")

            HStack(spacing: 10) {
                ForEach(RenderBackend.allCases) { backend in
                    PGRChoiceChip(
                        title: backend.displayName,
                        subtitle: backend.subtitle,
                        selected: config.backend == backend
                    ) {
                        if config.backend != backend {
                            state.setBackend(backend)
                            showRestartHint = true
                        }
                    }
                }
            }

            PGRDivider()

            toggleRow(
                title: "高分辨率渲染（Retina）",
                subtitle: "以 HiDPI 渲染游戏画面，文字与 UI 更清晰；若出现缩放异常可关闭。",
                isOn: Binding(get: { config.retina }, set: { state.setRetina($0) }))

            PGRDivider()

            PGRSettingRow(
                title: "帧率上限",
                subtitle: "通过 DXMT 限制最大帧率，降低发热与功耗；「无限制」使用显示器刷新率。"
            ) {
                HStack(spacing: 5) {
                    ForEach([0, 30, 60, 120, 144, 165, 240], id: \.self) { fps in
                        fpsChip(fps)
                    }
                }
            }

            PGRDivider()

            toggleRow(
                title: "Metal HUD",
                subtitle: "在游戏画面叠加 Metal 性能信息层，仅用于调试。",
                isOn: Binding(get: { config.metalHud }, set: { state.setMetalHud($0) }))

            PGRDivider()

            toggleRow(
                title: "左 Command 键映射为 Ctrl",
                subtitle: "在 Wine 容器内把左侧 ⌘ 键注册为 Ctrl，便于使用以 Ctrl 为主的快捷键。",
                isOn: Binding(get: { config.leftCommandIsCtrl }, set: { state.setLeftCommandIsCtrl($0) }))
        }
        .pgrCard(padding: 22)
    }

    private func fpsChip(_ fps: Int) -> some View {
        FPSOptionChip(fps: fps, selected: config.maxFPS == fps) {
            state.setMaxFPS(fps)
        }
    }

    // MARK: Runtime

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PGRSectionHeader(
                title: "Wine 运行时",
                subtitle: "Wine 11（CrossOver 11）+ DXMT v0.80，安装在应用支持目录中",
                systemImage: "shippingbox.fill")

            runtimeRow(
                label: "运行时版本",
                value: state.wineVersion,
                badge: state.runtimeInstalled ? "已安装" : "未安装",
                badgeColor: state.runtimeInstalled ? PGRTheme.success : PGRTheme.warning)

            PGRDivider()

            PGRSettingRow(title: "运行时路径", subtitle: "Wine 可执行文件所在的目录") {
                HStack(spacing: 8) {
                    Text(PGRSystem.truncatePath(state.runtime.wineRoot.path, maxLength: 56))
                        .font(PGRFont.mono(10.5))
                        .foregroundStyle(PGRTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PGRIconButton(systemImage: "folder", help: "在访达中显示") {
                        PGRSystem.reveal(state.runtime.wineRoot)
                    }
                }
            }

            PGRDivider()

            HStack(spacing: 10) {
                PGRSecondaryButton(title: "打开日志目录", systemImage: "folder") {
                    PGRSystem.open(state.logsDir)
                }
                Spacer(minLength: 0)
                if state.runtimeInstalled {
                    PGRSecondaryButton(title: "重新安装运行时", systemImage: "arrow.triangle.2.circlepath") {
                        showReinstallConfirm = true
                    }
                    .disabled(state.isBusy)
                }
            }
        }
        .pgrCard(padding: 22)
        .alert("重新安装 Wine 运行时？", isPresented: $showReinstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("重新安装", role: .destructive) {
                Task { await state.reinstallRuntime() }
            }
        } message: {
            Text("将删除现有 Wine 容器与运行时，并重新下载约 480 MB 的运行时；游戏安装目录不受影响。")
        }
    }

    private func runtimeRow(label: String, value: String, badge: String, badgeColor: Color) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text("首次启动后会初始化 Wine 容器，可能需要几十秒")
                    .font(.system(size: 11))
                    .foregroundStyle(PGRTheme.textTertiary)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(PGRFont.mono(11.5))
                .foregroundStyle(PGRTheme.textSecondary)
                .lineLimit(1)
            Text(badge)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(badgeColor.opacity(0.13)))
                .overlay(Capsule().strokeBorder(badgeColor.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: Game & installer

    private var gameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PGRSectionHeader(
                title: "游戏渠道与下载",
                subtitle: "渠道、安装目录与官方 CDN 配置",
                systemImage: "gamecontroller.fill")

            VStack(alignment: .leading, spacing: 8) {
                Text("游戏服务器 / 渠道")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text("决定从哪个官方 CDN 下载游戏资源；切换渠道后请执行「检查更新」或重新下载。")
                    .font(.system(size: 11))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: 8)],
                    alignment: .leading, spacing: 8) {
                    ForEach(state.availableChannels) { channel in
                        PGRChoiceChip(
                            title: channel.displayName,
                            subtitle: channel.subtitle,
                            selected: state.config.channelID == channel.id
                        ) {
                            state.setChannel(channel.id)
                        }
                    }
                }
            }

            PGRDivider()

            PGRSettingRow(
                title: "游戏安装目录",
                subtitle: "游戏资源会写入该目录，Wine 容器通过共享目录映射访问它。"
            ) {
                HStack(spacing: 8) {
                    Text(PGRSystem.truncatePath(state.config.gameDir, maxLength: 46))
                        .font(PGRFont.mono(10.5))
                        .foregroundStyle(PGRTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PGRSecondaryButton(title: "选择…", systemImage: "folder") {
                        chooseGameDir()
                    }
                    PGRIconButton(systemImage: "arrow.up.forward.app", help: "打开目录") {
                        state.openGameDir()
                    }
                }
            }

            PGRDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("自定义 CDN 配置地址（可选）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PGRTheme.textPrimary)
                    Spacer(minLength: 0)
                    PGRSecondaryButton(title: "恢复默认", systemImage: "arrow.counterclockwise") {
                        state.setInstallerURL(AppConfig.defaultInstallerURL)
                    }
                }
                Text("一般不用填写：留空时使用所选渠道的官方配置地址（index.json）。仅在使用自建 / 镜像清单时填写完整的 index.json URL。")
                    .font(.system(size: 11))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                DebouncedTextField(
                    placeholder: "留空则使用渠道默认 CDN（https://…/index.json）",
                    value: config.installerURL,
                    monospaced: true,
                    onCommit: { state.setInstallerURL($0) })
            }
        }
        .pgrCard(padding: 22)
    }

    // MARK: Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PGRSectionHeader(
                title: "网络",
                subtitle: "下载运行时与 Wine 内进程都会使用该代理",
                systemImage: "network")

            DebouncedTextField(
                placeholder: "http://127.0.0.1:7890（留空则直连）",
                value: config.proxy,
                monospaced: true,
                onCommit: { state.setProxy($0) })

            Text("支持 HTTP / HTTPS 代理，例如 Clash 默认的 http://127.0.0.1:7890。修改后对新启动的游戏进程生效。")
                .font(.system(size: 10.5))
                .foregroundStyle(PGRTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pgrCard(padding: 22)
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PGRSectionHeader(
                title: "关于",
                subtitle: nil,
                systemImage: "info.circle.fill")

            HStack(alignment: .top, spacing: 14) {
                PGRAppIcon(size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PGR Launcher v\(AppState.appVersion)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PGRTheme.textPrimary)
                    Text("非官方粉丝制作的《战双帕弥什》macOS 启动器 · SwiftUI + Wine + DXMT")
                        .font(.system(size: 11))
                        .foregroundStyle(PGRTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            PGRDivider()

            HStack(spacing: 10) {
                PGRSecondaryButton(title: "打开数据目录", systemImage: "internaldrive") {
                    PGRSystem.open(state.appSupportDir)
                }
                PGRSecondaryButton(title: "打开日志文件", systemImage: "doc.text") {
                    PGRSystem.reveal(state.logger.logFileURL)
                }
                Spacer(minLength: 0)
                Text("数据目录：\(PGRSystem.truncatePath(state.appSupportDir.path, maxLength: 50))")
                    .font(PGRFont.mono(10))
                    .foregroundStyle(PGRTheme.textFaint)
                    .lineLimit(1)
            }
        }
        .pgrCard(padding: 22)
    }

    // MARK: Helpers

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        PGRSettingRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(PGRTheme.accent)
        }
    }

    private func chooseGameDir() {
        if let url = PGRSystem.chooseDirectory(startingAt: state.gameDirURL) {
            state.chooseGameDir(url)
        }
    }
}

// MARK: - Debounced text field (instant-save settings)

struct DebouncedTextField: View {
    let placeholder: String
    let value: String
    var monospaced: Bool = false
    let onCommit: (String) -> Void

    @State private var text: String
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(placeholder: String, value: String, monospaced: Bool = false, onCommit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.value = value
        self.monospaced = monospaced
        self.onCommit = onCommit
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? PGRFont.mono(11.5) : .system(size: 12))
            .foregroundStyle(PGRTheme.textPrimary)
            .focused($focused)
            .onSubmit { commitIfNeeded() }
            .onChange(of: text) { _, _ in scheduleCommit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfNeeded() }
            }
            .onChange(of: value) { _, newValue in
                if !focused, text != newValue { text = newValue }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.30))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? PGRTheme.accent.opacity(0.55) : Color.white.opacity(0.09),
                        lineWidth: 1)
            )
    }

    private func scheduleCommit() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitIfNeeded() }
        }
    }

    private func commitIfNeeded() {
        saveTask?.cancel()
        guard text != value else { return }
        onCommit(text)
    }
}


// MARK: - FPS option chip

private struct FPSOptionChip: View {
    let fps: Int
    let selected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(fps == 0 ? "无限制" : "\(fps)")
                .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(selected ? .white : PGRTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected
                              ? PGRTheme.accent.opacity(0.75)
                              : Color.white.opacity(hovering && isEnabled ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            selected ? Color.white.opacity(0.22) : Color.white.opacity(hovering ? 0.16 : 0.07),
                            lineWidth: 1)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
