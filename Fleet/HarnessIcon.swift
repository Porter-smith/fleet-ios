import FleetKit
import SwiftUI

/// The logos of the harnesses, the same ones the web draws in HarnessIcon
/// (web/src/fleet-chat/hicons.tsx): Claude Code and Codex are Hugeicons'
/// free set (MIT, @hugeicons/core-free-icons), stroked at 1.5 on a 24 grid;
/// Pi's mark is a filled block "P". They take the surrounding foreground color.
struct HarnessIcon: View {
    let harness: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch harness {
            case "pi": Shape24(paths: Glyphs.pi).fill(.foreground, style: FillStyle(eoFill: true))
            case "codex": Shape24(paths: Glyphs.codex).stroke(.foreground, style: stroke)
            default: Shape24(paths: Glyphs.claude).stroke(.foreground, style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Harness: \(Format.harnessName(harness))")
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: 1.5 * size / 24, lineCap: .round, lineJoin: .round) }
}

/// Paths drawn on a 24 x 24 grid, scaled to fit the frame.
private struct Shape24: Shape {
    let paths: [Path]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var out = Path()
        for p in paths { out.addPath(p, transform: CGAffineTransform(scaleX: scale, y: scale)) }
        return out
    }
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private enum Glyphs {
    static let claude: [Path] = [
        { var p = Path()
          p.move(to: P(13, 12))
          p.addLine(to: P(18.5, 5))
          p.move(to: P(7.63965, 3))
          p.addLine(to: P(12.5, 12))
          p.addLine(to: P(13.6865, 3))
          p.move(to: P(4.48381, 6.71679))
          p.addLine(to: P(11.9872, 12))
          p.move(to: P(3, 12))
          p.addLine(to: P(11.9872, 12.473))
          p.move(to: P(12.2244, 13.177))
          p.addLine(to: P(7, 20))
          p.move(to: P(4.84194, 16.8682))
          p.addLine(to: P(11.2824, 12.9758))
          p.move(to: P(11.5, 21))
          p.addLine(to: P(12.665, 13.177))
          p.move(to: P(21, 14))
          p.addLine(to: P(13.1846, 12.668))
          p.move(to: P(21, 10.5788))
          p.addLine(to: P(13, 12.3223))
          p.move(to: P(16.779, 19.646))
          p.addLine(to: P(12.8876, 13.3772))
          p.move(to: P(19.3566, 18.207))
          p.addLine(to: P(13.313, 12.9893))
          return p }()
    ]

    static let codex: [Path] = [
        { var p = Path()
          p.move(to: P(11.7453, 14.85))
          p.addLine(to: P(6.90436, 12))
          p.addLine(to: P(6.90436, 7))
          p.addCurve(to: P(10.9809, 3), control1: P(6.90436, 4.79086), control2: P(8.72949, 3))
          p.addCurve(to: P(14.3458, 4.74128), control1: P(12.3782, 3), control2: P(13.6113, 3.6898))
          return p }(),
        { var p = Path()
          p.move(to: P(9.59961, 19.1791))
          p.addCurve(to: P(13.0192, 21.0008), control1: P(10.3266, 20.2757), control2: P(11.5866, 21.0008))
          p.addCurve(to: P(17.0958, 17.0008), control1: P(15.2707, 21.0008), control2: P(17.0958, 19.21))
          p.addLine(to: P(17.0958, 12.0008))
          p.addLine(to: P(12.1612, 9.0957))
          return p }(),
        { var p = Path()
          p.move(to: P(9.45166, 13.5))
          p.addLine(to: P(9.45123, 7.66938))
          p.addLine(to: P(13.8642, 5.16938))
          p.addCurve(to: P(19.4329, 6.63348), control1: P(15.814, 4.06481), control2: P(18.3072, 4.72031))
          p.addCurve(to: P(19.5089, 10.4995), control1: P(20.1593, 7.86806), control2: P(20.1388, 9.32466))
          return p }(),
        { var p = Path()
          p.move(to: P(4.48963, 13.4993))
          p.addCurve(to: P(4.56539, 17.3657), control1: P(3.8595, 14.6742), control2: P(3.83887, 16.131))
          p.addCurve(to: P(10.1341, 18.8298), control1: P(5.6911, 19.2789), control2: P(8.18428, 19.9344))
          p.addLine(to: P(14.5471, 16.3298))
          p.addLine(to: P(14.643, 10.7344))
          return p }(),
        { var p = Path()
          p.move(to: P(17.0959, 17.6309))
          p.addCurve(to: P(20.4529, 15.634), control1: P(18.4415, 17.5734), control2: P(19.7295, 16.8634))
          p.addCurve(to: P(18.9608, 10.1699), control1: P(21.5786, 13.7209), control2: P(20.9106, 11.2745))
          p.addLine(to: P(14.5478, 7.66992))
          p.addLine(to: P(9.48907, 10.4255))
          return p }(),
        { var p = Path()
          p.move(to: P(6.90454, 6.36938))
          p.addCurve(to: P(3.54684, 8.3663), control1: P(5.55865, 6.42662), control2: P(4.27032, 7.13672))
          p.addCurve(to: P(5.03896, 13.8304), control1: P(2.42113, 10.2795), control2: P(3.08917, 12.7258))
          p.addLine(to: P(9.45196, 16.3304))
          p.addLine(to: P(14.5, 13.5807))
          return p }()
    ]

    static let pi: [Path] = [
        { var p = Path()
          p.move(to: P(4, 4))
          p.addLine(to: P(15, 4))
          p.addLine(to: P(15, 11))
          p.addLine(to: P(11, 11))
          p.addLine(to: P(11, 15))
          p.addLine(to: P(8, 15))
          p.addLine(to: P(8, 20))
          p.addLine(to: P(4, 20))
          p.addLine(to: P(4, 4))
          p.closeSubpath()
          p.move(to: P(8, 8))
          p.addLine(to: P(8, 11))
          p.addLine(to: P(11, 11))
          p.addLine(to: P(11, 8))
          p.addLine(to: P(8, 8))
          p.closeSubpath()
          return p }(),
        { var p = Path()
          p.move(to: P(15, 11))
          p.addLine(to: P(19, 11))
          p.addLine(to: P(19, 20))
          p.addLine(to: P(15, 20))
          p.closeSubpath()
          return p }()
    ]
}
