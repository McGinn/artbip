import ArtbipCore
import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var controller: RotationController
    @State private var search = ""
    @State private var favouritesOnly = false
    @State private var infoWork: ManifestWork?

    private var filtered: [ManifestWork] {
        var works = controller.manifest.works
        if favouritesOnly {
            let favs = Set(controller.state.favourites)
            works = works.filter { favs.contains($0.id) }
        }
        let blocked = Set(controller.state.blocklist)
        works = works.filter { !blocked.contains($0.id) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            works = works.filter {
                $0.title.lowercased().contains(q)
                    || $0.artist.lowercased().contains(q)
                    || ($0.movement?.lowercased().contains(q) ?? false)
                    || ($0.region?.lowercased().contains(q) ?? false)
                    || $0.collection.lowercased().contains(q)
            }
        }
        return works.sorted { $0.artistSort < $1.artistSort }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search title, artist, movement, region…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Toggle("Favourites only", isOn: $favouritesOnly)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(filtered.count) works")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if let err = controller.lastError {
                    Text(err).foregroundStyle(.red).font(.caption).lineLimit(1)
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(filtered, id: \.id) { work in
                        GalleryCard(work: work) { infoWork = work }
                    }
                }
                .padding(14)
            }
        }
        .sheet(item: $infoWork) { work in
            VStack(spacing: 0) {
                WorkInfoPanel(work: work)
                Divider()
                HStack {
                    Spacer()
                    Button("Close") { infoWork = nil }.keyboardShortcut(.escape)
                }
                .padding(10)
            }
        }
    }
}

// Sheet presentation needs Identifiable; ManifestWork's id already is one.
extension ManifestWork: @retroactive Identifiable {}

struct GalleryCard: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork
    var showInfo: () -> Void = {}

    private var isCurrent: Bool { controller.state.current == work.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkThumb(work: work, height: 170)
                .overlay(alignment: .topTrailing) {
                    if controller.isFavourite(work.id) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .padding(6)
                            .shadow(radius: 2)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))

            Text(work.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack {
                Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                WorkActions(work: work)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { showInfo() }
        .contextMenu {
            Button("About This Work") { showInfo() }
            Button("Set as Wallpaper") { controller.show(work) }
            Button(controller.isFavourite(work.id) ? "Unfavourite" : "Favourite") {
                controller.toggleFavourite(work.id)
            }
            Button("Never Show Again") { controller.block(work.id) }
        }
        .help(work.caption ?? work.title)
    }
}
