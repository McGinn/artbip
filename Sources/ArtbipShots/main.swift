// Renders marketing images of the artbip UI headlessly with SwiftUI
// ImageRenderer: the same design and real collection data, drawn without a
// live window (shell screen capture needs permissions this tool doesn't).
// Usage: ArtbipShots <outdir> [wallpaper.png]
import AppKit
import ArtbipCore
import SwiftUI

let galleryIds = [
    "wikidata-Q45585", "wikidata-Q185372", "rijks-200107928", "wikidata-Q698487",
    "wikidata-Q1044742", "wikidata-Q1025704", "wikidata-Q83872", "wikidata-Q311243",
    "wikidata-Q151047", "wikidata-Q328523", "wikidata-Q464782", "wikidata-Q683274",
]

struct Shot {
    let works: [(ManifestWork, NSImage)]
    let current: String
}

// MARK: - UI mimics (static versions of the app's views, images preloaded)

struct ShotCard: View {
    let work: ManifestWork
    let image: NSImage
    var isCurrent = false
    var isFavourite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black.opacity(0.25))
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if isFavourite {
                    Image(systemName: "heart.fill").foregroundStyle(.pink).padding(6)
                        .shadow(radius: 2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
            Text(work.title)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Color(white: 0.94))
            HStack {
                Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
                    .font(.system(size: 10.5)).foregroundStyle(Color(white: 0.62)).lineLimit(1)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle")
                    Image(systemName: isFavourite ? "heart.fill" : "heart")
                    Image(systemName: "eye.slash")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color(white: 0.55))
            }
        }
        .padding(8)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ShotGalleryWindow: View {
    let shot: Shot

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            ZStack {
                Color(white: 0.13)
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 14)
                Text("artbip").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.75))
                HStack(spacing: 18) {
                    Spacer()
                    Label("Gallery", systemImage: "square.grid.3x3")
                        .foregroundStyle(Color.accentColor)
                    Label("History", systemImage: "clock").foregroundStyle(Color(white: 0.6))
                    Label("Blocked", systemImage: "eye.slash").foregroundStyle(Color(white: 0.6))
                    Label("Settings", systemImage: "gearshape").foregroundStyle(Color(white: 0.6))
                }
                .font(.system(size: 11.5))
                .padding(.trailing, 16)
            }
            .frame(height: 40)

            // Search row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(white: 0.5))
                    Text("Search title, artist, movement, region…")
                        .foregroundStyle(Color(white: 0.45))
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 330)
                HStack(spacing: 5) {
                    Image(systemName: "square")
                        .font(.system(size: 11)).foregroundStyle(Color(white: 0.6))
                    Text("Favourites only").font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                }
                Spacer()
                Text("2000 works").font(.system(size: 12)).foregroundStyle(Color(white: 0.55))
            }
            .padding(12)
            .background(Color(white: 0.115))

            Rectangle().fill(Color(white: 0.22)).frame(height: 1)

            // Grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(Array(shot.works.enumerated()), id: \.offset) { i, pair in
                    ShotCard(work: pair.0, image: pair.1,
                             isCurrent: pair.0.id == shot.current,
                             isFavourite: i == 3 || i == 7)
                }
            }
            .padding(14)
            .background(Color(white: 0.115))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.3), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

struct ShotMenu: View {
    let title: String
    let artist: String

    private func item(_ text: String, _ symbol: String? = nil, dim: Bool = false,
                      shortcut: String? = nil) -> some View {
        HStack {
            Text(text).font(.system(size: 13))
                .foregroundStyle(dim ? Color(white: 0.55) : Color(white: 0.92))
            Spacer()
            if let shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item(title, dim: true)
            item(artist, dim: true)
            Divider().padding(.horizontal, 10)
            item("Next Artwork", shortcut: "⌘N")
            item("Pause Rotation")
            item("Favourite", shortcut: "⌘F")
            item("Never Show Again")
            item("View at Museum of Modern Art")
            Divider().padding(.horizontal, 10)
            item("Open artbip…", shortcut: "⌘O")
            item("Launch at Login   ✓")
            Divider().padding(.horizontal, 10)
            item("Quit artbip", shortcut: "⌘Q")
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.32), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

struct DesktopHero: View {
    let wallpaper: NSImage
    let shot: Shot

    var body: some View {
        ZStack {
            Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
            ShotGalleryWindow(shot: shot)
                .frame(width: 980)
                .shadow(color: .black.opacity(0.55), radius: 34, y: 18)
        }
        .frame(width: 1440, height: 900)
        .clipped()
    }
}

// MARK: - Render

@MainActor
func render<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage, let png = Compositor.png(cg) else {
        FileHandle.standardError.write(Data("render failed for \(url.lastPathComponent)\n".utf8))
        return
    }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ArtbipShots <outdir> [wallpaper.png]\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let store = try RuntimeStore()
let manifest = try store.loadManifest()
let byId = Dictionary(uniqueKeysWithValues: manifest.works.map { ($0.id, $0) })
let cache = WallpaperEngine.makeCache(store: store, settings: store.loadSettings())

var pairs: [(ManifestWork, NSImage)] = []
for id in galleryIds {
    guard let work = byId[id] else { continue }
    if let data = try? await cache.thumbnailData(for: work), let img = NSImage(data: data) {
        pairs.append((work, img))
    }
}
print("thumbnails ready: \(pairs.count)/\(galleryIds.count)")
let shot = Shot(works: pairs, current: "wikidata-Q45585")

await MainActor.run {
    render(ShotGalleryWindow(shot: shot).frame(width: 1080),
           to: outDir.appendingPathComponent("ui-gallery.png"))
    render(ShotMenu(title: "The Starry Night", artist: "Vincent van Gogh, 1889"),
           to: outDir.appendingPathComponent("ui-menubar.png"))
    if args.count >= 3, let wp = NSImage(contentsOfFile: args[2]) {
        render(DesktopHero(wallpaper: wp, shot: shot),
               to: outDir.appendingPathComponent("desktop-hero.png"))
    }
}
