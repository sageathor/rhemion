// The animated Rhemion logo for the Welcome window, drawn natively (no image asset). The orb is the user's
// double in the machine — their voice inside the Mac; the rings are layers of air around it. Motion (story A,
// "the voice goes out into the world"): an intro (the orb appears,
// four rings step out of it), then a pressure pulse from the orb every 9 s, plus one on an event (setup done).
// The pulse obeys one law — the closer to the source, the louder: each ring is pushed out and brightened by
// its loudness r1/r (compression), then pulled slightly in and dimmed (rarefaction); the rings never leave,
// the energy passes through them; a fifth ring exists only while the pulse passes. No glow on the rings —
// only the soft halo of the orb. Reduce Motion → the still mark. Frames are drawn only while something
// moves (intro, pulse); between pulses the timeline is idle.
//
// Farewell mode (the Uninstall window): the same mark, calmer — a pulse every 12 s instead of 9,
// the push out 0.6× as strong, the rings at 85% opacity. When uninstall succeeds the clock's `collapse()`
// folds the mark into its core over 0.9 s: the rings sink into the orb and fade, then the orb and its halo
// shrink to nothing. Without farewell/collapse every frame is exactly what it was before.

import SwiftUI

/// Drives the logo's timeline. The Welcome controller restarts it on every show (so the intro plays each
/// time the window opens); `pulse()` sends a pulse now and restarts the 9 s rhythm from it; `collapse()`
/// (farewell only) folds the mark into its core — the uninstall has succeeded.
@MainActor
final class WelcomeLogoClock: ObservableObject {
    @Published private(set) var start = Date()
    @Published private(set) var trigger: Date?
    @Published private(set) var collapseAt: Date?
    func restart() { start = Date(); trigger = nil; collapseAt = nil }
    func pulse() { trigger = Date() }
    func collapse() { collapseAt = Date() }
}

struct WelcomeLogo: View {
    @ObservedObject var clock: WelcomeLogoClock
    let size: CGFloat
    /// The calmer farewell rhythm of the Uninstall window (see the header).
    var farewell = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let trig = clock.trigger.map { $0.timeIntervalSince(clock.start) }
        let coll = clock.collapseAt.map { $0.timeIntervalSince(clock.start) }
        TimelineView(LogoMotion.Schedule(start: clock.start, trigger: trig, still: reduceMotion,
                                         farewell: farewell, collapse: coll)) { timeline in
            Canvas { ctx, canvasSize in
                let dark = scheme == .dark
                let t = timeline.date.timeIntervalSince(clock.start)
                // Reduce Motion: the still mark (the Uninstall window closes at once on success, no gesture).
                let frame = reduceMotion ? LogoMotion.rest(farewell: farewell)
                    : LogoMotion.frame(t: t, trigger: trig, farewell: farewell,
                                       collapse: coll.map { max(0, t - $0) })
                LogoMotion.draw(frame, in: ctx, size: canvasSize, dark: dark)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Rhemion")
    }
}

/// Geometry, motion and drawing of the mark, in a 1024 frame (centre 512). The same geometry as the app icon
/// and the menu-bar glyph (deploy/icons); the logo keeps the fine ring weights.
enum LogoMotion {
    struct Ring { var r: Double; var w: Double; var op: Double; var hot: Bool }
    struct Frame { var orb: Double; var glow: Double; var rings: [Ring] }

    static let center = 512.0, span = 1024.0

    /// Orb Ø 31%; five rings laid out with clear gaps starting at 3% and growing ×1.10 (icon weights
    /// 3.2 / 2.7 / 2.4 / 2.1 / 2.0 % set the spacing); loudness = r1 / r.
    static let geometry: (orbR: Double, radii: [Double], loud: [Double]) = {
        let s = span, orbR = 0.31 * s / 2
        let layout = [3.2, 2.7, 2.4, 2.1, 2.0].map { $0 / 100 * s }
        var edge = orbR, gap = 0.03 * s, radii: [Double] = []
        for w in layout { edge += gap; radii.append(edge + w / 2); edge += w; gap *= 1.10 }
        return (orbR, radii, radii.map { radii[0] / $0 })
    }()
    static var orbR: Double { geometry.orbR }
    static var radii: [Double] { geometry.radii }
    static var loud: [Double] { geometry.loud }
    /// Fine logo weights: 2% of the frame × loudness.
    static var widths: [Double] { loud.map { 0.02 * span * $0 } }
    /// Base opacity: loudness^1.5, never under 30%.
    static var opacities: [Double] { loud.map { max(0.3, pow($0, 1.5)) } }

    // Timing: intro → first pulse at 3.2 s → a pulse every 9 s; an event pulse restarts the rhythm.
    static let firstPulse = 3.2, period = 9.0, introEnd = 2.1
    // Farewell: a slower breath (12 s), a softer push (× 0.6), quieter rings (× 0.85).
    static let farewellPeriod = 12.0, farewellShift = 0.6, farewellOpacity = 0.85
    // Collapse: the mark folds into its core in 0.9 s.
    static let collapseDur = 0.9
    static func period(farewell: Bool) -> Double { farewell ? farewellPeriod : period }
    // Pulse: the front crosses the mark in 2.1 s; a ring is pushed out by up to 16 units × its loudness.
    static let pulseDur = 2.1, pulseShift = 16.0, pulseSigma = 36.0

    static func rest(farewell: Bool = false) -> Frame {
        let f = Frame(orb: 1, glow: 1, rings: radii.indices.map { i in
            Ring(r: radii[i], w: widths[i], op: i == 4 ? 0 : opacities[i], hot: false)
        })
        return farewell ? quieted(f) : f
    }

    /// Seconds since the current pulse began, or nil during the intro.
    static func pulseTime(t: Double, trigger: Double?, farewell: Bool = false) -> Double? {
        let period = period(farewell: farewell)
        if let trig = trigger, t >= trig { return (t - trig).truncatingRemainder(dividingBy: period) }
        if t < firstPulse { return nil }
        return (t - firstPulse).truncatingRemainder(dividingBy: period)
    }

    /// `collapse`: seconds since `collapse()` was called (nil = no collapse) — applied over whatever the
    /// mark is doing at that moment.
    static func frame(t: Double, trigger: Double?, farewell: Bool = false, collapse: Double? = nil) -> Frame {
        let base: Frame
        if let x = pulseTime(t: t, trigger: trigger, farewell: farewell) {
            base = pulse(x, shift: farewell ? pulseShift * farewellShift : pulseShift)
        } else {
            base = intro(min(t, introEnd))
        }
        let f = farewell ? quieted(base) : base
        guard let elapsed = collapse else { return f }
        return collapsed(f, elapsed: elapsed)
    }

    /// Farewell: the rings at 85% of their opacity.
    private static func quieted(_ f: Frame) -> Frame {
        var f = f
        for i in f.rings.indices { f.rings[i].op *= farewellOpacity }
        return f
    }

    /// The collapse gesture at `elapsed` s: k = smooth(elapsed / 0.9); rings sink to the orb's radius and
    /// fade by (1 − k); the orb and its halo shrink by (1 − k). At k = 1 nothing is left.
    static func collapsed(_ f: Frame, elapsed: Double) -> Frame {
        let k = smooth(elapsed / collapseDur)
        var f = f
        for i in f.rings.indices {
            f.rings[i].r = lerp(f.rings[i].r, orbR, k)
            f.rings[i].op *= 1 - k
        }
        f.orb *= 1 - k
        f.glow *= 1 - k
        return f
    }

    private static func intro(_ t: Double) -> Frame {
        let o = backOut(t / 0.6)
        let rings: [Ring] = radii.indices.map { i in
            guard i < 4 else { return Ring(r: radii[i], w: widths[i], op: 0, hot: false) }
            let k = smooth((t - 0.35 - Double(i) * 0.2) / 0.75)
            return Ring(r: lerp(orbR, radii[i], k), w: widths[i], op: opacities[i] * k, hot: false)
        }
        return Frame(orb: max(0.001, o), glow: clamp(o), rings: rings)
    }

    /// A pressure pulse: compression (out + bright), then rarefaction (slightly in + dim).
    private static func pulseShape(_ x: Double) -> Double { gauss(x) - 0.42 * gauss((x - 1.35) / 0.8) }

    private static func pulse(_ x: Double, shift pulseShift: Double) -> Frame {
        let inner = orbR - 20, outer = radii[4] + 70
        guard x <= pulseDur else { return rest() }
        let front = lerp(inner, outer, x / pulseDur)
        let rings: [Ring] = radii.indices.map { i in
            let s = loud[i] * pulseShape((front - radii[i]) / pulseSigma)
            let b = max(0, s), dim = min(1, max(0, -s))
            let base = opacities[i]
            let shown = i == 4 ? min(1, b * 2.2) : 1
            let op = (i == 4 ? 0.5 * shown : min(1, base + (1 - base) * 0.7 * b)) * (1 - 0.35 * dim)
            return Ring(r: radii[i] + pulseShift * s, w: widths[i], op: op, hot: b > 0.45)
        }
        let kick = gauss((front - orbR) / 42)
        return Frame(orb: 1 + 0.045 * kick, glow: 1 + 0.6 * kick, rings: rings)
    }

    /// Frames only while something moves: during the intro and each pulse (plus a beat to settle); in between,
    /// the timeline jumps straight to the next pulse.
    struct Schedule: TimelineSchedule {
        let start: Date
        let trigger: Double?
        let still: Bool
        var farewell = false
        /// Seconds since `start` at which `collapse()` was called, if it was.
        var collapse: Double? = nil

        func entries(from date: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            var next: Date? = date
            return AnyIterator {
                guard let current = next else { return nil }
                if still { next = nil; return current }
                let t = current.timeIntervalSince(start)
                // Collapsed: the last frame (nothing left) stays; the timeline stops.
                if let c = collapse, t > c + collapseDur + 0.1 { next = nil; return current }
                next = start.addingTimeInterval(active(t) ? t + 1.0 / 60 : nextActive(after: t))
                return current
            }
        }

        private var period: Double { LogoMotion.period(farewell: farewell) }

        private func active(_ t: Double) -> Bool {
            if let c = collapse, t >= c { return true }       // collapsing (the end is handled above)
            if t <= introEnd + 0.1 { return true }
            guard let x = LogoMotion.pulseTime(t: t, trigger: trigger, farewell: farewell) else { return false }
            return x <= pulseDur + 0.1
        }

        private func nextActive(after t: Double) -> Double {
            var candidates: [Double] = []
            if let trig = trigger {
                if t < trig { candidates.append(trig) }
                else { candidates.append(trig + period * ((t - trig) / period).rounded(.up)) }
            }
            if trigger == nil || t < trigger! {
                candidates.append(t < firstPulse ? firstPulse
                                  : firstPulse + period * ((t - firstPulse) / period).rounded(.up))
            }
            let n = candidates.filter { $0 > t }.min() ?? t + period
            return n
        }
    }

    // MARK: drawing

    private struct Palette { let ring: Color, hot: Color, glow: Color, glowOp: Double, orb: [Color], opScale: Double }
    private static let darkPalette = Palette(
        ring: Color(rhemionHex: 0xEBB244), hot: Color(rhemionHex: 0xFFE2A0),
        glow: Color(rhemionHex: 0xF0B84E), glowOp: 0.55,
        orb: [Color(rhemionHex: 0xF7C862), Color(rhemionHex: 0xE29F2E)], opScale: 1)
    private static let lightPalette = Palette(
        ring: Color(rhemionHex: 0xDD9F2A), hot: Color(rhemionHex: 0xF2B340),
        glow: Color(rhemionHex: 0xE9B24A), glowOp: 0.38,
        orb: [Color(rhemionHex: 0xF4BE55), Color(rhemionHex: 0xDB9526)], opScale: 0.9)

    static func draw(_ f: Frame, in ctx: GraphicsContext, size: CGSize, dark: Bool) {
        let s = min(size.width, size.height) / span
        let c = CGPoint(x: center * s, y: center * s)
        let p = dark ? darkPalette : lightPalette
        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

        for ring in f.rings where ring.op > 0.002 {
            ctx.stroke(circle(ring.r * s), with: .color((ring.hot ? p.hot : p.ring).opacity(clamp(ring.op * p.opScale))),
                       style: StrokeStyle(lineWidth: ring.w * s))
        }

        // the orb's soft halo: the double is alive (no glow on the rings)
        let haloR = 330 * s
        ctx.drawLayer { layer in
            layer.opacity = clamp(0.8 * f.glow)
            layer.fill(circle(haloR), with: .radialGradient(
                Gradient(stops: [.init(color: p.glow.opacity(p.glowOp), location: 0),
                                 .init(color: p.glow.opacity(p.glowOp * 0.3), location: 0.45),
                                 .init(color: p.glow.opacity(0), location: 1)]),
                center: c, startRadius: 0, endRadius: haloR))
        }

        let r = orbR * f.orb * s
        ctx.fill(circle(r), with: .linearGradient(Gradient(colors: p.orb),
                                                  startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
    }

    // MARK: easing

    private static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func smooth(_ x: Double) -> Double { let x = clamp(x); return x * x * (3 - 2 * x) }
    private static func gauss(_ x: Double) -> Double { exp(-x * x) }
    private static func backOut(_ x: Double) -> Double {
        let x = clamp(x), c = 1.5
        return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
    }
}
