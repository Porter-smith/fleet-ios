import SwiftUI
import UIKit
import FleetKit

/// Fleet chat's palette (web/src/index.css, the `.fleet-chat` tokens): near-black
/// greys in dark mode, white and greys in light mode, and three signal colors.
enum Theme {
    private static func color(_ dark: UInt32, _ light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    static let canvas = color(0x151515, 0xFFFFFF)
    static let side = color(0x1B1B1B, 0xFAFAFA)
    static let secondary = color(0x2B2B2B, 0xEFEFEF)
    static let select = color(0x262626, 0xEDEDED)
    static let line = color(0x313131, 0xDFDFDF)
    static let seam = color(0x252525, 0xE9E9E9)
    static let ink = color(0xC1C1C1, 0x333333)
    static let ink2 = color(0xB7B7B7, 0x525252)
    static let muted = color(0x989898, 0x636363)
    static let strong = color(0xEBEBEB, 0x111111)
    static let primary = color(0xC4C4C4, 0x262626)
    static let onPrimary = color(0x1A1A1A, 0xFFFFFF)
    static let ok = color(0x4FBF86, 0x22915A)
    static let bad = color(0xE0675F, 0xB4352C)
    static let attn = color(0xE5B04A, 0xB07A12)
    static let hover = color(0xC1C1C1, 0x333333, darkAlpha: 0.138, lightAlpha: 0.059)
    static let active = color(0xC1C1C1, 0x333333, darkAlpha: 0.225, lightAlpha: 0.118)
    static let code = color(0xC1C1C1, 0x333333, darkAlpha: 0.04, lightAlpha: 0.035)
    static let bubble = color(0xC1C1C1, 0x333333, darkAlpha: 0.06, lightAlpha: 0.05)
    static let attnSoft = color(0xE5B04A, 0xD29B2A, darkAlpha: 0.07, lightAlpha: 0.08)
    /// The waiting cards' border: attn mixed 40% into the line color.
    static let attnLine = color(0x7A6133, 0xE2CC9F)
    static let badLine = color(0x7A3F3B, 0xE1AEAA)

    /// Text sizes from the web, in points (the web's px).
    static let body = Font.system(size: 15)
    static let small = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 12, design: .monospaced)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Light, dark, or as the system: the web chat's moon / sun toggle. Dark by default, like the web.
enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

// ---- small pieces shared by the screens

/// The web's spinner: a thin ring with a bright arc, turning.
struct Spinner: View {
    var size: CGFloat = 12
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Theme.primary, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .background(Circle().stroke(Theme.primary.opacity(0.28), lineWidth: 1.75))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Running")
    }
}

/// A run's state in lists: a spinner while it works, an amber dot when it needs you.
struct StatusGlyph: View {
    let status: ChatThread.Status

    var body: some View {
        switch status {
        case .running:
            Spinner(size: 12).opacity(0.7).accessibilityLabel("Working")
        case .waiting:
            Circle().fill(Theme.attn).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.attn.opacity(0.25), lineWidth: 3).frame(width: 13, height: 13))
                .accessibilityLabel("Needs you")
        case .unknown:
            Circle().strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 7, height: 7)
                .accessibilityLabel("Unknown: machine unreachable")
        case .idle:
            Circle().fill(Theme.muted).frame(width: 7, height: 7).accessibilityLabel("Idle")
        case .done:
            Circle().fill(Theme.ink2.opacity(0.6)).frame(width: 5, height: 5).accessibilityLabel("Finished")
        }
    }
}

/// "Working..." with a light sweeping across it (the web's animate-shine).
struct ShineText: View {
    let text: String
    var font: Font = Theme.small
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Theme.muted)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Theme.strong.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                }
                .mask(Text(text).font(font))
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

/// The web's buttons: primary (ink on a light fill), plain (secondary fill) and danger.
struct FleetButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, danger, ghost }
    var kind: Kind = .plain
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minHeight: compact ? 32 : 36)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if kind == .plain || kind == .danger {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(kind == .danger ? Theme.badLine : Theme.line, lineWidth: 1)
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.onPrimary
        case .plain, .ghost: Theme.ink
        case .danger: Theme.bad
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? Theme.primary.opacity(0.85) : Theme.primary
        case .plain: pressed ? Theme.active : Theme.secondary
        case .danger: pressed ? Theme.bad.opacity(0.15) : Theme.canvas
        case .ghost: pressed ? Theme.active : .clear
        }
    }
}

extension ButtonStyle where Self == FleetButtonStyle {
    static func fleet(_ kind: FleetButtonStyle.Kind = .plain, compact: Bool = false) -> FleetButtonStyle {
        FleetButtonStyle(kind: kind, compact: compact)
    }
}

/// A muted option button under the prompt box (machine, folder, permission mode).
struct OptionChip: View {
    let icon: String?
    let text: String
    var chevron = true
    var tint: Color = Theme.ink2

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 12)) }
            Text(text).lineLimit(1).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}
