import SwiftUI
import AppKit

// MARK: - Palette

/// Centralised dark visual language for the launcher (PGR-inspired crimson + cold steel).
enum PGRTheme {
    // Backgrounds
    static let bgBase = Color(hex: 0x07090F)
    static let bgTop = Color(hex: 0x0B0F18)
    static let bgBottom = Color(hex: 0x090C13)
    static let sidebar = Color(hex: 0x0A0D15)
    static let card = Color(hex: 0x121826)
    static let cardElevated = Color(hex: 0x17202F)
    static let cardInset = Color(hex: 0x0C111B)

    // Accents
    static let accent = Color(hex: 0xE8455A)
    static let accentDeep = Color(hex: 0xA81D33)
    static let accentLight = Color(hex: 0xFF7B8C)
    static let cyan = Color(hex: 0x4CC9F0)
    static let blue = Color(hex: 0x4361EE)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    // Text
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.42)
    static let textFaint = Color.white.opacity(0.26)

    // Lines
    static let stroke = Color.white.opacity(0.085)
    static let strokeStrong = Color.white.opacity(0.16)

    static let corner: CGFloat = 16
    static let cornerSmall: CGFloat = 10

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xFF5C72), Color(hex: 0xC3243F)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cyanGradient = LinearGradient(
        colors: [Color(hex: 0x6FE3FF), Color(hex: 0x3A6FF7)],
        startPoint: .leading, endPoint: .trailing)

    static let heroGradient = LinearGradient(
        colors: [Color(hex: 0x1A2233), Color(hex: 0x0D1220)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Color(hex: 0x7FA6C9)
        case .warn: return warning
        case .error: return danger
        }
    }

    static func statusColor(_ status: LauncherStatus) -> Color {
        switch status {
        case .checking, .preparingRuntime, .downloading, .installing, .updating, .launching:
            return cyan
        case .needsRuntime, .needsGame:
            return warning
        case .ready:
            return success
        case .running:
            return Color(hex: 0x60A5FA)
        case .failed:
            return danger
        }
    }

    static func shortStatus(_ status: LauncherStatus) -> String {
        switch status {
        case .checking: return "检查中"
        case .needsRuntime: return "待准备"
        case .preparingRuntime: return "准备中"
        case .needsGame: return "未安装"
        case .downloading: return "下载中"
        case .installing: return "安装中"
        case .updating: return "更新中"
        case .ready: return "就绪"
        case .launching: return "启动中"
        case .running: return "运行中"
        case .failed: return "出错"
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha)
    }
}

// MARK: - Typography helpers

enum PGRFont {
    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .bold, design: .default) }
    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .regular) }
    static func medium(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium) }
    static func small(_ size: CGFloat = 11.5) -> Font { .system(size: size, weight: .regular) }
    static func mono(_ size: CGFloat = 11.5) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
    static let eyebrow = Font.system(size: 10, weight: .semibold)
}

// MARK: - Backgrounds

/// Full-window ambient backdrop: deep gradient, soft colour glows and a faint grid.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PGRTheme.bgTop, PGRTheme.bgBottom],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(
                colors: [Color(hex: 0x2B3A5C, alpha: 0.55), .clear],
                center: UnitPoint(x: 0.78, y: 0.02),
                startRadius: 10, endRadius: 520)

            RadialGradient(
                colors: [Color(hex: 0x6E1E32, alpha: 0.32), .clear],
                center: UnitPoint(x: 0.04, y: 0.96),
                startRadius: 10, endRadius: 560)

            GridTexture()
                .opacity(0.5)
        }
        .ignoresSafeArea()
    }
}

/// Very subtle 1px engineering grid.
struct GridTexture: View {
    var spacing: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(Color.white.opacity(0.022)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cards

struct PGRCardModifier: ViewModifier {
    var radius: CGFloat = PGRTheme.corner
    var elevated: Bool = false
    var padding: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(elevated ? PGRTheme.cardElevated : PGRTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0.035), .clear],
                                startPoint: .top, endPoint: .center)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.13), Color.white.opacity(0.035)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1))
            .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func pgrCard(radius: CGFloat = PGRTheme.corner, elevated: Bool = false, padding: CGFloat = 22) -> some View {
        modifier(PGRCardModifier(radius: radius, elevated: elevated, padding: padding))
    }

    /// Brighten-on-hover feedback used by every interactive surface.
    func pgrHover(radius: CGFloat = 10, amount: Double = 0.055, scale: CGFloat = 1.0) -> some View {
        modifier(HoverHighlight(radius: radius, amount: amount, scaleAmount: scale))
    }
}

struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 10
    var amount: Double = 0.055
    var scaleAmount: CGFloat = 1.0

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(hovering ? amount : 0))
            )
            .scaleEffect(hovering && scaleAmount != 1 ? scaleAmount : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

// MARK: - Buttons

enum PGRButtonTint {
    case accent
    case cyan
    case danger
    case neutral

    var gradient: LinearGradient {
        switch self {
        case .accent: return PGRTheme.accentGradient
        case .cyan: return PGRTheme.cyanGradient
        case .danger:
            return LinearGradient(colors: [Color(hex: 0xF0525F), Color(hex: 0xA8172B)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .neutral:
            return LinearGradient(colors: [Color(hex: 0x2A3446), Color(hex: 0x1B2331)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var glow: Color {
        switch self {
        case .accent: return PGRTheme.accent.opacity(0.35)
        case .cyan: return PGRTheme.cyan.opacity(0.30)
        case .danger: return PGRTheme.danger.opacity(0.32)
        case .neutral: return Color.black.opacity(0.25)
        }
    }
}

/// The hero call-to-action. Reads `isEnabled` from the environment for a clear disabled state.
struct PGRPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: PGRButtonTint = .accent
    var loading: Bool = false
    var wide: Bool = true
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.72)
                        .frame(width: 14, height: 14)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, wide ? 26 : 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.gradient)
                    .opacity(isEnabled ? 1 : 0.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0.08), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.07 : 0))
            )
            .shadow(color: tint.glow, radius: hovering && isEnabled ? 16 : 10, x: 0, y: 5)
            .scaleEffect(hovering && isEnabled ? 1.012 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}

/// Compact secondary action (open folder / rescan…).
struct PGRSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6.5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(isEnabled ? PGRTheme.textPrimary : PGRTheme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8.5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.10 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.11 : 0.05), lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Small text/icon button used inside rows (delete, open, copy…).
struct PGRIconButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color = PGRTheme.textSecondary
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering && isEnabled ? tint : PGRTheme.textTertiary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(hovering && isEnabled ? 0.09 : 0))
                )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(help)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Badges & chips

struct StatusBadge: View {
    let status: LauncherStatus

    @State private var pulsing = false

    var body: some View {
        let color = PGRTheme.statusColor(status)
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.22))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulsing && status.isBusy ? 1.35 : 1)
                    .opacity(pulsing && status.isBusy ? 0.3 : 1)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(PGRTheme.shortStatus(status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(color.opacity(0.10))
        )
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 1))
        .onAppear { pulsing = true }
        .animation(status.isBusy ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                   value: pulsing)
    }
}

struct MetaPill: View {
    var systemImage: String? = nil
    let text: String
    var tint: Color = PGRTheme.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// Selectable option chip used for render backend / FPS.
struct PGRChoiceChip: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? PGRTheme.textPrimary : PGRTheme.textSecondary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(selected ? PGRTheme.textSecondary : PGRTheme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected
                          ? PGRTheme.accent.opacity(0.16)
                          : Color.white.opacity(hovering && isEnabled ? 0.075 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? PGRTheme.accent.opacity(0.55) : Color.white.opacity(hovering ? 0.18 : 0.09),
                        lineWidth: selected ? 1.2 : 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

// MARK: - Structural pieces

struct PGRSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PGRTheme.accentLight)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(PGRTheme.accent.opacity(0.13))
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PGRPageHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow.uppercased())
                    .font(PGRFont.eyebrow)
                    .tracking(2.2)
                    .foregroundStyle(PGRTheme.accentLight.opacity(0.85))
                Text(title)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(PGRTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PGRTheme.textSecondary)
                }
            }
            Spacer(minLength: 16)
            if let trailing {
                trailing
            }
        }
    }
}

struct PGRDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

struct PGRSettingRow<Content: View>: View {
    let title: String
    var subtitle: String?
    let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PGRTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PGRTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 2)
    }
}

/// Key-cap style label used for keyboard mapping rows.
struct KeyCapView: View {
    let label: String
    var accent: Color = PGRTheme.textPrimary
    var wide: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minWidth: wide ? 62 : 46)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0.05), .clear],
                                startPoint: .top, endPoint: .bottom)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}

/// App monogram icon drawn purely in code.
struct PGRAppIcon: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x3A1020), Color(hex: 0x12060C)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [PGRTheme.accent.opacity(0.9), PGRTheme.accentDeep.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            // Diagonal crack
            Path { p in
                p.move(to: CGPoint(x: size * 0.20, y: size * 0.82))
                p.addLine(to: CGPoint(x: size * 0.62, y: size * 0.18))
                p.addLine(to: CGPoint(x: size * 0.80, y: size * 0.18))
                p.addLine(to: CGPoint(x: size * 0.38, y: size * 0.82))
                p.closeSubpath()
            }
            .fill(Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))

            Text("战")
                .font(.system(size: size * 0.52, weight: .black))
                .foregroundStyle(LinearGradient(
                    colors: [Color.white, Color(hex: 0xFFB3BE)],
                    startPoint: .top, endPoint: .bottom))
                .shadow(color: PGRTheme.accent.opacity(0.6), radius: 6, x: 0, y: 0)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Empty state

struct PGREmptyState: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(PGRTheme.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PGRTheme.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PGRTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
