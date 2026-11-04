import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Downsample image data to a JPEG thumbnail using ImageIO (no third-party deps).
public enum Thumbs {
    public static func makeThumbnail(from data: Data, maxDimension: Int) -> Data? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The image with `trim` (left, top, right, bottom fractions) cut away,
    /// re-encoded as a high-quality JPEG; the data unchanged without a trim.
    public static func trimmed(_ data: Data, _ trim: [Double]?) -> Data? {
        guard let trim, trim.count == 4, trim.contains(where: { $0 != 0 }) else { return data }
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        let rect = CGRect(x: (w * trim[0]).rounded(), y: (h * trim[1]).rounded(),
                          width: (w * (1 - trim[0] - trim[2])).rounded(),
                          height: (h * (1 - trim[1] - trim[3])).rounded())
        guard rect.width >= 1, rect.height >= 1, let cut = cg.cropping(to: rect) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cut, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Pixel size of encoded image data without decoding the bitmap.
    public static func imageSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
