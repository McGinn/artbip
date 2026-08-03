import ArtbipCore
import SwiftUI

/// "About this work" — titleplate from the manifest (always available),
/// context/details from info.json when an entry exists, sources at the
/// bottom. Shown as a sheet from gallery cards and as the standalone
/// "info" window for the current wallpaper.
struct WorkInfoPanel: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork
    /// Extra headroom so content clears the traffic lights when the panel is
    /// shown in a hidden-title-bar window. The gallery sheet has real chrome
    /// and passes 0.
    var topInset: CGFloat = 0

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
                // Thumbnails cap at 640px, so keep the reproduction modest —
                // scaling it up only makes it soft, and the full-size work is
                // already on the desktop behind this panel.
                WorkThumb(work: work, height: 220, plate: false)
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
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        // Narrow enough to sit beside the artwork rather than over it. Height is
        // a floor only: a ScrollView reports a flexible ideal rather than its
        // content's height, so a window cannot actually shrink-wrap this — the
        // scene sets a sensible opening height and macOS remembers any resize.
        .frame(width: 400)
        .frame(minHeight: 260)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let work = controller.currentWork {
                // 22pt clears the traffic lights, which float over the content
                // once the title bar is hidden.
                WorkInfoPanel(work: work, topInset: 22)
                    .navigationTitle(work.title)
            } else {
                ContentUnavailableView("Nothing shown yet", systemImage: "photo.artframe",
                                       description: Text("Rotate to a work first."))
                    .frame(minWidth: 360, minHeight: 240)
            }
        }
        // The menu and main window refresh on appear; without this the panel
        // keeps showing whatever was current when the controller last read
        // disk, so a rotation while it is open leaves it describing the wrong
        // painting.
        .onAppear { controller.reloadFromDisk() }
        // Hand the hosting NSWindow to the controller so the global shortcut can
        // close this exact panel. SwiftUI gives a scene's window no identifier
        // matching its scene id, so it cannot be found in NSApp.windows.
        .background(WindowAccessor { controller.infoWindow = $0 })
        // With no title bar there is no obvious close affordance beyond the
        // traffic lights, so honour Escape.
        .onExitCommand { dismiss() }
    }
}
