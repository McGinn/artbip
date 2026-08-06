import AppKit
import ArtbipCore
import ServiceManagement
import SwiftUI

@main
struct ArtbipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = RotationController()

    var body: some Scene {
        // A paused artbip looks identical to a broken one from the desktop —
        // say so in the menu bar itself.
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
        } label: {
            MenuBarLabel()
                .environmentObject(controller)
        }

        Window("artbip", id: "main") {
            MainWindow()
                .environmentObject(controller)
        }
        .defaultSize(width: 1080, height: 720)
        // Don't pop the window open when the app launches at login — it lives
        // in the menu bar until asked for.
        .defaultLaunchBehavior(.suppressed)

        // Deliberately spare: no title bar, and sized to its own content rather
        // than a fixed frame. The point of the panel is to read about the work
        // while still looking at it, so it stays small enough to leave the
        // wallpaper visible around it.
        Window("About This Artwork", id: "info") {
            CurrentWorkInfoWindow()
                .environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 560)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Menu-bar-only app: no Dock icon, closing the window keeps it running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The menu-bar icon — and the host for the global shortcut. MenuBarExtra builds
/// its menu content lazily, only while the menu is open, but the label view is
/// alive for the whole session, which is what a global hotkey needs.
struct MenuBarLabel: View {
    @EnvironmentObject var controller: RotationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Image(systemName: controller.state.paused ? "pause.rectangle" : "photo.artframe")
            .onAppear(perform: rebind)
            .onChange(of: controller.settings.shortcuts) { rebind() }
    }

    /// Register every action's shortcut. This lives on the label rather than in
    /// the menu content because the menu is built lazily and torn down when it
    /// closes, whereas a global hotkey has to stay registered all session.
    private func rebind() {
        for action in Shortcut.Action.allCases {
            let sc = controller.settings.shortcut(action)
            let ok = controller.hotKey(for: action)
                .bind(keyCode: sc.code, modifiers: sc.modifiers) { perform(action) }
            controller.shortcutRejected[action.rawValue] = sc.isBound && !ok
        }
    }

    private func perform(_ action: Shortcut.Action) {
        switch action {
        case .info: toggleInfo()
        case .next: if !controller.busy { controller.next() }
        case .favourite:
            if let work = controller.currentWork { controller.toggleFavourite(work.id) }
        }
    }

    /// Toggle, not just open: pressing the shortcut again should put the panel
    /// away without reaching for the mouse.
    private func toggleInfo() {
        if let window = controller.infoWindow, window.isVisible {
            window.close()
        } else {
            openWindow(id: "info")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var controller: RotationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let work = controller.currentWork {
                Text(work.title)
                Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
            } else {
                Text("Nothing shown yet")
            }
            if controller.state.paused {
                Text("Rotation is paused")
            }
        }
        .onAppear { controller.reloadFromDisk() }
        Divider()
        // No .keyboardShortcut anywhere in this menu: inside a MenuBarExtra it
        // only becomes an NSMenu key equivalent, which fires while the menu is
        // open and never otherwise — a menu advertising ⌘N would be lying. Any
        // shortcut shown here is the global one from Settings.
        Button(menuTitle(controller.busy ? "Rotating…" : "Next Artwork", .next)) {
            controller.next()
        }
        .disabled(controller.busy)
        Button(controller.state.paused ? "Resume Rotation" : "Pause Rotation") {
            controller.togglePause()
        }
        if controller.hasOriginalWallpaper {
            Button("Restore Original Wallpaper") { controller.restoreOriginalWallpaper() }
                .disabled(controller.busy)
        }
        if let work = controller.currentWork {
            Button(menuTitle(controller.isFavourite(work.id) ? "Unfavourite" : "Favourite",
                             .favourite)) {
                controller.toggleFavourite(work.id)
            }
            Button("Never Show Again") { controller.block(work.id) }
            Button(menuTitle("About This Artwork…", .info)) {
                openWindow(id: "info")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("View at \(work.collectionLinkTitle)") {
                if let url = URL(string: work.collectionURL) { NSWorkspace.shared.open(url) }
            }
            Menu("Report a Problem…") {
                Button("Problem with this artwork…") { Feedback.reportArtwork(work) }
                Button("Problem with the info text…") { Feedback.reportInfoText(work) }
            }
        }
        Divider()
        Button("Open artbip…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        LaunchAtLoginToggle()
        Menu("Feedback") {
            Button("Request a Feature…") { Feedback.requestFeature() }
            Button("Browse Open Requests…") { Feedback.browseIssues() }
        }
        Button("About artbip") { showAbout() }
        Divider()
        Button("Quit artbip") { NSApp.terminate(nil) }
    }

    /// Menu title with the action's global shortcut appended, when it has one.
    private func menuTitle(_ title: String, _ action: Shortcut.Action) -> String {
        let sc = controller.settings.shortcut(action)
        return sc.isBound ? "\(title)  \(sc.label)" : title
    }

    /// The open-access programmes the collection is actually drawn from, keyed
    /// by work-id prefix so the counts come from the manifest rather than a
    /// number that quietly goes stale. Every URL here was checked to resolve;
    /// metmuseum.org and nga.gov refuse scripted requests, so those two point
    /// at the institutions' own open-data repositories instead.
    private static let providers: [(prefix: String, name: String, url: String)] = [
        ("wikidata", "Wikimedia Commons", "https://commons.wikimedia.org/"),
        ("met", "The Metropolitan Museum of Art", "https://github.com/metmuseum/openaccess"),
        ("nga", "National Gallery of Art", "https://github.com/NationalGalleryOfArt/opendata"),
        ("rijks", "Rijksmuseum", "https://www.rijksmuseum.nl/en/rijksstudio"),
        ("artic", "Art Institute of Chicago", "https://www.artic.edu/open-access"),
        ("cleveland", "Cleveland Museum of Art", "https://www.clevelandart.org/open-access"),
    ]

    /// macOS's standard About panel, populated with the bundle version and a
    /// licence/provenance note. An accessory app has no app menu, so this is
    /// the only place "About artbip" can live.
    private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"

        let body = NSFont.systemFont(ofSize: 11)
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        let dim: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.secondaryLabelColor]

        var counts: [String: Int] = [:]
        for work in controller.manifest.works {
            let prefix = work.id.split(separator: "-").first.map(String.init) ?? ""
            counts[prefix, default: 0] += 1
        }

        let credits = NSMutableAttributedString(
            string: """
            Live with great paintings.

            Every painting here is public domain or CC0, released by institutions \
            that chose to put high-resolution images of their collections into the \
            commons for anyone to use. That work is what makes artbip possible:

            """,
            attributes: plain)

        for provider in Self.providers where (counts[provider.prefix] ?? 0) > 0 {
            credits.append(NSAttributedString(string: "\n  ", attributes: plain))
            credits.append(NSAttributedString(
                string: provider.name,
                attributes: [.font: body, .link: URL(string: provider.url)!]))
            credits.append(NSAttributedString(
                string: "  \(counts[provider.prefix] ?? 0) works", attributes: dim))
        }

        credits.append(NSAttributedString(
            string: """


            Code is MIT-licensed; each work's source and licence is recorded in \
            the manifest.

            """,
            attributes: plain))
        credits.append(NSAttributedString(
            string: "github.com/McGinn/artbip",
            attributes: [.font: body, .link: URL(string: "https://github.com/McGinn/artbip")!]))
        credits.append(NSAttributedString(string: "\n", attributes: plain))
        credits.append(NSAttributedString(
            string: "Sponsor artbip",
            attributes: [.font: body, .link: URL(string: "https://github.com/sponsors/McGinn")!]))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: version,
            .credits: credits,
        ]
        if let build = info?["CFBundleVersion"] as? String { options[.version] = build }

        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    // SMAppService only works from a real .app bundle; hide it under `swift run`.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        if isBundled {
            Toggle("Launch at Login", isOn: Binding(
                get: { enabled },
                set: { on in
                    do {
                        if on {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        enabled = on
                    } catch {
                        enabled = SMAppService.mainApp.status == .enabled
                    }
                }))
        }
    }
}
