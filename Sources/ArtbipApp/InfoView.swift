import ArtbipCore
import SwiftUI

/// "About this work" — titleplate from the manifest (always available),
/// context/details from info.json when an entry exists, sources at the
/// bottom. Shown as a sheet from gallery cards and as the standalone
/// "info" window for the current wallpaper.
struct WorkInfoPanel: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork

    private var entry: WorkInfo? { controller.info.entries[work.id] }

    /// Citations in first-appearance order, shared by paragraph markers
    /// and the sources list.
    private var citeOrder: [String] {
        var seen: [String] = []
        for para in (entry?.context ?? []) + (entry?.details ?? []) {
            for cite in para.cite where !seen.contains(cite) {
                seen.append(cite)
            }
        }
        return seen
    }

    private func marks(_ cites: [String]) -> String {
        let order = citeOrder
        let refs = cites.compactMap { order.firstIndex(of: $0).map { $0 + 1 } }
        return refs.isEmpty ? "" : " [" + refs.map(String.init).joined(separator: ",") + "]"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkThumb(work: work, height: 260)
                    .frame(maxWidth: .infinity)

                // Titleplate
                VStack(alignment: .leading, spacing: 3) {
                    Text(work.title).font(.title2.bold())
                    Text(titleplateLine).foregroundStyle(.secondary)
                    if let url = URL(string: work.collectionURL) {
                        Link(work.collection, destination: url).font(.callout)
                    }
                }

                if let caption = work.caption {
                    Text(caption).italic().foregroundStyle(.secondary)
                }

                if let entry {
                    if !entry.context.isEmpty {
                        Divider()
                        ForEach(entry.context.indices, id: \.self) { i in
                            Text(entry.context[i].text + marks(entry.context[i].cite))
                        }
                    }
                    if !entry.details.isEmpty {
                        Divider()
                        Text("Look for").font(.headline)
                        ForEach(entry.details.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(entry.details[i].text + marks(entry.details[i].cite))
                            }
                        }
                    }
                    if !citeOrder.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sources").font(.caption.bold()).foregroundStyle(.secondary)
                            ForEach(Array(citeOrder.enumerated()), id: \.offset) { i, cite in
                                let label = "[\(i + 1)] \(controller.info.label(forCite: cite))"
                                if let url = controller.info.url(forCite: cite) {
                                    Link(label, destination: url)
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 640)
    }

    private var titleplateLine: String {
        var artist = work.artist
        if let death = work.artistDeathYear { artist += " (d. \(death))" }
        return [artist, work.dateDisplay, work.medium].compactMap(\.self).joined(separator: " · ")
    }
}

/// Standalone window for the current wallpaper ("About This Artwork" in the
/// menu bar). Follows rotation while open.
struct CurrentWorkInfoWindow: View {
    @EnvironmentObject var controller: RotationController

    var body: some View {
        if let work = controller.currentWork {
            WorkInfoPanel(work: work)
                .navigationTitle(work.title)
        } else {
            ContentUnavailableView("Nothing shown yet", systemImage: "photo.artframe",
                                   description: Text("Rotate to a work first."))
                .frame(minWidth: 440, minHeight: 420)
        }
    }
}
