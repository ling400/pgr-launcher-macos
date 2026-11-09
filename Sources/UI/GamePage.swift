import SwiftUI
import AppKit

// MARK: - Game page

struct GamePage: View {
    @EnvironmentObject private var state: AppState
    @State private var showDownloadConfirm = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                PGRPageHeader(
                    eyebrow: "PUNISHING : GRAY RAVEN",
                    title: "游戏",
                    subtitle: "下载、更新并启动《战双帕弥什》",
                    trailing: AnyView(StatusBadge(status: state.status))
                )
                .padding(.bottom, 2)

                HeroCard(onRequestDownload: requestDownload)

                if let message = failureMessage {
                    ErrorCard(message: message, onRequestDownload: requestDownload)
                }

                if !state.runtimeInstalled && !state.status.isBusy && state.status != .checking {
                    RuntimeOnboardingCard()
                } else if state.runtimeInstalled && state.installation == nil && !state.status.isBusy {
                    InstallGameCard(onRequestDownload: requestDownload)
                } else if state.status == .ready || state.status == .running {
                    ReadyTipsCard()
                }

                infoStrip

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("下载《战双帕弥什》？", isPresented: $showDownloadConfirm) {
            Button("取消", role: .cancel) {}
            Button("开始下载") {
                Task { await state.downloadAndInstallGame() }
            }
        } message: {
            Text(downloadConfirmMessage)
        }
    }

    private func requestDownload() {
        showDownloadConfirm = true
    }

    private var downloadConfirmMessage: String {
        var lines = [
            "将从官方 CDN 直接下载完整游戏资源：约 68 GB、85,263 个文件。",
            "逐文件 MD5 校验，支持断点续传；下载耗时取决于网络，可随时中断后继续。"
        ]
        if let free = PGRSystem.availableDiskSpace(at: state.gameDirURL) {
            lines.append("当前磁盘可用空间：\(PGRFormat.bytes(free))。")
            if free < 75 * 1024 * 1024 * 1024 {
                lines.append("⚠️ 可用空间可能不足，建议至少预留 75 GB。")
            }
        } else {
            lines.append("无法读取磁盘空间，请确认安装目录所在磁盘容量充足。")
        }
        lines.append("安装目录：\(state.config.gameDir)")
        return lines.joined(separator: "\n")
    }

    private var failureMessage: String? {
        if case .failed(let message) = state.status { return message }
        return nil
    }

    private var infoStrip: some View {
        HStack(spacing: 12) {
            MetricCard(
                systemImage: "opticaldisc.fill",
                label: "游戏版本",
                value: state.gameVersionText,
                tint: PGRTheme.cyan,
                caption: state.installation?.rootDir.path ?? state.config.gameDir)
            MetricCard(
                systemImage: "cup.and.saucer.fill",
                label: "Wine 运行时",
                value: state.wineVersion,
                tint: PGRTheme.success,
                caption: state.runtimeInstalled ? PGRSystem.truncatePath(state.runtime.wineRoot.path) : "尚未安装")
            MetricCard(
                systemImage: "sparkles.rectangle.stack.fill",
                label: "渲染后端",
                value: state.config.backend == .dxmt ? "DXMT" : "D3DMetal",
                tint: PGRTheme.accentLight,
                caption: "Retina \(state.config.retina ? "开启" : "关闭") · 帧率上限 \(state.config.maxFPS == 0 ? "无限制" : "\(state.config.maxFPS) FPS")")
        }
    }
}

// MARK: - Hero card

struct HeroCard: View {
    @EnvironmentObject private var state: AppState
    let onRequestDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(statusEyebrow)
                        .font(PGRFont.eyebrow)
                        .tracking(2.4)
                        .foregroundStyle(PGRTheme.accentLight.opacity(0.9))

                    Text(statusTitle)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(PGRTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(PGRTheme.textSecondary)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)

                    HStack(spacing: 7) {
                        StatusBadge(status: state.status)
                        MetaPill(systemImage: "tag.fill", text: "版本 \(state.gameVersionText)")
                        MetaPill(systemImage: "cup.and.saucer.fill", text: state.wineVersion)
                        MetaPill(systemImage: "cpu.fill", text: state.config.backend == .dxmt ? "DXMT" : "D3DMetal")
                        MetaPill(systemImage: "globe.asia.australia.fill", text: state.currentChannel.displayName)
                    }
                }

                Spacer(minLength: 8)

                GameEmblemView(size: 148)
                    .frame(width: 160, height: 160)
            }

            if let progress = state.progress {
                ProgressDetailView(progress: progress)
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 13)

            actionRow
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground())
        .clipShape(RoundedRectangle(cornerRadius: PGRTheme.corner, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 14)
        .animation(.easeInOut(duration: 0.25), value: state.status)
        .animation(.easeInOut(duration: 0.2), value: state.progress)
    }

    // MARK: Status copy

    private var statusEyebrow: String {
        switch state.status {
        case .ready, .running: return "MISSION READY"
        case .failed: return "SYSTEM ALERT"
        case .needsRuntime, .preparingRuntime: return "RUNTIME SETUP"
        case .needsGame, .downloading, .installing, .updating: return "INSTALLATION"
        default: return "SYSTEM CHECK"
        }
    }

    private var statusTitle: String {
        switch state.status {
        case .checking: return "正在检查环境"
        case .needsRuntime: return "准备 Wine 运行环境"
        case .preparingRuntime: return "正在准备运行环境"
        case .needsGame: return "下载《战双帕弥什》"
        case .downloading: return "正在下载游戏资源"
        case .installing: return "正在校验本地文件"
        case .updating: return "正在检查更新"
        case .ready: return "准备就绪"
        case .launching: return "正在启动游戏"
        case .running: return "游戏运行中"
        case .failed: return "遇到问题"
        }
    }

    private var description: String {
        switch state.status {
        case .checking:
            return "正在检测 Wine 运行时与游戏安装状态，请稍候…"
        case .needsRuntime:
            return "本机尚未安装 Wine 运行时。先准备运行环境，随后即可下载并启动 Windows 版《战双帕弥什》。"
        case .preparingRuntime:
            return "正在下载并解压 Wine 与 DXMT 渲染层，请保持网络连接，进度会实时显示在下方。"
        case .needsGame:
            return "Wine 运行环境已就绪。游戏将通过官方 CDN 直接下载（类似 Yaagl），逐文件 MD5 校验、支持断点续传，完整资源约 68 GB。"
        case .downloading:
            return "正在从官方 CDN 并发下载游戏文件，支持断点续传；请保持网络连接，进度与速度见下方。"
        case .installing:
            return "正在逐文件校验已下载资源（MD5）并完成安装收尾工作。"
        case .updating:
            return "正在对比官方 CDN 文件清单，只下载有变更的文件，完成后即可启动。"
        case .ready:
            return "一切就绪。启动后请勿关闭启动器——键位映射与 Wine 进程管理依赖它。可用「检查更新」同步官方最新版本，首次启动可能需要较长时间。"
        case .launching:
            return "正在通过 Wine 启动游戏进程，窗口出现前请稍候…"
        case .running:
            return "游戏正在运行。键位映射仅在此状态下生效；退出游戏后启动器会自动回到就绪状态。"
        case .failed(let message):
            return "操作未完成：\(message)"
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            primaryButton

            PGRSecondaryButton(title: "打开安装目录", systemImage: "folder") {
                state.openGameDir()
            }
            PGRSecondaryButton(title: "打开容器目录", systemImage: "shippingbox") {
                state.openBottleDir()
            }
            PGRSecondaryButton(title: "重新扫描", systemImage: "arrow.clockwise") {
                state.rescanInstallation()
            }
            .disabled(state.isBusy)

            if state.installation != nil {
                PGRSecondaryButton(title: "检查更新", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await state.updateGame() }
                }
                .disabled(state.isBusy || state.status == .running)
            }

            Spacer(minLength: 0)

            if state.isGameRunning {
                HStack(spacing: 6) {
                    Circle().fill(PGRTheme.success)
                        .frame(width: 5.5, height: 5.5)
                    Text("PID 运行中 · 键位映射\(state.config.keyMappingEnabled ? "已启用" : "未启用")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state.status {
        case .checking:
            PGRPrimaryButton(title: "正在检查环境…", systemImage: "hourglass", loading: true) {}
                .disabled(true)
        case .needsRuntime:
            PGRPrimaryButton(title: "准备 Wine 环境", systemImage: "shippingbox.fill") {
                Task { await state.installRuntime() }
            }
        case .preparingRuntime:
            PGRPrimaryButton(title: "正在准备运行环境…", loading: true) {}
                .disabled(true)
        case .needsGame:
            PGRPrimaryButton(title: "下载游戏", systemImage: "arrow.down.circle.fill") {
                onRequestDownload()
            }
        case .downloading:
            PGRPrimaryButton(title: "正在下载游戏资源…", loading: true) {}
                .disabled(true)
        case .installing:
            PGRPrimaryButton(title: "正在校验本地文件…", loading: true) {}
                .disabled(true)
        case .updating:
            PGRPrimaryButton(title: "正在检查更新…", loading: true) {}
                .disabled(true)
        case .ready:
            PGRPrimaryButton(title: "启动游戏", systemImage: "play.fill") {
                Task { await state.launchGame() }
            }
        case .launching:
            PGRPrimaryButton(title: "正在启动…", loading: true) {}
                .disabled(true)
        case .running:
            PGRPrimaryButton(title: "终止游戏", systemImage: "stop.fill", tint: .danger) {
                state.terminateGame()
            }
        case .failed:
            PGRPrimaryButton(title: "重试", systemImage: "arrow.clockwise") {
                retry()
            }
            .disabled(state.isBusy)
        }
    }

    private func retry() {
        if !state.runtimeInstalled {
            Task { await state.installRuntime() }
        } else if state.installation == nil {
            onRequestDownload()
        } else {
            Task { await state.launchGame() }
        }
    }
}

// MARK: - Ready tips

struct ReadyTipsCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                PGRSectionHeader(
                    title: "启动提示",
                    subtitle: nil,
                    systemImage: "lightbulb.fill")

                tip(icon: "hourglass", text: "首次启动需要初始化 Wine 容器，窗口出现前可能等待 10–30 秒。")
                tip(icon: "keyboard", text: "键位映射当前\(state.config.keyMappingEnabled ? "已启用" : "未启用")，仅在游戏运行时生效。")
                tip(icon: "slider.horizontal.3", text: "若画面异常，可在设置中切换渲染后端或关闭 Retina。")
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 9) {
                PGRSecondaryButton(title: "键位映射", systemImage: "keyboard") {
                    state.showKeyMapping = true
                }
                PGRSecondaryButton(title: "打开日志", systemImage: "text.alignleft") {
                    state.showLogs = true
                }
                PGRSecondaryButton(title: "设置", systemImage: "gearshape") {
                    state.showSettings = true
                }
            }
            .frame(width: 128)
        }
        .pgrCard(padding: 20)
    }

    private func tip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(PGRTheme.textTertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(PGRTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Progress

struct ProgressDetailView: View {
    let progress: TaskProgress

    @State private var samples: [(date: Date, fraction: Double)] = []

    private let barHeight: CGFloat = 7

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .onAppear { recordSample(progress.fraction) }
        .onChange(of: progress.fraction) { _, newValue in
            recordSample(newValue)
        }
    }

    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.title.isEmpty ? "正在处理…" : progress.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PGRTheme.textPrimary)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PGRTheme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let fraction = progress.fraction {
                    Text(PGRFormat.percent(fraction))
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(PGRTheme.cyanGradient)
                        .contentTransition(.numericText())
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                        Text("处理中")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PGRTheme.cyan)
                    }
                }
            }

            progressBar(at: date)

            HStack(spacing: 14) {
                if let speed = PGRFormat.speed(progress.bytesPerSecond) {
                    label(systemImage: "arrow.down", text: speed, tint: PGRTheme.cyan)
                }
                if let eta = eta(at: date) {
                    label(systemImage: "clock", text: "剩余 \(PGRFormat.remaining(seconds: eta))", tint: PGRTheme.textSecondary)
                } else if progress.fraction != nil {
                    label(systemImage: "clock", text: "正在估算剩余时间…", tint: PGRTheme.textTertiary)
                }
                Spacer(minLength: 0)
                if let fraction = progress.fraction, fraction >= 0.999 {
                    label(systemImage: "checkmark.circle", text: "完成", tint: PGRTheme.success)
                } else {
                    label(systemImage: "lock.shield", text: "逐文件 MD5 校验", tint: PGRTheme.textFaint)
                }
            }
        }
    }

    @ViewBuilder
    private func progressBar(at date: Date) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.075))
                if let fraction = progress.fraction {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [PGRTheme.cyan, PGRTheme.blue],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(barHeight, geo.size.width * min(max(fraction, 0), 1)))
                        .overlay(alignment: .trailing) {
                            Circle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 3, height: 3)
                                .shadow(color: PGRTheme.cyan, radius: 5)
                                .padding(.trailing, 2)
                        }
                        .animation(.easeOut(duration: 0.45), value: fraction)
                } else {
                    // Indeterminate shimmer
                    let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, PGRTheme.cyan.opacity(0.75), .clear],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.32)
                        .offset(x: (geo.size.width * 1.3) * phase - geo.size.width * 0.32)
                }
            }
        }
        .frame(height: barHeight)
        .clipShape(Capsule())
    }

    private func label(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tint)
    }

    // MARK: ETA estimation (UI-side, from fraction samples)

    private func recordSample(_ fraction: Double?) {
        guard let fraction else { return }
        let now = Date()
        samples.append((now, fraction))
        samples.removeAll { now.timeIntervalSince($0.date) > 8 }
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }

    private func eta(at date: Date) -> Double? {
        guard let fraction = progress.fraction, fraction > 0, fraction < 1 else { return nil }
        let recent = samples.filter { date.timeIntervalSince($0.date) <= 8 }
        guard let first = recent.first, let last = recent.last, recent.count >= 2 else { return nil }
        let elapsed = last.date.timeIntervalSince(first.date)
        let delta = last.fraction - first.fraction
        guard elapsed > 0.8, delta > 0.00001 else { return nil }
        let rate = delta / elapsed
        let remaining = (1 - fraction) / rate
        guard remaining.isFinite, remaining > 0, remaining < 60 * 60 * 6 else { return nil }
        return remaining
    }
}

// MARK: - Onboarding (runtime missing)

struct RuntimeOnboardingCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PGRTheme.accentLight)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(PGRTheme.accent.opacity(0.13))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("首次使用 · 准备 Wine 运行环境")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(PGRTheme.textPrimary)
                    Text("需要下载 Wine 11 运行时与 DXMT 渲染层，约 480 MB")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                }
                Spacer(minLength: 8)
                MetaPill(systemImage: "arrow.down.circle", text: "约 480 MB", tint: PGRTheme.accentLight)
                PGRPrimaryButton(title: "安装运行时", systemImage: "arrow.down.circle.fill", wide: false) {
                    Task { await state.installRuntime() }
                }
                .disabled(state.isBusy)
            }

            HStack(spacing: 8) {
                StepChip(index: 1, title: "准备运行时", state: .current)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textFaint)
                StepChip(index: 2, title: "下载游戏", state: .upcoming)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textFaint)
                StepChip(index: 3, title: "开始游戏", state: .upcoming)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                capabilityPill(icon: "cup.and.saucer.fill", title: "Wine 11 运行时")
                capabilityPill(icon: "sparkles.rectangle.stack.fill", title: "DXMT v0.80 渲染")
                capabilityPill(icon: "rectangle.on.rectangle", title: "Retina 高分辨率")
                capabilityPill(icon: "keyboard.fill", title: "键位映射")
                Spacer(minLength: 0)
            }

            PGRDivider()

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9.5))
                Text("运行时下载会自动尝试 GitHub 镜像；完成后将从官方 CDN 直接下载游戏（类似 Yaagl），逐文件 MD5 校验、支持断点续传，完整约 68 GB。")
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(PGRTheme.textFaint)
        }
        .pgrCard(padding: 22)
    }

    private func capabilityPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PGRTheme.accentLight)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(PGRTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Install game card

struct InstallGameCard: View {
    @EnvironmentObject private var state: AppState
    let onRequestDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PGRSectionHeader(
                title: "下载游戏资源",
                subtitle: "从官方 CDN 直接下载（类似 Yaagl），逐文件 MD5 校验，支持断点续传",
                systemImage: "arrow.down.circle.fill")

            HStack(spacing: 10) {
                MetaPill(systemImage: "globe.asia.australia.fill", text: state.currentChannel.displayName)
                MetaPill(systemImage: "internaldrive", text: "约 68 GB · 85,263 个文件")
                Spacer(minLength: 8)
                PGRSecondaryButton(title: "更换渠道", systemImage: "slider.horizontal.3") {
                    state.showSettings = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 7) {
                instruction(index: 1, text: "从渠道官方 CDN 拉取文件清单（\(state.currentChannel.displayName)：\(state.currentChannel.subtitle)）")
                instruction(index: 2, text: "并发下载游戏文件，逐文件 MD5 校验；中断后可从断点继续")
                instruction(index: 3, text: "完成后自动扫描安装目录，直接点击「启动游戏」即可")
            }

            HStack(spacing: 12) {
                PGRPrimaryButton(title: "下载游戏", systemImage: "arrow.down.circle.fill") {
                    onRequestDownload()
                }
                .disabled(state.isBusy)
                Text("安装目录：\(PGRSystem.truncatePath(state.config.gameDir, maxLength: 52))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .pgrCard(padding: 22)
    }

    private func instruction(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(PGRTheme.textSecondary)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.07)))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(PGRTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Error card

struct ErrorCard: View {
    @EnvironmentObject private var state: AppState
    let message: String
    let onRequestDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PGRTheme.danger)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PGRTheme.danger.opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("操作未完成")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PGRTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PGRSecondaryButton(title: "打开日志文件", systemImage: "doc.text") {
                        PGRSystem.reveal(state.logger.logFileURL)
                    }
                    PGRSecondaryButton(title: "重试", systemImage: "arrow.clockwise") {
                        retry()
                    }
                    .disabled(state.isBusy)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(PGRTheme.danger.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(PGRTheme.danger.opacity(0.28), lineWidth: 1)
        )
    }

    private func retry() {
        if !state.runtimeInstalled {
            Task { await state.installRuntime() }
        } else if state.installation == nil {
            onRequestDownload()
        } else {
            Task { await state.launchGame() }
        }
    }
}
