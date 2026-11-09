import SwiftUI
import AppKit

// MARK: - Key mapping page

struct KeyMappingPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var mapper: KeyMapper

    @State private var phase: CapturePhase = .idle
    @State private var capturedSource: CapturedKey?
    @State private var captureTask: Task<Void, Never>?
    @State private var captureHint: String?
    @State private var hoveringAdd = false

    private enum CapturePhase: Equatable {
        case idle
        case source
        case target
    }

    private struct CapturedKey: Equatable {
        let code: Int
        let label: String
    }

    init(mapper: KeyMapper) {
        _mapper = ObservedObject(wrappedValue: mapper)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                PGRPageHeader(
                    eyebrow: "INPUT",
                    title: "键位映射",
                    subtitle: "拦截并改写键盘按键，仅在游戏运行时生效",
                    trailing: AnyView(mappingStatusPill)
                )
                .padding(.bottom, 2)

                masterCard
                permissionCard
                mappingsCard
                tipsCard

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if phase != .idle {
                captureOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: phase)
        .onExitCommand { cancelCapture() }
        .task {
            // Keep the permission state in sync while the page is visible.
            while !Task.isCancelled {
                mapper.refreshAccessibilityStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onDisappear { cancelCapture() }
    }

    // MARK: Usage tips

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            PGRSectionHeader(
                title: "使用提示",
                subtitle: nil,
                systemImage: "lightbulb.fill")

            tipRow(index: 1, text: "开启总开关后，只有游戏运行期间才会拦截按键；启动器自身与其他 App 不受影响。")
            tipRow(index: 2, text: "若映射无效，请确认已在「系统设置 → 隐私与安全性 → 辅助功能」中勾选本应用。")
            tipRow(index: 3, text: "所有修改即时保存；退出游戏后映射自动停止，无需手动关闭。")
        }
        .pgrCard(padding: 18)
    }

    private func tipRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(PGRTheme.textSecondary)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.07)))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(PGRTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Status pill

    private var mappingStatusPill: some View {
        let color: Color = mapper.isRunning ? PGRTheme.success : PGRTheme.textTertiary
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(mapper.isRunning ? "映射运行中" : "映射未激活")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(mapper.isRunning ? PGRTheme.success : PGRTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
    }

    // MARK: Master switch

    private var masterCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PGRTheme.accentLight)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PGRTheme.accent.opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("启用键位映射")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text("开启后，启动游戏时自动开始拦截按键；退出游戏时自动关闭，不会常驻影响系统输入。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { state.config.keyMappingEnabled },
                set: { state.setKeyMappingEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(PGRTheme.accent)
        }
        .pgrCard(padding: 16)
    }

    // MARK: Permission

    private var permissionCard: some View {
        Group {
            if mapper.accessibilityGranted {
                permissionGranted
            } else {
                permissionMissing
            }
        }
    }

    private var permissionMissing: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PGRTheme.warning)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(PGRTheme.warning.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 7) {
                Text("需要「辅助功能」权限")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text("macOS 要求获得辅助功能权限后，应用才能拦截并发送键盘事件。点击「去授权」后在系统设置中勾选 PGR Launcher，然后回到本页。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PGRTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PGRSecondaryButton(title: "去授权", systemImage: "hand.raised.fill") {
                        mapper.requestAccessibilityPermission()
                    }
                    PGRSecondaryButton(title: "打开系统设置", systemImage: "gearshape") {
                        PGRSystem.openAccessibilitySettings()
                    }
                    PGRSecondaryButton(title: "刷新状态", systemImage: "arrow.clockwise") {
                        mapper.refreshAccessibilityStatus()
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PGRTheme.warning.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PGRTheme.warning.opacity(0.24), lineWidth: 1)
        )
    }

    private var permissionGranted: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PGRTheme.success)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PGRTheme.success.opacity(0.11))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("辅助功能权限已授予")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                Text(mapper.isRunning
                     ? "键位映射正在运行，游戏中的按键将被实时改写。"
                     : "启动游戏时将自动开始拦截按键；退出游戏后自动停止。")
                    .font(.system(size: 11))
                    .foregroundStyle(PGRTheme.textTertiary)
            }
            Spacer(minLength: 8)
            PGRSecondaryButton(title: "刷新状态", systemImage: "arrow.clockwise") {
                mapper.refreshAccessibilityStatus()
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(PGRTheme.success.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(PGRTheme.success.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: Mapping list

    private var mappingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                PGRSectionHeader(
                    title: "按键映射",
                    subtitle: "按下源键时，游戏会收到目标键；支持启用 / 停用与删除",
                    systemImage: "arrow.left.arrow.right")
                Spacer(minLength: 8)
                addButton
            }

            if captureHint != nil {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text(captureHint ?? "")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(PGRTheme.warning)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PGRTheme.warning.opacity(0.08))
                )
            }

            if state.config.keyMappings.isEmpty {
                PGREmptyState(
                    systemImage: "keyboard",
                    title: "还没有按键映射",
                    subtitle: "点击「新增映射」，依次按下源键与目标键即可创建。\n例如：把 F 键映射为 Space，实现更顺手的闪避操作。")
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.black.opacity(0.16))
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach(state.config.keyMappings) { mapping in
                        mappingRow(mapping)
                    }
                }
            }

            if !state.config.keyMappings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5))
                    Text("映射仅在游戏运行时生效；退出游戏后自动停止，不影响系统其他应用。")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(PGRTheme.textFaint)
            }
        }
        .pgrCard(padding: 18)
    }

    private var addButton: some View {
        Button {
            beginCapture()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .bold))
                Text("新增映射")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PGRTheme.accentGradient.opacity(hoveringAdd ? 1 : 0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: PGRTheme.accent.opacity(0.3), radius: hoveringAdd ? 10 : 6, x: 0, y: 3)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hoveringAdd = $0 }
        .animation(.easeOut(duration: 0.15), value: hoveringAdd)
        .disabled(phase != .idle)
    }

    private func mappingRow(_ mapping: KeyMapping) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                KeyCapView(label: mapping.sourceLabel, accent: PGRTheme.textPrimary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PGRTheme.textFaint)
                KeyCapView(label: mapping.targetLabel, accent: PGRTheme.accentLight)
            }
            .frame(width: 176, alignment: .leading)

            Text("按下 \(mapping.sourceLabel) → 发送 \(mapping.targetLabel)")
                .font(.system(size: 11))
                .foregroundStyle(mapping.enabled ? PGRTheme.textTertiary : PGRTheme.textFaint)

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { mapping.enabled },
                set: { newValue in
                    var copy = mapping
                    copy.enabled = newValue
                    state.updateKeyMapping(copy)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(PGRTheme.accent)

            PGRIconButton(systemImage: "trash", help: "删除映射", tint: PGRTheme.danger) {
                withAnimation(.easeOut(duration: 0.15)) {
                    state.removeKeyMapping(id: mapping.id)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
        )
        .opacity(mapping.enabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: mapping.enabled)
    }

    // MARK: Capture flow

    private func beginCapture() {
        captureHint = nil
        capturedSource = nil
        phase = .source
        startCapture(for: .source)
    }

    private func startCapture(for step: CapturePhase) {
        captureTask?.cancel()
        captureTask = Task { @MainActor in
            let result = await mapper.captureNextKey(timeout: 30)
            guard !Task.isCancelled else { return }
            handleCapture(result, for: step)
        }
    }

    private func handleCapture(_ result: (code: Int, label: String)?, for step: CapturePhase) {
        guard phase == step else { return }
        switch step {
        case .source:
            if let result {
                capturedSource = CapturedKey(code: result.code, label: result.label)
                phase = .target
                startCapture(for: .target)
            } else {
                captureHint = "未捕获到按键（可能超时），请重试。"
                phase = .idle
            }
        case .target:
            if let result, let source = capturedSource {
                let mapping = KeyMapping(
                    sourceKeyCode: source.code,
                    sourceLabel: source.label,
                    targetKeyCode: result.code,
                    targetLabel: result.label,
                    enabled: true)
                state.addKeyMapping(mapping)
                mapper.refreshAccessibilityStatus()
                captureHint = "已添加映射：\(source.label) → \(result.label)"
                phase = .idle
                capturedSource = nil
            } else {
                captureHint = "未捕获到目标按键（可能超时），请重试。"
                phase = .idle
                capturedSource = nil
            }
        case .idle:
            break
        }
    }

    private func cancelCapture() {
        guard phase != .idle else { return }
        captureTask?.cancel()
        captureTask = nil
        phase = .idle
        capturedSource = nil
        captureHint = "已取消按键捕获。"
    }

    // MARK: Capture overlay

    private var captureOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { cancelCapture() }

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(PGRTheme.accent.opacity(0.12))
                        .frame(width: 76, height: 76)
                    Circle()
                        .strokeBorder(PGRTheme.accent.opacity(0.35), lineWidth: 1)
                        .frame(width: 76, height: 76)
                    Image(systemName: phase == .source ? "keyboard" : "keyboard.badge.ellipsis")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(PGRTheme.accentLight)
                }

                VStack(spacing: 7) {
                    Text(phase == .source ? "请按下要映射的源键" : "请按下目标键")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PGRTheme.textPrimary)
                    Text(phase == .source
                         ? "捕获你当前键盘上的任意按键，作为映射的输入键。"
                         : "捕获游戏应当收到的按键，作为映射的输出键。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PGRTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                if let source = capturedSource {
                    HStack(spacing: 8) {
                        Text("源键")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PGRTheme.textTertiary)
                        KeyCapView(label: source.label, accent: PGRTheme.textPrimary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PGRTheme.textFaint)
                        Text("目标键")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PGRTheme.textTertiary)
                        Text("等待按下…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PGRTheme.accentLight)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                }

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                    Text("等待按键输入，30 秒后自动取消")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                }

                PGRSecondaryButton(title: "取消（Esc）", systemImage: "xmark", action: cancelCapture)
            }
            .padding(28)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PGRTheme.cardElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), PGRTheme.accent.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.55), radius: 40, x: 0, y: 20)
        }
    }
}
