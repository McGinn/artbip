import ArgumentParser
import ArtbipCore
import CoreGraphics
import Foundation

extension ComposeOptions.Background: ExpressibleByArgument {}

struct Compose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a wallpaper PNG from a manifest work (art fit inside the screen, never cropped).")

    @OptionGroup var opts: PipelineOptions
    @Option(help: "Work id from the manifest (e.g. met-436535). Omit for a random work.")
    var id: String?
    @Option(help: "Output PNG path (default work/wallpapers/<id>.png).")
    var out: String?
    @Option(help: "Target width in pixels (default: main display's native pixels).")
    var width: Int?
    @Option(help: "Target height in pixels (default: main display's native pixels).")
    var height: Int?
    @Option(help: "Background style: blur | palette.")
    var background: ComposeOptions.Background = .blur
    @Option(help: "Margin around the art as a fraction of the short screen edge.")
    var margin: Double = 0.045
    @Flag(help: "Disable the drop shadow behind the art.")
    var noShadow = false
    @Flag(help: "Draw a wall label (title / artist, date) in the bottom margin.")
    var label = false

    func run() async throws {
        let manifest = try JSONIO.read(Manifest.self, from: opts.dataDir.appendingPathComponent("manifest.json"))
        let work: ManifestWork
        if let id {
            guard let found = manifest.works.first(where: { $0.id == id }) else {
                throw ValidationError("\(id) is not in data/manifest.json")
            }
            work = found
        } else {
            guard let random = manifest.works.randomElement() else {
                throw ValidationError("manifest is empty")
            }
            work = random
        }

        let (targetW, targetH) = try targetPixels()
        guard let imageURL = URL(string: work.image.url) else {
            throw ValidationError("bad image URL for \(work.id): \(work.image.url)")
        }

        let http = Http(cacheDir: opts.workDir.appendingPathComponent("cache"))
        FileHandle.standardError.write(Data("compose: fetching \(work.id) (\(imageURL.host ?? "?"))…\n".utf8))
        let data = try await http.get(imageURL)
        guard let art = Compositor.decode(data) else {
            throw ValidationError("cannot decode image for \(work.id)")
        }

        var detail = work.artist
        if let date = work.dateDisplay { detail += ", \(date)" }
        let options = ComposeOptions(
            background: background,
            marginFraction: margin,
            shadow: !noShadow,
            label: label ? ComposeLabel(title: work.title, detail: detail) : nil)

        guard let composed = Compositor.compose(art: art, targetWidth: targetW, targetHeight: targetH,
                                                dominantHSL: work.paletteDominantHSL, options: options),
              let png = Compositor.png(composed) else {
            throw ValidationError("compositor failed for \(work.id)")
        }

        let outURL: URL
        if let out {
            outURL = URL(fileURLWithPath: out)
        } else {
            let dir = opts.workDir.appendingPathComponent("wallpapers")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            outURL = dir.appendingPathComponent("\(work.id).png")
        }
        try png.write(to: outURL, options: .atomic)
        print("compose: \(work.id) — \(work.title) (\(work.artist))")
        print("compose: art \(art.width)x\(art.height) -> \(targetW)x\(targetH) \(background.rawValue) -> \(outURL.path)")
    }

    func targetPixels() throws -> (Int, Int) {
        if let width, let height { return (width, height) }
        if width != nil || height != nil {
            throw ValidationError("pass both --width and --height, or neither")
        }
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        let display = try opts.config().display
        return (display.width, display.height)
    }
}
