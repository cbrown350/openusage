import SwiftUI

/// A provider's copied vector mark, keyed by provider id.
struct IconSource: Hashable {
    let providerID: String

    /// Named constructor retained at call sites so the stored string's meaning stays explicit.
    static func providerMark(_ providerID: String) -> IconSource {
        IconSource(providerID: providerID)
    }
}

/// Renders an `IconSource` in monochrome (`Theme.iconGray`): on the glass popover, icon color
/// reads as noise (WWDC25 — monochrome reduces it), and provider identity comes from the name
/// beside the mark.
struct ProviderIcon: View {
    let source: IconSource
    /// Margin kept around a vector provider mark, forwarded to `ProviderIconShape`. Defaults to the
    /// breathing-room value used in list contexts (e.g. Settings); callers that want the mark to
    /// fill its box — like the section header matching the menu-bar strip glyph — pass a smaller value.
    var inset: CGFloat = 0.14

    var body: some View {
        if let mark = ProviderMarks.mark(for: source.providerID) {
            ProviderIconShape(pathData: mark.path, inset: inset)
                .fill(Theme.iconGray)
        } else {
            Image(systemName: ProviderMarks.symbolFallback(for: source.providerID))
                .foregroundStyle(Theme.iconGray)
        }
    }
}

/// A SwiftUI `Shape` built from an SVG path `d` string, scaled to fit the frame and centered.
///
/// It normalizes by the artwork's **true bounding box** (not the declared `viewBox`): some source SVGs
/// bake whitespace into their viewBox (Claude/Codex/Cursor sit ~10% inside a 100×100 box) while others
/// run edge-to-edge (Devin, Grok). Fitting the real path bounds gives every provider mark the same
/// optical weight, then a single shared `inset` adds consistent breathing room so none touch the edge.
struct ProviderIconShape: Shape {
    let pathData: String
    /// Fraction of the frame kept as margin on every side, so normalized marks have uniform padding.
    var inset: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.parse(pathData)
        let bounds = raw.cgPath.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return raw }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let dx = target.midX - bounds.midX * scale
        let dy = target.midY - bounds.midY * scale
        return raw
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// A provider vector mark: the combined SVG path data. `ProviderIconShape` normalizes by the path's
/// true bounding box, so the source `viewBox` isn't needed.
struct ProviderMark: Hashable {
    let path: String
}

/// Loads copied provider SVGs from the bundle and extracts their path data (cached).
@MainActor
enum ProviderMarks {
    private static var cache: [String: ProviderMark] = [:]
    private static var missing: Set<String> = []

    static func mark(for id: String) -> ProviderMark? {
        if let cached = cache[id] { return cached }
        if missing.contains(id) { return nil }
        guard
            let url = Bundle.openUsageResources.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            let d = extractD(text)
        else {
            missing.insert(id)
            return nil
        }
        let mark = ProviderMark(path: d)
        cache[id] = mark
        return mark
    }

    static func symbolFallback(for id: String) -> String {
        switch id {
        case "antigravity": return "paperplane"
        case "claude": return "sparkle"
        case "codex": return "circle.hexagongrid"
        case "cursor": return "cube"
        case "grok": return "bolt.fill"
        case "ollama": return "cpu.fill"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "openrouter": return "point.3.connected.trianglepath.dotted"
        case "qwen": return "q.circle.fill"
        case "zai": return "z.signal"
        default: return "app.dashed"
        }
    }

    private static func extractD(_ svg: String) -> String? {
        var values: [String] = []
        var searchStart = svg.startIndex
        while let start = svg[searchStart...].range(of: "d=\"") {
            let rest = svg[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            values.append(String(rest[..<end]))
            searchStart = end
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
}

/// SVG path parser supporting M/L/H/V/C/S/Q/T/A/Z (absolute + relative, implicit repeats). Elliptical
/// arcs (A) are approximated with cubic beziers so brand marks built from circles/rounded shapes
/// (Ollama, Qwen) render correctly alongside the older arc-free marks.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var prevWasCubic = false
        var prevWasQuad = false

        func skipSeparators() {
            while i < n {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < n {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." && !sawDot {
                    sawDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        /// An SVG arc's large-arc / sweep flag: a single `0`/`1`, which the spec allows to be packed
        /// against neighboring numbers without a separator (e.g. `a1 1 0 011 1`), so read exactly one char.
        func readFlag() -> Bool? {
            skipSeparators()
            guard i < n, chars[i] == "0" || chars[i] == "1" else { return nil }
            let flag = chars[i] == "1"
            i += 1
            return flag
        }

        func reflected() -> CGPoint {
            guard let lc = lastControl else { return current }
            return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
        }

        /// Append an elliptical arc from `current` to `end`, approximated by cubic beziers (one per
        /// ≤90° segment). Implements the SVG spec's endpoint→center conversion (W3C F.6). A degenerate
        /// arc (zero radius) degrades to a straight line, matching the spec.
        func addArc(rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDeg: CGFloat,
                    largeArc: Bool, sweep: Bool, end: CGPoint) {
            let start = current
            var rx = abs(rxIn)
            var ry = abs(ryIn)
            guard rx > 0, ry > 0 else { path.addLine(to: end); current = end; return }

            let phi = rotationDeg * .pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let dx = (start.x - end.x) / 2
            let dy = (start.y - end.y) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy

            // Scale the radii up if they're too small to connect the two endpoints (F.6.6).
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                let scale = sqrt(lambda)
                rx *= scale
                ry *= scale
            }

            let rx2 = rx * rx
            let ry2 = ry * ry
            let x1p2 = x1p * x1p
            let y1p2 = y1p * y1p
            var coef: CGFloat = 0
            let den = rx2 * y1p2 + ry2 * x1p2
            if den != 0 {
                let num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2
                coef = (largeArc != sweep ? 1 : -1) * sqrt(max(0, num / den))
            }
            let cxp = coef * (rx * y1p / ry)
            let cyp = coef * -(ry * x1p / rx)
            let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

            func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
                guard len > 0 else { return 0 }
                var angle = acos(max(-1, min(1, dot / len)))
                if (ux * vy - uy * vx) < 0 { angle = -angle }
                return angle
            }

            let theta1 = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var dtheta = vectorAngle((x1p - cxp) / rx, (y1p - cyp) / ry,
                                     (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
            if sweep && dtheta < 0 { dtheta += 2 * .pi }

            // A point on the unit circle mapped through the ellipse's scale/rotation/translation.
            func mapPoint(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
                let ex = rx * ux
                let ey = ry * uy
                return CGPoint(x: cx + cosPhi * ex - sinPhi * ey,
                               y: cy + sinPhi * ex + cosPhi * ey)
            }

            let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
            let segmentAngle = dtheta / CGFloat(segments)
            var angle = theta1
            for _ in 0..<segments {
                let half = segmentAngle / 2
                let alpha = sin(segmentAngle) * (sqrt(4 + 3 * tan(half) * tan(half)) - 1) / 3
                let next = angle + segmentAngle
                let control1 = mapPoint(cos(angle) - alpha * sin(angle),
                                        sin(angle) + alpha * cos(angle))
                let control2 = mapPoint(cos(next) + alpha * sin(next),
                                        sin(next) - alpha * cos(next))
                path.addCurve(to: mapPoint(cos(next), sin(next)), control1: control1, control2: control2)
                angle = next
            }
            current = end
        }

        while i < n {
            skipSeparators()
            if i >= n { break }

            if chars[i].isLetter {
                lastCommand = chars[i]
                i += 1
            }

            let cmd = lastCommand
            var failed = false
            var isCubic = false
            var isQuad = false

            switch cmd {
            case "M", "m":
                if let p = readPoint(relative: cmd == "m") {
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    lastCommand = (cmd == "m") ? "l" : "L"
                } else { failed = true }

            case "L", "l":
                if let p = readPoint(relative: cmd == "l") {
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "H", "h":
                if let x = readNumber() {
                    let nx = (cmd == "h") ? current.x + x : x
                    let p = CGPoint(x: nx, y: current.y)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "V", "v":
                if let y = readNumber() {
                    let ny = (cmd == "v") ? current.y + y : y
                    let p = CGPoint(x: current.x, y: ny)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "C", "c":
                if let c1 = readPoint(relative: cmd == "c"),
                   let c2 = readPoint(relative: cmd == "c"),
                   let end = readPoint(relative: cmd == "c") {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "S", "s":
                if let c2 = readPoint(relative: cmd == "s"),
                   let end = readPoint(relative: cmd == "s") {
                    let c1 = prevWasCubic ? reflected() : current
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "Q", "q":
                if let c = readPoint(relative: cmd == "q"),
                   let end = readPoint(relative: cmd == "q") {
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "T", "t":
                if let end = readPoint(relative: cmd == "t") {
                    let c = prevWasQuad ? reflected() : current
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "A", "a":
                if let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                   let largeArcFlag = readFlag(), let sweepFlag = readFlag(),
                   let end = readPoint(relative: cmd == "a") {
                    addArc(rx: rx, ry: ry, rotationDeg: rotation,
                           largeArc: largeArcFlag, sweep: sweepFlag, end: end)
                } else { failed = true }

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                failed = true
            }

            if failed { break }
            prevWasCubic = isCubic
            prevWasQuad = isQuad
        }

        return path
    }
}
