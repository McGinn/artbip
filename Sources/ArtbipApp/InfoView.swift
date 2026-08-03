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
    private var artist: ArtistInfo? { controller.info.artist(forSort: work.artistSort) }
    private var school: SchoolInfo? { controller.info.school(forMovement: work.movement) }

    /// Persisted rather than @State: the same school text recurs for every work
    /// in a tradition, so collapsing it once should stay collapsed.
    private var schoolExpanded: Binding<Bool> {
        Binding(get: { controller.settings.infoSchoolExpanded },
                set: { open in controller.updateSettings { $0.infoSchoolExpanded = open } })
    }

    /// Same, for the painter.
    private var artistExpanded: Binding<Bool> {
        Binding(get: { controller.settings.infoArtistExpanded },
                set: { open in controller.updateSettings { $0.infoArtistExpanded = open } })
    }

    /// Citations in first-appearance order, shared by paragraph markers and the
    /// sources list. Order must match the render order below, or the [n] markers
    /// point at the wrong source — and a collapsed section's sources are not
    /// counted, so Sources never lists a number nothing on screen refers to.
    private var citeOrder: [String] {
        var seen: [String] = []
        let artistParas = artistExpanded.wrappedValue ? (artist?.context ?? []) : []
        let schoolParas = schoolExpanded.wrappedValue ? (school?.context ?? []) : []
        for para in (entry?.context ?? []) + (entry?.details ?? []) + artistParas + schoolParas {
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
                }

                // The painter, then the tradition — widening out from the work
                // in front of you. Both are collapsible: they are background
                // rather than news about this picture, and they repeat for
                // every work by the same hand or in the same school.
                if let artist {
                    CollapsibleInfoSection(
                        title: artist.name, subtitle: artist.subtitle,
                        paragraphs: artist.context, expanded: artistExpanded,
                        hint: "artist", marks: marks)
                }

                if let school {
                    CollapsibleInfoSection(
                        title: school.name, subtitle: school.subtitle,
                        paragraphs: school.context, expanded: schoolExpanded,
                        hint: "period and style", marks: marks)
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
        [work.artist + artistDates, work.dateDisplay, work.medium,
         work.dimensions?.display].compactMap(\.self).joined(separator: " · ")
    }

    /// " (1824–1904)" when both dates are known, " (d. 1904)" when only the
    /// death year is — which is all the museums gave us before the Wikidata
    /// enrichment pass, and still all we have for some works.
    private var artistDates: String {
        switch (work.artistBirthYear, work.artistDeathYear) {
        case let (birth?, death?): return " (\(birth)–\(death))"
        case let (birth?, nil):    return " (b. \(birth))"
        case let (nil, death?):    return " (d. \(death))"
        default:                   return ""
        }
    }
}

/// A titled, collapsible run of cited paragraphs — used for both the artist and
/// the school, which differ only in what they are about.
private struct CollapsibleInfoSection: View {
    let title: String
    let subtitle: String?
    let paragraphs: [InfoParagraph]
    @Binding var expanded: Bool
    /// Filled into the tooltip: "Show <hint>".
    let hint: String
    /// Citation markers, resolved by the parent against the whole panel's order.
    let marks: ([String]) -> String

    // Spacing matches the parent panel's VStack, so the section's rows sit in
    // the same rhythm as everything above them rather than reading as a
    // nested block.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            // A plain Button rather than DisclosureGroup: the latter only
            // toggles on its chevron, which is a small target for something the
            // user is meant to collapse once and forget. Widening the target
            // with .onTapGesture on a DisclosureGroup label does not work
            // either — it fires alongside the built-in toggle, so the two
            // cancel and nothing happens.
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide \(hint)" : "Show \(hint)")

            if expanded {
                ForEach(paragraphs.indices, id: \.self) { i in
                    Text(paragraphs[i].text + marks(paragraphs[i].cite))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Translucent, so the wallpaper stays half-visible behind the reading
        // pane. .containerBackground is the supported route: an NSVisualEffectView
        // behind the content does nothing, because SwiftUI paints its own opaque
        // window background over it.
        .containerBackground(.ultraThinMaterial, for: .window)
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
