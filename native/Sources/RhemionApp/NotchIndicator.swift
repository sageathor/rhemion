// NotchIndicator — the renderer (IndicatorView) draws
// the plate + breathing orb + halo + spinner dots + result glyph, with fixed geometry/colors/animation
// constants. NotchIndicator owns the window + style:
//   .notch    — plate the exact size of the notch (black-on-black, invisible) that slides RIGHT by
//               `ext` px, the orb riding in that right ear. Default on notched Macs.
//   .floating — a rounded pill just below the menu bar (displays without a notch / explicit choice).

import AppKit
import QuartzCore

// Geometry constants.
private enum GK {
    static let ext: CGFloat = 48, rb: CGFloat = 12, ri: CGFloat = 4, slideT: Double = 0.18, spinR: CGFloat = 9
    // Silence countdown ring: faint full track + bright depleting arc, on the orb.
    static let ringR: CGFloat = 7.5, ringW: CGFloat = 1.6, cdTrackW: CGFloat = 1.4, cdTrackA: CGFloat = 0.16
}
// Brand amber (matches the app icon's orb + the gold accent).
// HI = bright inner highlight (#F3C868), LO = deeper gold for the body + glow halo (#E0A42E).
private let ACCENT_HI: (CGFloat, CGFloat, CGFloat) = (0.953, 0.784, 0.408)
private let ACCENT_LO: (CGFloat, CGFloat, CGFloat) = (0.878, 0.643, 0.180)
// Pale cream sheen for the orb's matte highlight (same diffuse-light idea as the app icon).
private let SHEEN: (CGFloat, CGFloat, CGFloat) = (1.0, 0.94, 0.78)
private let REDC: (CGFloat, CGFloat, CGFloat) = (0.92, 0.36, 0.36)
private let M_BASE: CGFloat = 2.5, M_GROW: CGFloat = 6.0
private let RENDER_INTERVAL = 0.06, ANIM_INTERVAL = 0.02, SPIN_INTERVAL = 0.03
private let DOTS_N = 9, DOT_FADE: CGFloat = 270

private func cg(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
    CGColor(red: c.0, green: c.1, blue: c.2, alpha: a)
}

@MainActor
final class NotchIndicator {
    enum Style { case notch, floating }

    private(set) var style: Style
    private var window: NSWindow?
    private var view: IndicatorView?

    init() { style = NotchIndicator.detectDefaultStyle() }

    func setStyle(_ newStyle: Style) {
        guard newStyle != style else { return }
        style = newStyle
        view?.stopAll()
        window?.orderOut(nil); window = nil; view = nil
    }

    func recording() { ensureWindow(); window?.orderFrontRegardless(); view?.recording() }
    func onLevel(_ rms: Double) { view?.onLevel(rms) }
    func processing() { view?.hold() }   // release freezes the orb; the spinner blooms after a grace
    func done() { view?.done() }
    func error() { ensureWindow(); window?.orderFrontRegardless(); view?.error() }
    func hide() { view?.hide() }
    /// Hands-free silence countdown: `remaining` shrinks 1→0; the ring depletes. Speech → cancelCountdown().
    func countdown(_ remaining: Double) { ensureWindow(); window?.orderFrontRegardless(); view?.countdown(CGFloat(remaining)) }
    func cancelCountdown() { view?.cancelCountdown() }

    /// Speech-model download in progress: a calm amber orb with a ring that FILLS as `fraction` grows 0→1
    /// (not the red error cross — this is "not ready yet", not a failure). Shown from the moment Download is
    /// pressed so the user links the click to the orb; also on a gated PTT press while downloading. The window
    /// stays click-through (never eats notch/menu-bar clicks); the words live on the menu-bar item's tooltip.
    func downloadProgress(_ fraction: Double) {
        ensureWindow(); window?.orderFrontRegardless(); view?.downloadProgress(CGFloat(max(0, min(1, fraction))))
    }
    /// Model not ready and not downloading (absent, or a download that was interrupted/canceled): a brief
    /// amber down-arrow cue on a calm orb, then it retracts. Used on a gated PTT press with no model.
    func downloadHint() {
        ensureWindow(); window?.orderFrontRegardless(); view?.downloadHint()
    }
    /// Speech model on disk but still being prepared (first load/compile): the spinner dots, held until the
    /// model is ready (endModelCue) instead of a download ring frozen at 100%.
    func preparing() { ensureWindow(); window?.orderFrontRegardless(); view?.preparing() }
    /// End a download/not-ready cue if that's what's showing (e.g. the model just became ready), WITHOUT
    /// disturbing an active recording/processing indicator.
    func endModelCue() { view?.endModelCue() }

    private func ensureWindow() {
        guard window == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let frame: NSRect
        let v: IndicatorView
        if style == .notch, let geo = NotchIndicator.notchGeometry(screen) {
            let expanded = geo.width + GK.ext
            frame = NSRect(x: screen.frame.minX + geo.left, y: screen.frame.maxY - geo.height,
                           width: expanded, height: geo.height)
            v = IndicatorView(frame: NSRect(origin: .zero, size: frame.size),
                              style: .notch, plateH: geo.height, retractedW: geo.width, expandedW: expanded)
        } else {
            let w: CGFloat = 96, h: CGFloat = 28
            frame = NSRect(x: screen.frame.midX - w / 2, y: screen.visibleFrame.maxY - h, width: w, height: h)
            v = IndicatorView(frame: NSRect(origin: .zero, size: frame.size),
                              style: .floating, plateH: h, retractedW: w, expandedW: w)
        }

        let panel = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        v.onRetracted = { [weak self] in self?.window?.orderOut(nil) }
        panel.contentView = v
        window = panel
        view = v
    }

    // MARK: - notch geometry

    private struct NotchGeo { let left: CGFloat; let width: CGFloat; let height: CGFloat }

    private static func notchGeometry(_ screen: NSScreen) -> NotchGeo? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard width > 20 else { return nil }
        return NotchGeo(left: left.maxX - screen.frame.minX, width: width, height: left.height)
    }

    private static func detectDefaultStyle() -> Style {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .floating }
        return notchGeometry(screen) != nil ? .notch : .floating
    }
}

// MARK: - Renderer (immediate-mode)

@MainActor
private final class IndicatorView: NSView {
    enum Phase { case hidden, recording, holding, processing, finishing, countdown, download, hint, preparing }

    private let style: NotchIndicator.Style
    private let plateH: CGFloat
    private let retractedW: CGFloat
    private let expandedW: CGFloat

    private var plateW: CGFloat
    private var phase: Phase = .hidden
    private var meterLevel: CGFloat = 0, meterTarget: CGFloat = 0, meterPhase: CGFloat = 0, meterPulse: CGFloat = 0
    private var spinBase: CGFloat = 0
    private var dotsAlpha: CGFloat = 0, dotsScale: CGFloat = 1
    private var glyph: (kind: String, progress: CGFloat, alpha: CGFloat)? = nil
    private var ringFrac: CGFloat = 0

    private var meterTimer: Timer?, animTimer: Timer?, spinTimer: Timer?, graceTimer: Timer?, procTimer: Timer?
    var onRetracted: (() -> Void)?

    // Flipped so top-left / y-down math applies directly.
    override var isFlipped: Bool { true }

    init(frame: NSRect, style: NotchIndicator.Style, plateH: CGFloat, retractedW: CGFloat, expandedW: CGFloat) {
        self.style = style; self.plateH = plateH; self.retractedW = retractedW; self.expandedW = expandedW
        self.plateW = retractedW
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError() }

    // Render at the screen's backing scale so the orb/rings are crisp (vector-smooth) rather than
    // pixelated — a layer-backed view otherwise keeps contentsScale 1.0 on Retina until told otherwise.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    private var orbCx: CGFloat { style == .notch ? plateW - GK.ext / 2 : plateW / 2 }
    private var orbCy: CGFloat { plateH / 2 - 2 }

    // MARK: state machine

    func recording() {
        stopAll()
        phase = .recording
        plateW = retractedW
        glyph = nil; dotsAlpha = 0
        if style == .notch { slide(to: expandedW) }
        startMeter()
        needsDisplay = true
    }

    func onLevel(_ rms: Double) { meterTarget = max(0, min(1, CGFloat(rms))) }

    /// Silence countdown (hands-free): the orb settles into a calm dot and a ring around it depletes as
    /// `remaining` shrinks 1→0.
    func countdown(_ remaining: CGFloat) {
        if phase != .countdown { phase = .countdown; stopMeter() }   // freeze the meter
        ringFrac = max(0, min(1, remaining))
        needsDisplay = true
    }

    /// Speech resumed during the countdown: drop the ring and let the orb breathe again.
    func cancelCountdown() {
        guard phase == .countdown else { return }
        phase = .recording
        startMeter()
        needsDisplay = true
    }

    /// Speech-model download progress: a calm orb with a ring that FILLS (0→1) as the model downloads.
    /// Idempotent — the first call sets the phase (and slides the orb out on notched Macs); later calls just
    /// advance the fill. Persistent (no auto-hide); the caller ends it via hide() on done/cancel/fail.
    func downloadProgress(_ fraction: CGFloat) {
        if phase != .download {
            stopAll()
            phase = .download
            glyph = nil; dotsAlpha = 0
            if style == .notch { plateW = retractedW; slide(to: expandedW) } else { plateW = retractedW }
        }
        ringFrac = max(0, min(1, fraction))
        needsDisplay = true
    }

    /// Model not ready / not downloading: a brief amber down-arrow on a calm orb (not the red error cross),
    /// then it retracts on its own. Shown on a gated PTT press when there is nothing to fall back to.
    func downloadHint() {
        stopAll()
        phase = .hint
        glyph = ("download", 1, 1)
        if style == .notch { plateW = retractedW; slide(to: expandedW) } else { plateW = retractedW }
        needsDisplay = true
        procTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.phase == .hint else { return }; self.hide() }
        }
    }

    /// Hide ONLY if a download/not-ready cue is on screen — never interrupt a live recording/spinner/countdown.
    func endModelCue() { if phase == .download || phase == .hint || phase == .preparing { hide() } }

    /// Model preparing: the processing spinner, persistent (no safety timeout) until endModelCue().
    func preparing() {
        guard phase != .preparing else { return }
        stopAll()
        phase = .preparing
        glyph = nil
        guard style == .notch else { plateW = retractedW; startSpinner(); return }
        // slide() and the spinner share one animation timer: start the spinner once the plate is out.
        plateW = retractedW
        slide(to: expandedW)
        graceTimer = Timer.scheduledTimer(withTimeInterval: GK.slideT, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.phase == .preparing else { return }; self.startSpinner() }
        }
    }

    func hold() {
        guard phase == .recording || phase == .countdown else { return }   // stop during countdown → spinner
        phase = .holding
        stopMeter()
        // Bloom into the spinner only if recognition outlasts the grace (fast/empty takes resolve first).
        graceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .holding else { return }
                self.processing()
            }
        }
    }

    func processing() {
        stopGrace()
        phase = .processing
        startSpinner()
        procTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in   // safety: never freeze
            MainActor.assumeIsolated {
                guard let self, self.phase == .processing else { return }
                self.hide()
            }
        }
    }

    func done() { finish(kind: "ok") }
    func error() { phase = .finishing; finish(kind: "error") }

    func hide() {
        stopAll()
        phase = .hidden
        onRetracted?()
    }

    func stopAll() {
        [meterTimer, animTimer, spinTimer, graceTimer, procTimer].forEach { $0?.invalidate() }
        meterTimer = nil; animTimer = nil; spinTimer = nil; graceTimer = nil; procTimer = nil
    }
    private func stopMeter() { meterTimer?.invalidate(); meterTimer = nil }
    private func stopGrace() { graceTimer?.invalidate(); graceTimer = nil }

    // MARK: animations

    private func startMeter() {
        stopMeter()
        meterTimer = Timer.scheduledTimer(withTimeInterval: RENDER_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.meterLevel += (self.meterTarget - self.meterLevel) * 0.25
                self.meterPhase += 0.06
                self.meterPulse = 0.5 + 0.5 * sin(self.meterPhase * 3.4)
                self.needsDisplay = true
            }
        }
    }

    private func slide(to target: CGFloat) {
        animTimer?.invalidate()
        let from = plateW, start = CACurrentMediaTime()
        animTimer = Timer.scheduledTimer(withTimeInterval: ANIM_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, (CACurrentMediaTime() - start) / GK.slideT)
                let e = 1 - (1 - p) * (1 - p)
                self.plateW = from + (target - from) * CGFloat(e)
                self.needsDisplay = true
                if p >= 1 { self.animTimer?.invalidate(); self.animTimer = nil }
            }
        }
    }

    private func startSpinner() {
        animTimer?.invalidate(); spinTimer?.invalidate()
        dotsAlpha = 0; dotsScale = 0
        let start = CACurrentMediaTime(), spawn = 0.24
        animTimer = Timer.scheduledTimer(withTimeInterval: ANIM_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, (CACurrentMediaTime() - start) / spawn), e = 1 - (1 - p) * (1 - p)
                self.spinBase = (self.spinBase + 11).truncatingRemainder(dividingBy: 360)
                self.dotsAlpha = CGFloat(e); self.dotsScale = CGFloat(e)
                self.needsDisplay = true
                if p >= 1 {
                    self.animTimer?.invalidate(); self.animTimer = nil
                    self.spinTimer = Timer.scheduledTimer(withTimeInterval: SPIN_INTERVAL, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.spinBase = (self.spinBase + 11).truncatingRemainder(dividingBy: 360)
                            self.dotsAlpha = 1; self.dotsScale = 1
                            self.needsDisplay = true
                        }
                    }
                }
            }
        }
    }

    private func finish(kind: String) {
        stopAll()
        phase = .finishing
        let silent = (kind == "ok")   // dictation success is silent (no glyph) — the inserted text is the confirmation
        let FADE = 0.16, GSTART = 0.09, GDRAW = 0.22, HOLD = 0.7, RETRACT = 0.36
        let GEND = GSTART + GDRAW
        let RSTART = silent ? FADE : (GEND + HOLD)
        let start = CACurrentMediaTime()
        var fromW: CGFloat? = nil
        animTimer = Timer.scheduledTimer(withTimeInterval: ANIM_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime() - start
                if t <= FADE { let p = t / FADE, e = 1 - (1 - p) * (1 - p); self.dotsAlpha = CGFloat(1 - e) }
                if !silent, t >= GSTART, t <= GEND {
                    let p = min(1, (t - GSTART) / GDRAW)
                    self.glyph = (kind, CGFloat(1 - (1 - p) * (1 - p)), 1)
                }
                if t > RSTART {
                    let p = min(1, (t - RSTART) / RETRACT), e = p * p * (3 - 2 * p)   // smoothstep
                    if fromW == nil { fromW = self.plateW }
                    if self.style == .notch { self.plateW = fromW! + (self.retractedW - fromW!) * CGFloat(e) }
                    if !silent { self.glyph = (kind, 1, CGFloat(1 - e)) }
                    if p >= 1 { self.animTimer?.invalidate(); self.animTimer = nil; self.hide() }
                }
                self.needsDisplay = true
            }
        }
    }

    // MARK: drawing (immediate mode)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Plate (black).
        ctx.addPath(platePath(plateW, plateH))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()

        switch phase {
        case .recording, .holding: drawOrb(ctx)
        case .processing, .preparing: drawDots(ctx)
        case .countdown: drawCountdownOrb(ctx); drawRing(ctx)
        case .download: drawCountdownOrb(ctx); drawRing(ctx)   // calm orb + a ring that FILLS with progress
        case .hint: drawCountdownOrb(ctx); if let g = glyph { drawGlyph(ctx, g) }
        case .finishing:
            if dotsAlpha > 0.001 { drawDots(ctx) }
            if let g = glyph { drawGlyph(ctx, g) }
        case .hidden: break
        }
    }

    // Countdown: a calm static orb (crisp, faint glow) and a depleting ring around it.
    private func drawCountdownOrb(_ ctx: CGContext) {
        let orbR = M_BASE + M_GROW * 0.18
        radial(ctx, cx: orbCx, cy: orbCy, r: orbR * 1.8,
               inner: cg(ACCENT_LO, 0.24), outer: cg(ACCENT_LO, 0), offset: 0)
        radial(ctx, cx: orbCx, cy: orbCy, r: orbR, inner: cg(ACCENT_HI), outer: cg(ACCENT_LO), offset: -0.2)
        drawSheen(ctx, r: orbR)
    }

    private func drawRing(_ ctx: CGContext) {
        // Faint full track behind the arc.
        ctx.setStrokeColor(cg(ACCENT_LO, GK.cdTrackA))
        ctx.setLineWidth(GK.cdTrackW)
        ctx.addEllipse(in: CGRect(x: orbCx - GK.ringR, y: orbCy - GK.ringR, width: GK.ringR * 2, height: GK.ringR * 2))
        ctx.strokePath()
        // Bright arc that depletes from a full circle to nothing as ringFrac → 0, starting at the top.
        guard ringFrac > 0.001 else { return }
        ctx.setStrokeColor(cg(ACCENT_LO))
        ctx.setLineWidth(GK.ringW)
        ctx.setLineCap(.round)
        let start: CGFloat = -.pi / 2
        ctx.addArc(center: CGPoint(x: orbCx, y: orbCy), radius: GK.ringR,
                   startAngle: start, endAngle: start + ringFrac * 2 * .pi, clockwise: false)
        ctx.strokePath()
    }

    private func drawOrb(_ ctx: CGContext) {
        let orbR = M_BASE + M_GROW * meterLevel + 0.75 * meterPulse
        // Glow halo — ALWAYS present (a soft amber contour even at rest), and brighter + wider as the orb
        // grows on loud speech. Fades to nothing, no hard ring, sits behind the crisp orb.
        let glow = 0.26 + 0.26 * meterLevel + 0.12 * meterPulse
        radial(ctx, cx: orbCx, cy: orbCy, r: orbR * (1.8 + 0.55 * meterLevel) + 1.5 * meterPulse,
               inner: cg(ACCENT_LO, min(glow, 0.62)), outer: cg(ACCENT_LO, 0), offset: 0)
        // Orb body: a CRISP radial sphere (HI -> LO). The backing scale is pinned to the screen
        // (viewDidChangeBackingProperties), so the edge renders smooth, not pixelated.
        radial(ctx, cx: orbCx, cy: orbCy, r: max(orbR, 0.5),
               inner: cg(ACCENT_HI), outer: cg(ACCENT_LO), offset: -0.2)
        drawSheen(ctx, r: orbR)
    }

    /// A soft pale diffuse highlight on the top-left of the sphere (matte look, like the app icon),
    /// clipped to the orb so it never spills onto the plate.
    private func drawSheen(_ ctx: CGContext, r: CGFloat) {
        guard r > 1 else { return }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: orbCx - r, y: orbCy - r, width: r * 2, height: r * 2))
        ctx.clip()
        radial(ctx, cx: orbCx - r * 0.26, cy: orbCy - r * 0.30, r: r * 0.95,
               inner: cg(SHEEN, 0.32), outer: cg(SHEEN, 0), offset: 0)
        ctx.restoreGState()
    }

    private func radial(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat,
                        inner: CGColor, outer: CGColor, offset: CGFloat) {
        guard r > 0.5,
              let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [inner, outer] as CFArray, locations: [0, 1]) else { return }
        let start = CGPoint(x: cx + offset * r, y: cy + offset * r)
        ctx.saveGState()
        ctx.drawRadialGradient(grad, startCenter: start, startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [])
        ctx.restoreGState()
    }

    private func drawDots(_ ctx: CGContext) {
        let rr = GK.spinR * dotsScale
        for i in 0..<DOTS_N {
            let a = CGFloat(i) * (360 / CGFloat(DOTS_N))
            let d = (spinBase - a).truncatingRemainder(dividingBy: 360)
            let dd = d < 0 ? d + 360 : d
            let c = pow(1 - min(1, dd / DOT_FADE), 2.2)
            let x = orbCx + rr * cos(a * .pi / 180)
            let y = orbCy - rr * sin(a * .pi / 180)
            let radius = 2.0 + 0.7 * c
            ctx.setFillColor(cg(ACCENT_LO, (0.08 + 0.92 * c) * dotsAlpha))
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private func drawGlyph(_ ctx: CGContext, _ g: (kind: String, progress: CGFloat, alpha: CGFloat)) {
        let cx = orbCx, cy = orbCy, p = g.progress
        let col = (g.kind == "error") ? REDC : ACCENT_LO
        ctx.setStrokeColor(cg(col, g.alpha))
        ctx.setLineWidth(2.3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if g.kind == "error" {
            let a0 = CGPoint(x: cx - 4, y: cy - 4), a1 = CGPoint(x: cx + 4, y: cy + 4)
            let b0 = CGPoint(x: cx + 4, y: cy - 4), b1 = CGPoint(x: cx - 4, y: cy + 4)
            ctx.move(to: a0); ctx.addLine(to: CGPoint(x: a0.x + (a1.x - a0.x) * p, y: a0.y + (a1.y - a0.y) * p))
            ctx.move(to: b0); ctx.addLine(to: CGPoint(x: b0.x + (b1.x - b0.x) * p, y: b0.y + (b1.y - b0.y) * p))
            ctx.strokePath()
        } else if g.kind == "download" {
            // Downward arrow (amber, NOT red): shaft grows with `p`, then a chevron head. Reads as
            // "download needed / not ready yet", distinct from the error cross.
            let topY = cy - 4.0, botY = cy + 4.0
            ctx.move(to: CGPoint(x: cx, y: topY))
            ctx.addLine(to: CGPoint(x: cx, y: topY + (botY - topY) * p))
            ctx.move(to: CGPoint(x: cx - 3.3, y: botY - 3.3))
            ctx.addLine(to: CGPoint(x: cx, y: botY))
            ctx.addLine(to: CGPoint(x: cx + 3.3, y: botY - 3.3))
            ctx.strokePath()
        }
    }

    // plateCoords(W,H) as a CGPath (rb=12 top corners, ri=4 top-right ear).
    private func platePath(_ W: CGFloat, _ H: CGFloat) -> CGPath {
        let ri = GK.ri, rb = GK.rb
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: W, y: 0))
        appendArc(p, cx: W, cy: ri, r: ri, a0: -.pi / 2, a1: -.pi)
        p.addLine(to: CGPoint(x: W - ri, y: H - rb))
        appendArc(p, cx: W - ri - rb, cy: H - rb, r: rb, a0: 0, a1: .pi / 2)
        p.addLine(to: CGPoint(x: rb, y: H))
        appendArc(p, cx: rb, cy: H - rb, r: rb, a0: .pi / 2, a1: .pi)
        p.closeSubpath()
        return p
    }

    private func appendArc(_ path: CGMutablePath, cx: CGFloat, cy: CGFloat, r: CGFloat, a0: CGFloat, a1: CGFloat) {
        let n = 6
        for i in 0...n {
            let a = a0 + (a1 - a0) * (CGFloat(i) / CGFloat(n))
            path.addLine(to: CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
        }
    }
}
