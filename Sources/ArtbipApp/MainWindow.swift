import ArtbipCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var controller: RotationController

    var body: some View {
        TabView {
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "square.grid.3x3") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
            BlockedView()
                .tabItem { Label("Blocked", systemImage: "eye.slash") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { controller.reloadFromDisk() }
    }
}

// MARK: - Shared thumbnail view

struct WorkThumb: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork
    var height: CGFloat = 180
    /// Neutral plate behind the image, so gallery tiles keep a uniform height.
    /// The info panel turns it off: around a portrait in a narrow window the
    /// plate reads as two grey bars rather than as a frame.
    var plate: Bool = true

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if plate { Rectangle().fill(.black.opacity(0.25)) }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // With a plate the tile is exactly `height`; without one the artwork
        // keeps its own aspect ratio and `height` is just a ceiling.
        .frame(height: plate ? height : nil)
        .frame(maxHeight: plate ? nil : height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Reload whenever the work changes. In the history List, SwiftUI reuses
        // a row's @State by position, so without clearing first this view would
        // keep the previous work's thumbnail next to the new title.
        .task(id: work.id) {
            image = nil
            image = await controller.thumbnail(for: work)
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var controller: RotationController

    var body: some View {
        let entries = Array(controller.state.history.reversed())
        List(Array(entries.enumerated()), id: \.offset) { _, entry in
            if let work = controller.worksById[entry.id] {
                HStack(spacing: 12) {
                    WorkThumb(work: work, height: 64)
                        .frame(width: 96)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(work.title).font(.headline).lineLimit(1)
                        Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
                            .foregroundStyle(.secondary).lineLimit(1)
                        Text(entry.shownAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    WorkActions(work: work)
                }
                .padding(.vertical, 2)
            }
        }
        .overlay {
            if controller.state.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock",
                                       description: Text("Works appear here as they rotate onto the desktop."))
            }
        }
    }
}

// MARK: - Blocked

struct BlockedView: View {
    @EnvironmentObject var controller: RotationController

    var body: some View {
        List(controller.state.blocklist, id: \.self) { id in
            HStack(spacing: 12) {
                if let work = controller.worksById[id] {
                    WorkThumb(work: work, height: 64)
                        .frame(width: 96)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(work.title).font(.headline).lineLimit(1)
                        Text(work.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(id)
                }
                Spacer()
                Button("Unblock") { controller.unblock(id) }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if controller.state.blocklist.isEmpty {
                ContentUnavailableView("Nothing blocked", systemImage: "eye.slash",
                                       description: Text("Works you never want to see again land here."))
            }
        }
    }
}

// MARK: - Per-work action cluster (used by gallery cards, history rows)

struct WorkActions: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.show(work)
            } label: {
                Image(systemName: "photo.on.rectangle")
            }
            .help("Set as wallpaper now")
            .disabled(controller.busy)

            Button {
                controller.toggleFavourite(work.id)
            } label: {
                Image(systemName: controller.isFavourite(work.id) ? "heart.fill" : "heart")
            }
            .help("Favourite")

            Button {
                controller.block(work.id)
            } label: {
                Image(systemName: "eye.slash")
            }
            .help("Never show again")

            if let url = URL(string: work.collectionURL) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("View at \(work.collection)")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }
}
