import SwiftUI

// MARK: - Emblem artwork

/// Game key-art made entirely from shapes / type (no bundled images).
struct GameEmblemView: View {
    var size: CGFloat = 214
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Halo
            Circle()
                .fill(RadialGradient(
                    colors: [PGRTheme.accent.opacity(0.55), PGRTheme.accent.opacity(0.0)],
                    center: .center, startRadius: 4, endRadius: size * 0.52))
                .frame(width: size * 1.04, height: size * 1.04)

            // Outer broken ring
            Circle()
                .trim(from: 0.04, to: 0.46)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: size * 0.94, height: size * 0.94)
                .rotationEffect(.degrees(appeared ? 18 : -12))

            Circle()
                .trim(from: 0.54, to: 0.96)
                .stroke(
                    LinearGradient(colors: [PGRTheme.accent.opacity(0.45), .clear],
                                   startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: size * 0.94, height: size * 0.94)
                .rotationEffect(.degrees(appeared ? -14 : 10))

            // Tick marks
            ForEach(0..<24, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index % 6 == 0 ? 0.32 : 0.10))
                    .frame(width: index % 6 == 0 ? 1.4 : 1, height: index % 6 == 0 ? 8 : 4)
                    .offset(y: -size * 0.435)
                    .rotationEffect(.degrees(Double(index) * 15))
            }

            // Ghost glyph
            Text("战")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom))
                .offset(y: -2)

            // Solid glyph with crimson gradient
            Text("战双")
                .font(.system(size: size * 0.235, weight: .black))
                .tracking(2)
                .foregroundStyle(
                    LinearGradient(colors: [Color.white, Color(hex: 0xFFC2CB)],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: PGRTheme.accent.opacity(0.9), radius: 14, x: 0, y: 0)
                .offset(y: size * 0.015)

        }
        .frame(width: size, height: size)
        .opacity(appeared ? 1 : 0.4)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { appeared = true }
        }
    }
}

// MARK: - Hero surface

/// Layered gradient + glow + diagonal slash background used by the hero card.
struct HeroBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PGRTheme.corner, style: .continuous)
                .fill(PGRTheme.heroGradient)

            GeometryReader { geo in
                // Diagonal light beam
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width * 0.46, y: geo.size.height + 40))
                    p.addLine(to: CGPoint(x: geo.size.width * 0.9, y: -40))
                    p.addLine(to: CGPoint(x: geo.size.width * 0.99, y: -40))
                    p.addLine(to: CGPoint(x: geo.size.width * 0.62, y: geo.size.height + 40))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.035), Color.white.opacity(0.0)],
                    startPoint: .bottomLeading, endPoint: .topTrailing))

                // Accent glow behind the emblem (right side)
                RadialGradient(
                    colors: [PGRTheme.accent.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.86, y: 0.25),
                    startRadius: 8, endRadius: 300)
                    .blendMode(.plusLighter)

                // Cold glow left
                RadialGradient(
                    colors: [PGRTheme.cyan.opacity(0.08), .clear],
                    center: UnitPoint(x: 0.02, y: 0.95),
                    startRadius: 8, endRadius: 260)
            }
            .clipShape(RoundedRectangle(cornerRadius: PGRTheme.corner, style: .continuous))

            // Hairline top sheen
            RoundedRectangle(cornerRadius: PGRTheme.corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.04), PGRTheme.accent.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
        }
    }
}

// MARK: - Metric cards

struct MetricCard: View {
    let systemImage: String
    let label: String
    let value: String
    var tint: Color = PGRTheme.textSecondary
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 2.5) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PGRTheme.textTertiary)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PGRTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(PGRTheme.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Onboarding step chip

struct StepChip: View {
    let index: Int
    let title: String
    let state: State

    enum State { case done, current, upcoming }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: 21, height: 21)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(PGRTheme.bgBase)
                } else {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(foreground)
                }
            }
            Text(title)
                .font(.system(size: 11.5, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? PGRTheme.textPrimary : PGRTheme.textTertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(state == .current ? PGRTheme.accent.opacity(0.10) : Color.white.opacity(0.03))
        )
        .overlay(
            Capsule().strokeBorder(
                state == .current ? PGRTheme.accent.opacity(0.35) : Color.white.opacity(0.06),
                lineWidth: 1)
        )
    }

    private var background: Color {
        switch state {
        case .done: return PGRTheme.success
        case .current: return PGRTheme.accent
        case .upcoming: return Color.white.opacity(0.08)
        }
    }

    private var foreground: Color {
        switch state {
        case .current: return .white
        case .upcoming: return PGRTheme.textTertiary
        case .done: return PGRTheme.bgBase
        }
    }
}
