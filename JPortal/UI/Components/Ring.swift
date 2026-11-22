import SwiftUI

private func ringRadius(_ rect: CGRect, stroke: CGFloat, amplitude: Double) -> CGFloat {
    min(rect.width, rect.height) / 2 - stroke / 2 - stroke * 0.24 * amplitude
}

/// the progress arc, wavy while you're safely above target and flat once you're below it
struct WavyArc: Shape {
    var fraction: Double
    var amplitude: Double
    var phase: Double
    let stroke: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(fraction, amplitude) }
        set { fraction = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0.001 else { return p }
        let waveAmp = stroke * 0.24 * amplitude
        let r = ringRadius(rect, stroke: stroke, amplitude: amplitude)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let start = -Double.pi / 2
        let sweep = min(fraction, 1) * 2 * .pi
        // wave count grows with the ring so bumps keep a constant size
        let waves = max(8, (2 * .pi * r) / (stroke * 4.6))
        let steps = max(24, Int(min(fraction, 1) * waves * 16))
        for i in 0...steps {
            let a = start + sweep * Double(i) / Double(steps)
            // taper the wave to zero at both ends so caps stay round and centred
            let edge = min(1, Double(min(i, steps - i)) / (Double(steps) * 0.08 + 1))
            let rr = r + waveAmp * edge * sin(waves * (a - start) + phase)
            let pt = CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// the rest of the circle, flat, with a gap at each end of the arc
struct TrackArc: Shape {
    var fraction: Double
    var amplitude: Double
    let stroke: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(fraction, amplitude) }
        set { fraction = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction < 0.999 else { return p }
        let r = ringRadius(rect, stroke: stroke, amplitude: amplitude)
        let gap = min(Double(stroke) * 1.6 / Double(r), 0.5)
        let start = -Double.pi / 2
        let sweep = max(0, fraction) * 2 * .pi
        let from = start + sweep + (fraction > 0.001 ? gap : 0)
        let to = start + 2 * .pi - (fraction > 0.001 ? gap : 0)
        guard to > from else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        return p
    }
}

/// jportal's attendance ring, grown up. the shape says it before the number does:
/// wavy above target, flat below. with shortfall, a dot on the track marks the target you're short of.
struct AttendanceRing<Content: View>: View {
    let percent: Double
    let target: Int
    var size: CGFloat = 56
    var stroke: CGFloat = 6
    var shortfall = false
    var animate = true
    @ViewBuilder var content: () -> Content

    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    @State private var amp: Double = 0

    private var safe: Bool { percent >= Double(target) }

    private var color: Color {
        if safe { return p.primary }
        if percent >= Double(target - 10) { return p.warn }
        return p.error
    }

    var body: some View {
        let moving = animate && safe && !reduceMotion
        ZStack {
            TrackArc(fraction: shown, amplitude: amp, stroke: stroke)
                .stroke(p.onSurfaceVariant.opacity(0.25), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { tl in
                let phase = moving ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) / 4.2 * 2 * .pi : 0
                WavyArc(fraction: shown, amplitude: amp, phase: phase, stroke: stroke)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            }
            marker
            content()
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .frame(width: size, height: size)
        .onAppear {
            amp = safe ? 1 : 0
            withAnimation(.spring(response: 1.1, dampingFraction: 0.8)) { shown = min(max(percent, 0), 100) / 100 }
        }
        .onChange(of: percent) { _, v in
            withAnimation(.spring(response: 1.1, dampingFraction: 0.8)) { shown = min(max(v, 0), 100) / 100 }
        }
        .onChange(of: safe) { _, s in
            withAnimation(.easeInOut(duration: 0.6)) { amp = s ? 1 : 0 }
        }
    }

    /// a dot on the track at the target you're short of, or a notch on the big rings
    @ViewBuilder private var marker: some View {
        let t = Double(target) / 100
        let angle = -Double.pi / 2 + t * 2 * .pi
        GeometryReader { g in
            let rect = CGRect(origin: .zero, size: g.size)
            let r = ringRadius(rect, stroke: stroke, amplitude: amp)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            if shortfall && shown > 0.001 && t > shown {
                Circle().fill(p.error)
                    .frame(width: stroke * 0.6, height: stroke * 0.6)
                    .position(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
            } else if !shortfall && stroke >= 10 && t > 0.01 && t < 0.99 && t > shown + 0.02 {
                Path { path in
                    path.move(to: CGPoint(x: c.x + (r - stroke * 0.15) * cos(angle), y: c.y + (r - stroke * 0.15) * sin(angle)))
                    path.addLine(to: CGPoint(x: c.x + (r + stroke * 0.15) * cos(angle), y: c.y + (r + stroke * 0.15) * sin(angle)))
                }
                .stroke(p.onSurfaceVariant.opacity(0.7), style: StrokeStyle(lineWidth: stroke * 0.35, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// stand-in for m3 expressive's loading indicator: a scalloped blob that breathes between 5 and 8 lobes while it spins
struct LoadingBlob: View {
    var size: CGFloat = 48
    @Environment(\.palette) private var p

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let spin = t.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360
            let phase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
            let morph = 0.5 - 0.5 * cos(phase * 2 * .pi)
            Canvas { ctx, sz in
                let r = min(sz.width, sz.height) / 2 * 0.82
                let lobes = 5 + 3 * morph
                let depth = 0.10 + 0.06 * (1 - morph)
                var path = Path()
                for i in 0...120 {
                    let a = 2 * Double.pi * Double(i) / 120
                    let rr = r * (1 - depth + depth * cos(lobes * a))
                    let pt = CGPoint(x: sz.width / 2 + rr * cos(a), y: sz.height / 2 + rr * sin(a))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(p.primary))
            }
            .rotationEffect(.degrees(spin))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }
}
