import CoreGraphics
import Testing
@testable import ArtbipCore

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// A w×h image filled with `ground`, with `paint` drawn by `shape`.
private func image(_ w: Int, _ h: Int, ground: [CGFloat], paint: [CGFloat],
                   shape: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: srgb, components: ground + [1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(colorSpace: srgb, components: paint + [1])!)
    shape(ctx)
    return ctx.makeImage()!
}

/// An arched panel: a rectangle topped by a half circle, inset from the edges.
private func arch(_ ctx: CGContext) {
    let (w, h) = (CGFloat(ctx.width), CGFloat(ctx.height))
    let r = w * 0.4, cx = w / 2, base = h * 0.6
    ctx.fill(CGRect(x: cx - r, y: h * 0.05, width: 2 * r, height: base - h * 0.05))
    ctx.fillEllipse(in: CGRect(x: cx - r, y: base - r, width: 2 * r, height: 2 * r))
}

/// RGBA of one pixel, in top-left coordinates.
private func pixel(_ img: CGImage, x: Int, y: Int) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    }
    return px
}

@Test func archedPanelOnWhiteLosesItsCorners() throws {
    let img = image(400, 600, ground: [1, 1, 1], paint: [0.55, 0.3, 0.1], shape: arch)
    let out = try #require(Compositor.cutOutGround(img))
    #expect(out.width == 400 && out.height == 600)
    #expect(pixel(out, x: 5, y: 5)[3] == 0)
    #expect(pixel(out, x: 395, y: 5)[3] == 0)
    #expect(pixel(out, x: 200, y: 300)[3] == 255)
}

@Test func midGreyPhotoCardIsCut() throws {
    let card: [CGFloat] = [93 / 255, 96 / 255, 93 / 255]
    let img = image(400, 600, ground: card, paint: [0.8, 0.75, 0.6], shape: arch)
    let out = try #require(Compositor.cutOutGround(img))
    #expect(pixel(out, x: 5, y: 5)[3] == 0)
    #expect(pixel(out, x: 200, y: 300)[3] == 255)
}

@Test func blackScanGroundIsCut() throws {
    let img = image(400, 600, ground: [0, 0, 0], paint: [0.8, 0.6, 0.5], shape: arch)
    let out = try #require(Compositor.cutOutGround(img))
    #expect(pixel(out, x: 5, y: 5)[3] == 0)
}

@Test func darkPaintedBackgroundIsNotCut() {
    // Painted near-black (a Dürer or Caravaggio background) sits around
    // 8-13, not at 0: part of the painting, not a photo ground.
    let img = image(400, 600, ground: [10 / 255, 9 / 255, 8 / 255], paint: [0.8, 0.6, 0.5], shape: arch)
    #expect(Compositor.cutOutGround(img) == nil)
}

@Test func fullBleedPaintingIsNotCut() {
    let img = image(400, 600, ground: [0.4, 0.5, 0.7], paint: [0.9, 0.8, 0.2]) {
        $0.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
    }
    #expect(Compositor.cutOutGround(img) == nil)
}

@Test func composeCutsOnlyWhenAsked() throws {
    let img = image(400, 600, ground: [1, 1, 1], paint: [0.55, 0.3, 0.1], shape: arch)
    let plain = try #require(Compositor.compose(art: img, targetWidth: 800, targetHeight: 800,
                                                options: ComposeOptions(shadow: false)))
    let cut = try #require(Compositor.compose(art: img, targetWidth: 800, targetHeight: 800,
                                              options: ComposeOptions(shadow: false, cutOutGround: true)))
    // Margin 36 px; the 400×600 art fits 728 px high, so it starts near x = 157.
    // Its top-left corner is white ground uncut, and the dimmed blur once cut.
    #expect(Array(pixel(plain, x: 162, y: 41)[0..<3]) == [255, 255, 255])
    #expect(pixel(cut, x: 162, y: 41)[0] < 200)
}
