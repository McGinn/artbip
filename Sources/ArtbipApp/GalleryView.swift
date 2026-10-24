import ArtbipCore
import SwiftUI

private enum LibrarySelection: Hashable {
    case all, favourites, collection(UUID)
}

struct GalleryView: View {
    @EnvironmentObject var controller: RotationController
    @EnvironmentObject var notes: NotesModel
    @State private var selection: LibrarySelection? = .all
    @State private var filters = GalleryFilter()
    @State private var showFilters = false
    @State private var infoWork: ManifestWork?
    @State private var collectionDraft: CollectionDraft?
    @State private var confirmDelete = false

    private var selectedCollection: SavedCollection? {
        guard case .collection(let id) = selection else { return nil }
        return controller.state.collections.first { $0.id == id }
    }

    private var title: String {
        switch selection {
        case .favourites: return "Favourites"
        case .collection: return selectedCollection?.name ?? "Collection"
        default: return "All artworks"
        }
    }

    private var libraryWorks: [ManifestWork] {
        let blocked = Set(controller.state.blocklist)
        let ids: Set<String>?
        switch selection {
        case .favourites: ids = Set(controller.state.favourites)
        case .collection: ids = Set(selectedCollection?.workIDs ?? [])
        default: ids = nil
        }
        let hideNSFW = controller.settings.hideNSFW
        return controller.manifest.works.filter {
            !blocked.contains($0.id) && !(hideNSFW && $0.isNSFW) && (ids == nil || ids!.contains($0.id))
        }
    }

    private var filtered: [ManifestWork] {
        libraryWorks.filter {
            filters.matches($0, hasNotes: notes.entry(for: $0.id) != nil)
        }.sorted {
            ($0.artistSort, $0.title, $0.id) < ($1.artistSort, $1.title, $1.id)
        }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 175, idealWidth: 195, maxWidth: 250)
            VStack(spacing: 0) {
                header
                Divider()
                if showFilters {
                    filterControls.padding(14)
                    Divider()
                }
                if filtered.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                            ForEach(filtered, id: \.id) { work in
                                GalleryCard(work: work,
                                            removeFromCollection: selectedCollection.map { collection in
                                                { controller.setMembership(collection.id, workID: work.id, included: false) }
                                            }) { infoWork = work }
                            }
                        }.padding(14)
                    }
                }
            }.frame(minWidth: 620)
        }
        .onAppear {
            if let name = LaunchArgument.value(after: "--show-collection"),
               let match = controller.state.collections.first(where: { $0.name == name }) {
                selection = .collection(match.id)
            }
        }
        .onChange(of: selection) { filters = GalleryFilter() }
        .onChange(of: controller.state.collections.map(\.id)) {
            if case .collection(let id) = selection,
               !controller.state.collections.contains(where: { $0.id == id }) { selection = .all }
        }
        .sheet(item: $collectionDraft) { draft in
            CollectionEditor(draft: draft) { id in
                if draft.existingID == nil { selection = .collection(id) }
            }
        }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let collection = selectedCollection {
                Button("Delete Collection", role: .destructive) {
                    controller.deleteCollection(collection.id)
                    selection = .all
                }
            }
        } message: {
            Text("Artworks, downloads and favourites are kept. If this collection is used for rotation, rotation returns to all artworks.")
        }
        .sheet(item: $infoWork) { work in
            VStack(spacing: 0) {
                WorkInfoPanel(work: work)
                Divider()
                HStack {
                    Spacer()
                    Button("Close") { infoWork = nil }.keyboardShortcut(.escape)
                }.padding(10)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Library") {
                    Label("All artworks", systemImage: "square.grid.2x2").tag(LibrarySelection.all)
                    Label("Favourites", systemImage: "heart").tag(LibrarySelection.favourites)
                }
                Section("My collections") {
                    ForEach(controller.state.collections) { collection in
                        HStack {
                            Label(collection.name, systemImage: "folder")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(availableCount(collection))").foregroundStyle(.secondary)
                                .font(.caption).monospacedDigit()
                        }
                        .tag(LibrarySelection.collection(collection.id))
                        .help(collection.name)
                    }
                }
            }.listStyle(.sidebar)
            if controller.state.collections.isEmpty {
                Text("Save gallery results or create a collection, then add artworks to it.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Button { beginCollection(save: false) } label: {
                Label("New collection", systemImage: "plus")
            }.padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Rotating from").font(.caption).foregroundStyle(.secondary)
                Text(controller.rotationSourceName).font(.callout).lineLimit(2)
                if controller.state.rotationCollectionID != nil || controller.settings.favouritesOnly {
                    Button("Use all artworks") { controller.selectRotationSource("all") }
                        .font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold()).lineLimit(1)
                    Text(filters.isActive ? "\(filtered.count) of \(libraryWorks.count) artworks" : "\(libraryWorks.count) artworks")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let collection = selectedCollection {
                    Button(controller.state.rotationCollectionID == collection.id ? "Used for rotation" : "Use for rotation") {
                        controller.selectRotationSource(collection.id.uuidString)
                    }
                    .disabled(libraryWorks.isEmpty || controller.state.rotationCollectionID == collection.id)
                    .help("Use this collection for the next rotation. The current wallpaper stays until then.")
                    Menu {
                        Button("Rename collection…") {
                            collectionDraft = CollectionDraft(existingID: collection.id, name: collection.name, works: [])
                        }
                        Button("Delete collection…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Collection options")
                    .accessibilityLabel("Collection options")
                }
                Button("Save results…") { beginCollection(save: true) }.disabled(filtered.isEmpty)
                    .help("Save these artworks as a new collection")
            }
            HStack(spacing: 10) {
                TextField("Search title, artist, subject…", text: $filters.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search artworks")
                Button {
                    showFilters.toggle()
                } label: {
                    Label(filters.facetCount == 0 ? "Filters" : "Filters (\(filters.facetCount))",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .help(showFilters ? "Hide filters" : "Show filters")
                if filters.isActive {
                    Button("Clear filters") { filters = GalleryFilter() }
                }
            }
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding(14)
    }

    private var filterControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                facet("Artist", selection: $filters.artist, options: libraryWorks.map(\.artist))
                facet("Movement", selection: $filters.movement, options: libraryWorks.compactMap(\.movement))
                facet("Subject", selection: $filters.subject, options: libraryWorks.flatMap { $0.tags ?? [] })
            }
            GridRow {
                Picker("Period", selection: $filters.period) {
                    ForEach(GalleryPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                facet("Museum / owner", selection: $filters.museum, options: libraryWorks.map(\.collection))
                Picker("Notes", selection: $filters.notes) {
                    ForEach(GalleryNotes.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }.pickerStyle(.menu)
    }

    private func facet(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(label, selection: selection) {
            Text("Any").tag("")
            ForEach(Array(Set(options.filter { !$0.isEmpty })).sorted(), id: \.self) { option in
                Text(option.replacingOccurrences(of: "-", with: " ")).tag(option)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if filters.isActive {
            ContentUnavailableView {
                Label("No matching artworks", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try a broader search or clear the filters.")
            } actions: {
                Button("Clear filters") { filters = GalleryFilter() }
            }
        } else if selectedCollection != nil {
            ContentUnavailableView("This collection is empty", systemImage: "folder",
                                   description: Text("Browse All artworks and use an artwork’s Add to collection menu, or save gallery results as a new collection. Blocked works are hidden."))
        } else {
            ContentUnavailableView("No artworks here yet", systemImage: "heart",
                                   description: Text("Favourite artworks to find them here. Blocked works are hidden."))
        }
    }

    private func availableCount(_ collection: SavedCollection) -> Int {
        let ids = Set(collection.workIDs).subtracting(controller.state.blocklist)
        return ids.intersection(controller.worksById.keys).count
    }

    private func beginCollection(save: Bool) {
        collectionDraft = CollectionDraft(existingID: nil, name: "", works: save ? filtered : [])
    }
}

/// The draft owns a snapshot of the exact results the user chose to save.
private struct CollectionDraft: Identifiable {
    let id = UUID()
    let existingID: UUID?
    let name: String
    let works: [ManifestWork]
}

private struct CollectionEditor: View {
    @EnvironmentObject var controller: RotationController
    @Environment(\.dismiss) private var dismiss
    let draft: CollectionDraft
    var onSave: (UUID) -> Void
    @State private var name: String
    @State private var error: String?

    init(draft: CollectionDraft, onSave: @escaping (UUID) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.existingID == nil ? "New collection" : "Rename collection").font(.title2.bold())
            if draft.existingID == nil {
                Text(draft.works.isEmpty ? "Create an empty collection, then add artworks from the gallery."
                     : "Save these \(draft.works.count) artworks. You can add or remove works later.")
                    .foregroundStyle(.secondary)
            }
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
    }

    private func save() {
        do {
            let id: UUID
            if let existing = draft.existingID {
                try controller.renameCollection(existing, name: name)
                id = existing
            } else {
                id = try controller.createCollection(name: name, works: draft.works)
            }
            onSave(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// Sheet presentation needs Identifiable; ManifestWork's id already is one.
extension ManifestWork: Identifiable {}

struct GalleryCard: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork
    var removeFromCollection: (() -> Void)? = nil
    var showInfo: () -> Void = {}

    private var isCurrent: Bool { controller.state.current == work.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkThumb(work: work, height: 170)
                .overlay(alignment: .topLeading) { NotesBadge(work: work) }
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
            Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                CollectionMembershipMenu(work: work)
                Spacer()
                WorkActions(work: work)
            }.padding(.top, 3)
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
            if let removeFromCollection {
                Button("Remove from this collection") { removeFromCollection() }
            }
        }

    }
}

/// Marks works that have their own notes, so they can be found from the grid
/// without opening each one.
private struct NotesBadge: View {
    @EnvironmentObject var notes: NotesModel
    let work: ManifestWork

    var body: some View {
        if notes.entry(for: work.id) != nil {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .padding(6)
                .help("Has notes")
                .accessibilityLabel("Has notes")
        }
    }
}

struct CollectionMembershipMenu: View {
    @EnvironmentObject var controller: RotationController
    let work: ManifestWork

    var body: some View {
        Menu {
            if controller.state.collections.isEmpty {
                Text("Create a collection in the gallery first")
            } else {
                ForEach(controller.state.collections) { collection in
                    let included = collection.workIDs.contains(work.id)
                    Button {
                        controller.setMembership(collection.id, workID: work.id, included: !included)
                    } label: {
                        Label(collection.name, systemImage: included ? "checkmark" : "plus")
                    }
                }
            }
        } label: { Label("Collections", systemImage: "folder.badge.plus") }
        .font(.caption)
        .menuStyle(.borderlessButton).fixedSize()
        .help("Add to or remove from a collection")
        .accessibilityLabel("Collections for \(work.title)")
    }
}
