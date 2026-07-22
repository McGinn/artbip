// artbip app icon — "Bold sun" (option E, chosen 2026-07-16).
// Run: swift scripts/make_icon.swift <out.png>   (use scripts/make_icon.sh)
//
// A vermilion sun over tapered cobalt waves, in a mitred gilded frame on a
// spotlit gallery wall. Craft rules the design obeys: ONE light source (top
// spotlight — wall pool, frame rim light, lit canvas top, hanging shadows);
// materials over flat gradients (gradient-shaded moulding bands with gilding
// colour temperature, gesso grain, impasto); complementary pop (vermilion vs
// cobalt); legible from 16 px (gold ring, blue field, orange dot).
// Rendered 2048 supersampled, downsampled to 1024.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Deterministic texture RNG — the icon must render identically every build.
struct Rand {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10000) / 10000
    }
    mutating func in_(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

// MARK: - Painterly helpers

/// Stroke a polyline with tapering width — brush pressure.
func taperedStroke(_ ctx: inout GraphicsContext, _ pts: [CGPoint], color: Color,
                   w0: CGFloat, w1: CGFloat) {
    guard pts.count > 1 else { return }
    for i in 0..<(pts.count - 1) {
        let t = CGFloat(i) / CGFloat(pts.count - 1)
        var seg = Path()
        seg.move(to: pts[i]); seg.addLine(to: pts[i + 1])
        ctx.stroke(seg, with: .color(color),
                   style: StrokeStyle(lineWidth: w0 + (w1 - w0) * t, lineCap: .round))
    }
}

func cubicPoints(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, n: Int = 60) -> [CGPoint] {
    (0...n).map { i in
        let t = CGFloat(i) / CGFloat(n), u = 1 - t
        return CGPoint(
            x: u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p1.x,
            y: u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p1.y)
    }
}

func impasto(_ ctx: inout GraphicsContext, _ size: CGSize, seed: UInt64, count: Int = 60) {
    var rng = Rand(seed)
    for _ in 0..<count {
        let x = rng.in_(0, size.width), y = rng.in_(0, size.height)
        let len = rng.in_(size.width * 0.03, size.width * 0.09)
        let light = rng.next() > 0.45
        var p = Path()
        p.move(to: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: x + len, y: y + rng.in_(-len * 0.08, len * 0.08)))
        ctx.stroke(p, with: .color(light ? Color.white.opacity(rng.in_(0.04, 0.08))
                                         : Color.black.opacity(rng.in_(0.05, 0.09))),
                   style: StrokeStyle(lineWidth: rng.in_(size.width * 0.006, size.width * 0.011), lineCap: .round))
    }
}

// MARK: - Gilded mitred frame, gradient-shaded moulding

enum Side: CaseIterable { case top, right, bottom, left }

struct MitredFrame: View {
    var frameW: CGFloat

    // (fraction of frameW, luminance, curvature: +1 convex, -1 concave, 0 flat)
    let profile: [(CGFloat, CGFloat, CGFloat)] = [
        (0.09, 0.45, 0),    // outer edge
        (0.16, 1.10, 1),    // outer ovolo
        (0.29, 0.88, -1),   // main hollow
        (0.11, 0.54, -1),   // scotia recess
        (0.13, 1.24, 1),    // gilt fillet
        (0.12, 0.72, 0),    // frieze
        (0.10, 0.42, 0),    // sight edge
    ]
    let sideLight: [Side: CGFloat] = [.top: 1.28, .left: 0.98, .right: 0.85, .bottom: 0.60]

    // Gilding with colour temperature: highlights pale and cool, shadows brown.
    func gold(_ f: CGFloat) -> Color {
        let hi = (r: 0.995, g: 0.90, b: 0.62)
        let mid = (r: 0.84, g: 0.655, b: 0.32)
        let lo = (r: 0.42, g: 0.28, b: 0.10)
        let t = min(max((f - 0.4) / 1.1, 0), 1)
        if t > 0.5 {
            let u = (t - 0.5) * 2
            return Color(red: mid.r + (hi.r - mid.r) * u, green: mid.g + (hi.g - mid.g) * u, blue: mid.b + (hi.b - mid.b) * u)
        } else {
            let u = t * 2
            return Color(red: lo.r + (mid.r - lo.r) * u, green: lo.g + (mid.g - lo.g) * u, blue: lo.b + (mid.b - lo.b) * u)
        }
    }

    func band(_ side: Side, _ o1: CGFloat, _ o2: CGFloat, _ size: CGSize) -> Path {
        let W = size.width, H = size.height
        var p = Path()
        switch side {
        case .top:
            p.move(to: CGPoint(x: o1, y: o1)); p.addLine(to: CGPoint(x: W - o1, y: o1))
            p.addLine(to: CGPoint(x: W - o2, y: o2)); p.addLine(to: CGPoint(x: o2, y: o2))
        case .bottom:
            p.move(to: CGPoint(x: o1, y: H - o1)); p.addLine(to: CGPoint(x: W - o1, y: H - o1))
            p.addLine(to: CGPoint(x: W - o2, y: H - o2)); p.addLine(to: CGPoint(x: o2, y: H - o2))
        case .left:
            p.move(to: CGPoint(x: o1, y: o1)); p.addLine(to: CGPoint(x: o2, y: o2))
            p.addLine(to: CGPoint(x: o2, y: H - o2)); p.addLine(to: CGPoint(x: o1, y: H - o1))
        case .right:
            p.move(to: CGPoint(x: W - o1, y: o1)); p.addLine(to: CGPoint(x: W - o2, y: o2))
            p.addLine(to: CGPoint(x: W - o2, y: H - o2)); p.addLine(to: CGPoint(x: W - o1, y: H - o1))
        }
        p.closeSubpath()
        return p
    }

    func bandGradient(_ side: Side, _ o1: CGFloat, _ o2: CGFloat, _ size: CGSize,
                      lum: CGFloat, curve: CGFloat) -> GraphicsContext.Shading {
        let light = sideLight[side] ?? 1
        let spread: CGFloat = curve == 0 ? 0.06 : 0.22
        let f0 = lum * light * (1 + spread * (curve >= 0 ? 1 : -1))
        let f1 = lum * light * (1 - spread * (curve >= 0 ? 1 : -1))
        let g = Gradient(colors: [gold(f0), gold(f1)])
        let W = size.width, H = size.height
        switch side {
        case .top: return .linearGradient(g, startPoint: CGPoint(x: 0, y: o1), endPoint: CGPoint(x: 0, y: o2))
        case .bottom: return .linearGradient(g, startPoint: CGPoint(x: 0, y: H - o1), endPoint: CGPoint(x: 0, y: H - o2))
        case .left: return .linearGradient(g, startPoint: CGPoint(x: o1, y: 0), endPoint: CGPoint(x: o2, y: 0))
        case .right: return .linearGradient(g, startPoint: CGPoint(x: W - o1, y: 0), endPoint: CGPoint(x: W - o2, y: 0))
        }
    }

    var body: some View {
        Canvas { context, size in
            var ctx = context
            let W = size.width, H = size.height
            var o: CGFloat = 0
            for (frac, lum, curve) in profile {
                let bw = frac * frameW
                for side in Side.allCases {
                    ctx.fill(band(side, o, o + bw, size),
                             with: bandGradient(side, o, o + bw, size, lum: lum, curve: curve))
                }
                o += bw
            }

            // Gesso grain along the rails
            var rng = Rand(61)
            for _ in 0..<26 {
                let horiz = rng.next() > 0.5
                let along = rng.in_(frameW * 1.3, (horiz ? W : H) - frameW * 1.3)
                let across = rng.in_(frameW * 0.12, frameW * 0.88)
                let len = rng.in_(frameW * 0.5, frameW * 1.6)
                let bottomOrRight = rng.next() > 0.55
                var p = Path()
                if horiz {
                    let y = bottomOrRight ? H - across : across
                    p.move(to: CGPoint(x: along, y: y)); p.addLine(to: CGPoint(x: along + len, y: y))
                } else {
                    let x = bottomOrRight ? W - across : across
                    p.move(to: CGPoint(x: x, y: along)); p.addLine(to: CGPoint(x: x, y: along + len))
                }
                let light = rng.next() > 0.5
                ctx.stroke(p, with: .color(light ? Color.white.opacity(rng.in_(0.03, 0.07))
                                                 : Color.black.opacity(rng.in_(0.04, 0.09))),
                           style: StrokeStyle(lineWidth: rng.in_(1.0, 2.2), lineCap: .round))
            }

            // Mitre seams
            for (x0, y0, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (1.0, 0.0, -1.0, 1.0),
                                     (0.0, 1.0, 1.0, -1.0), (1.0, 1.0, -1.0, -1.0)] {
                var p = Path()
                let sx = CGFloat(x0) * W, sy = CGFloat(y0) * H
                p.move(to: CGPoint(x: sx, y: sy))
                p.addLine(to: CGPoint(x: sx + CGFloat(dx) * frameW, y: sy + CGFloat(dy) * frameW))
                ctx.stroke(p, with: .color(Color.black.opacity(0.20)),
                           style: StrokeStyle(lineWidth: frameW * 0.024))
            }

            // Rim light on the top outer edge — the spotlight strikes here
            var rim = Path()
            rim.move(to: CGPoint(x: frameW * 0.07, y: frameW * 0.05))
            rim.addLine(to: CGPoint(x: W - frameW * 0.07, y: frameW * 0.05))
            ctx.stroke(rim, with: .color(Color(red: 1.0, green: 0.97, blue: 0.87).opacity(0.95)),
                       style: StrokeStyle(lineWidth: frameW * 0.055, lineCap: .round))
        }
    }
}

// MARK: - The canvas: bold vermilion sun over cobalt waves

struct BoldCanvas: View {
    var body: some View {
        Canvas { context, size in
            var ctx = context
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(stops: [
                        .init(color: Color(red: 0.13, green: 0.22, blue: 0.47), location: 0),
                        .init(color: Color(red: 0.07, green: 0.12, blue: 0.30), location: 1)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            let sunC = CGPoint(x: w * 0.63, y: h * 0.36)
            let sunR = w * 0.16
            ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - sunR * 2.2, y: sunC.y - sunR * 2.2,
                                            width: sunR * 4.4, height: sunR * 4.4)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.14).opacity(0.5), .clear]),
                                           center: sunC, startRadius: 0, endRadius: sunR * 2.2))
            ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR * 2, height: sunR * 2)),
                     with: .color(Color(red: 0.97, green: 0.36, blue: 0.11)))
            ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - sunR * 0.55, y: sunC.y - sunR * 0.68,
                                            width: sunR * 1.05, height: sunR * 1.05)),
                     with: .color(Color(red: 1.0, green: 0.55, blue: 0.24)))
            // Impasto rings inside the sun — painted, not printed
            for (rr, alpha) in [(0.62, 0.30), (0.82, 0.22)] {
                let r = sunR * CGFloat(rr)
                var arc = Path()
                arc.addArc(center: sunC, radius: r, startAngle: .degrees(300), endAngle: .degrees(180), clockwise: false)
                ctx.stroke(arc, with: .color(Color(red: 0.85, green: 0.28, blue: 0.08).opacity(alpha)),
                           style: StrokeStyle(lineWidth: sunR * 0.10, lineCap: .round))
            }
            // Two sweeping waves, tapered
            taperedStroke(&ctx, cubicPoints(CGPoint(x: -w * 0.04, y: h * 0.62),
                                            CGPoint(x: w * 0.3, y: h * 0.46),
                                            CGPoint(x: w * 0.72, y: h * 0.64),
                                            CGPoint(x: w * 1.05, y: h * 0.52)),
                          color: Color(red: 0.52, green: 0.66, blue: 0.92),
                          w0: w * 0.062, w1: w * 0.034)
            taperedStroke(&ctx, cubicPoints(CGPoint(x: -w * 0.04, y: h * 0.78),
                                            CGPoint(x: w * 0.35, y: h * 0.68),
                                            CGPoint(x: w * 0.7, y: h * 0.86),
                                            CGPoint(x: w * 1.05, y: h * 0.74)),
                          color: Color(red: 0.30, green: 0.44, blue: 0.74),
                          w0: w * 0.050, w1: w * 0.028)
            // Two stars
            for (sx, sy, sr) in [(0.16, 0.14, 0.013), (0.36, 0.24, 0.010)] {
                let c = CGPoint(x: w * sx, y: h * sy); let r = w * sr
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                         with: .radialGradient(Gradient(colors: [Color(red: 0.97, green: 0.92, blue: 0.66).opacity(0.45), .clear]),
                                               center: c, startRadius: 0, endRadius: r * 2.4))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.97, green: 0.93, blue: 0.72)))
            }
            var hills = Path()
            hills.move(to: CGPoint(x: 0, y: h)); hills.addLine(to: CGPoint(x: 0, y: h * 0.88))
            hills.addQuadCurve(to: CGPoint(x: w, y: h * 0.90), control: CGPoint(x: w * 0.5, y: h * 0.80))
            hills.addLine(to: CGPoint(x: w, y: h)); hills.closeSubpath()
            ctx.fill(hills, with: .color(Color(red: 0.05, green: 0.09, blue: 0.17)))
            impasto(&ctx, size, seed: 53)
            // The spotlight falls on the canvas too: lit top, settling dark
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(stops: [.init(color: Color.white.opacity(0.10), location: 0),
                                         .init(color: .clear, location: 0.35),
                                         .init(color: Color.black.opacity(0.16), location: 1)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}

// MARK: - Assembly

struct WallGrain: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = Rand(23)
            for _ in 0..<1500 {
                let x = rng.in_(0, size.width), y = rng.in_(0, size.height)
                let r = rng.in_(0.6, 1.7)
                let light = rng.next() > 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(light ? Color.white.opacity(rng.in_(0.015, 0.045))
                                            : Color.black.opacity(rng.in_(0.02, 0.06))))
            }
        }
    }
}

struct ArtbipIcon: View {
    // 1024 canvas, 824 squircle per Apple template
    let canvas: CGFloat = 1024
    let squircle: CGFloat = 824
    let corner: CGFloat = 185.4
    let pw: CGFloat = 600
    let ph: CGFloat = 470
    let frameW: CGFloat = 46

    var body: some View {
        let wall = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            // Gallery wall — slightly warm, light-to-dark for system lighting
            wall.fill(LinearGradient(stops: [
                    .init(color: Color(red: 0.262, green: 0.246, blue: 0.226), location: 0),
                    .init(color: Color(red: 0.118, green: 0.112, blue: 0.106), location: 0.55),
                    .init(color: Color(red: 0.068, green: 0.066, blue: 0.064), location: 1)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: squircle, height: squircle)
            WallGrain().frame(width: squircle, height: squircle).clipShape(wall)
            // Spotlight pool from above
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.72).opacity(0.44), .clear],
                                     center: .center, startRadius: 0, endRadius: squircle * 0.50))
                .frame(width: squircle * 1.25, height: squircle * 1.0)
                .offset(y: -squircle * 0.40)
                .frame(width: squircle, height: squircle)
                .clipShape(wall)

            ZStack {
                MitredFrame(frameW: frameW)
                    .frame(width: pw, height: ph)
                BoldCanvas()
                    .frame(width: pw - frameW * 2, height: ph - frameW * 2)
                    .clipShape(Rectangle())
                    // canvas sits behind the frame: shadowed all round, deepest under the top rail
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.black.opacity(0.40), lineWidth: frameW * 0.14)
                            .blur(radius: frameW * 0.12))
                    .overlay(
                        VStack(spacing: 0) {
                            LinearGradient(colors: [Color.black.opacity(0.35), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: frameW * 0.45)
                            Spacer()
                        })
            }
            .offset(y: -16)
            .shadow(color: .black.opacity(0.55), radius: 10, y: 10)
            .shadow(color: .black.opacity(0.45), radius: 42, y: 34)
        }
        .frame(width: canvas, height: canvas)
    }
}

// MARK: - Render (2048 supersample -> 1024)

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: ArtbipIcon())
    renderer.scale = 2
    guard let big = renderer.cgImage else { fatalError("render failed") }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(big, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let final = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, final, nil)
    CGImageDestinationFinalize(dest)
    try! (data as Data).write(to: URL(fileURLWithPath: out))
    print("wrote \(out) \(final.width)x\(final.height)")
}
