import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Wall-label text drawn in the bottom margin (title line + detail line).
public struct ComposeLabel: Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct ComposeOptions: Sendable {
    public enum Background: String, Sendable {
        /// The artwork itself, scaled to fill, heavily blurred and dimmed.
        case blur
        /// A flat colour derived from the work's dominant colour (or the
        /// image's average colour when the manifest has none).
        case palette
    }

    public var background: Background
    /// Minimum breathing room around the art, as a fraction of the short
    /// screen edge. The art is fit inside this inset box — never cropped.
    public var marginFraction: Double
    public var shadow: Bool
    public var label: ComposeLabel?
    /// Make a plain photo ground around a shaped panel transparent (see
    /// `cutOutGround`), so arched panels show no white corners. Off by default.
    public var cutOutGround: Bool

    public init(background: Background = .blur, marginFraction: Double = 0.045,
                shadow: Bool = true, label: ComposeLabel? = nil, cutOutGround: Bool = false) {
        self.background = background
        self.marginFraction = marginFraction
        self.shadow = shadow
        self.label = label
        self.cutOutGround = cutOutGround
    }
}

/// Manifest work + screen geometry -> wallpaper bitmap. The art is always
/// letterboxed to fit (upscaled only as far as the fit requires; prefilter
/// guarantees sources near display resolution, so upscaling stays mild).
public enum Compositor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Codec helpers

    public static func decode(_ data: Data) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }

    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Compose

    public static func compose(art: CGImage, targetWidth: Int, targetHeight: Int,
                               dominantHSL: [Double]? = nil,
                               options: ComposeOptions = ComposeOptions()) -> CGImage? {
        guard targetWidth > 0, targetHeight > 0, art.width > 0, art.height > 0,
              let ctx = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let full = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        switch options.background {
        case .blur:
            if let bg = blurredFill(art, width: targetWidth, height: targetHeight) {
                ctx.draw(bg, in: full)
            } else {
                ctx.setFillColor(paletteColor(hsl: dominantHSL, art: art))
                ctx.fill(full)
            }
            // Dim so the sharp art reads against its own blurred echo.
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.34))
            ctx.fill(full)
        case .palette:
            ctx.setFillColor(paletteColor(hsl: dominantHSL, art: art))
            ctx.fill(full)
        }

        // Fit the art inside the margin box. Never crop.
        let short = CGFloat(min(targetWidth, targetHeight))
        let margin = short * options.marginFraction
        let availW = CGFloat(targetWidth) - 2 * margin
        let availH = CGFloat(targetHeight) - 2 * margin
        let scale = min(availW / CGFloat(art.width), availH / CGFloat(art.height))
        let artW = CGFloat(art.width) * scale
        let artH = CGFloat(art.height) * scale
        let artRect = CGRect(x: (CGFloat(targetWidth) - artW) / 2,
                             y: (CGFloat(targetHeight) - artH) / 2,
                             width: artW, height: artH)

        ctx.saveGState()
        if options.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -short * 0.006),
                          blur: short * 0.02,
                          color: CGColor(gray: 0, alpha: 0.55))
        }
        // The background above keeps the uncut art; only the sharp copy is cut.
        let shaped = options.cutOutGround ? cutOutGround(art) ?? art : art
        ctx.draw(shaped, in: artRect)
        ctx.restoreGState()

        if let label = options.label {
            drawLabel(label, in: ctx, targetWidth: targetWidth, margin: margin)
        }
        return ctx.makeImage()
    }

    // MARK: Shaped panels

    /// Arched and shaped panels are often photographed on a plain white, black
    /// or mid-grey ground. Flood-fills that ground in from the image edge and
    /// returns the art with it made transparent, or nil when there is no such
    /// ground (or it covers too little or too much to be a ground).
    public static func cutOutGround(_ img: CGImage) -> CGImage? {
        let scale = min(1, 480 / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let small = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: srgb,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            small.interpolationQuality = .medium
            small.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func rgb(_ i: Int) -> (Int, Int, Int) { (Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2])) }
        var stack: [Int] = []
        for x in 0..<w { stack += [x, (h - 1) * w + x] }
        for y in 0..<h { stack += [y * w, y * w + w - 1] }
        // A photographer's mid-grey card: the edge is mostly one neutral grey.
        // Dark painted edges are never mid-grey.
        let edge = stack.map(rgb)
        let med = [edge.map(\.0), edge.map(\.1), edge.map(\.2)].map { $0.sorted()[$0.count / 2] }
        func nearMed(_ c: (Int, Int, Int)) -> Bool {
            abs(c.0 - med[0]) <= 16 && abs(c.1 - med[1]) <= 16 && abs(c.2 - med[2]) <= 16
        }
        let grey = med.max()! - med.min()! <= 8 && med.min()! > 60 && med.max()! < 200
            && Double(edge.filter(nearMed).count) > 0.75 * Double(edge.count)
        // Otherwise only a near-white ground or a true digital black counts.
        // Painted darks (Dürer, the Hell panel, the Raft) sit around 8-13 and
        // show through a cut on a blurred background; scan borders are 0.
        func isGround(_ c: (Int, Int, Int)) -> Bool {
            let lo = min(c.0, c.1, c.2), hi = max(c.0, c.1, c.2)
            return hi - lo < 18 && lo > 228 || hi < 5 || grey && nearMed(c)
        }
        var ground = [Bool](repeating: false, count: w * h)
        while let i = stack.popLast() {
            guard !ground[i], isGround(rgb(i)) else { continue }
            ground[i] = true
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
        let frac = Double(ground.filter { $0 }.count) / Double(w * h)
        guard frac > 0.004, frac < 0.45 else { return nil }
        // Mask (white = keep), grown by a pixel and softened, then scaled up.
        var mask = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) where ground[i] {
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny >= 0, ny < h { mask[ny * w + nx] = 0 }
                }
            }
        }
        let gray = CGColorSpaceCreateDeviceGray()
        let maskImage: CGImage? = mask.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        guard let maskImage else { return nil }
        let soft = CIImage(cgImage: maskImage).clampedToExtent().applyingGaussianBlur(sigma: 0.6)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let softMask = ciContext.createCGImage(soft, from: soft.extent, format: .L8, colorSpace: gray),
              let out = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        out.clip(to: full, mask: softMask)
        out.draw(img, in: full)
        return out.makeImage()
    }

    // MARK: Backgrounds

    /// The art scaled to FILL the target (cropping the background copy is
    /// fine), blurred hard. Rendered at quarter resolution — the blur and the
    /// dimming veil hide the loss, and it keeps a 5K compose fast.
    static func blurredFill(_ art: CGImage, width: Int, height: Int) -> CGImage? {
        let bgW = max(1, width / 4), bgH = max(1, height / 4)
        let fillScale = max(CGFloat(bgW) / CGFloat(art.width), CGFloat(bgH) / CGFloat(art.height))
        var ci = CIImage(cgImage: art)
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let crop = CGRect(x: (ci.extent.width - CGFloat(bgW)) / 2 + ci.extent.origin.x,
                          y: (ci.extent.height - CGFloat(bgH)) / 2 + ci.extent.origin.y,
                          width: CGFloat(bgW), height: CGFloat(bgH))
        ci = ci.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
        let extent = CGRect(x: 0, y: 0, width: bgW, height: bgH)
        ci = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(bgW, bgH)) / 22)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9])
        return ciContext.createCGImage(ci, from: extent)
    }

    /// Deep, muted version of the dominant colour — a gallery-wall tone dark
    /// enough that the label text and shadow always read.
    static func paletteColor(hsl: [Double]?, art: CGImage) -> CGColor {
        var (h, s, l) = hsl.flatMap(normalizeHSL) ?? averageHSL(art) ?? (0, 0, 0.2)
        s *= 0.45
        l = 0.15 + l * 0.10
        let (r, g, b) = hslToRGB(h: h, s: s, l: l)
        return CGColor(colorSpace: srgb, components: [CGFloat(r), CGFloat(g), CGFloat(b), 1])!
    }

    /// Accepts either normalized [0-1, 0-1, 0-1] or ARTIC-style [0-360, 0-100, 0-100].
    static func normalizeHSL(_ hsl: [Double]) -> (Double, Double, Double)? {
        guard hsl.count >= 3 else { return nil }
        var (h, s, l) = (hsl[0], hsl[1], hsl[2])
        if h > 1 || s > 1 || l > 1 { h /= 360; s /= 100; l /= 100 }
        return (min(max(h, 0), 1), min(max(s, 0), 1), min(max(l, 0), 1))
    }

    static func averageHSL(_ art: CGImage) -> (Double, Double, Double)? {
        let ci = CIImage(cgImage: art)
        let avg = ci.applyingFilter("CIAreaAverage",
                                    parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: srgb)
        return rgbToHSL(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1 / 3), channel(h), channel(h - 1 / 3))
    }

    static func rgbToHSL(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    // MARK: Label

    static func drawLabel(_ label: ComposeLabel, in ctx: CGContext, targetWidth: Int, margin: CGFloat) {
        // The label lives in the bottom margin strip, left-aligned with the
        // margin box; sizes are chosen so two lines always fit inside it.
        let titleSize = margin * 0.30
        let detailSize = margin * 0.24
        let maxWidth = CGFloat(targetWidth) - 2 * margin
        let titleFont = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, titleSize, nil)
        let detailFont = CTFontCreateWithName("HelveticaNeue" as CFString, detailSize, nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -titleSize * 0.06),
                      blur: titleSize * 0.18, color: CGColor(gray: 0, alpha: 0.65))
        drawLine(label.detail, font: detailFont, color: CGColor(gray: 1, alpha: 0.66),
                 at: CGPoint(x: margin, y: margin * 0.18), maxWidth: maxWidth, in: ctx)
        drawLine(label.title, font: titleFont, color: CGColor(gray: 1, alpha: 0.93),
                 at: CGPoint(x: margin, y: margin * 0.18 + detailSize * 1.45), maxWidth: maxWidth, in: ctx)
        ctx.restoreGState()
    }

    static func drawLine(_ text: String, font: CTFont, color: CGColor,
                         at point: CGPoint, maxWidth: CGFloat, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        guard let astr = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        var line = CTLineCreateWithAttributedString(astr)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth),
           let token = CFAttributedStringCreate(nil, "…" as CFString, attrs) {
            let tokenLine = CTLineCreateWithAttributedString(token)
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, tokenLine) ?? line
        }
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
