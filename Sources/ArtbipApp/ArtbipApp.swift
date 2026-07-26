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
        MenuBarExtra("artbip", systemImage: controller.state.paused ? "pause.rectangle" : "photo.artframe") {
            MenuContent()
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
        Button(controller.busy ? "Rotating…" : "Next Artwork") { controller.next() }
            .keyboardShortcut("n")
            .disabled(controller.busy)
        Button(controller.state.paused ? "Resume Rotation" : "Pause Rotation") {
            controller.togglePause()
        }
        if controller.hasOriginalWallpaper {
            Button("Restore Original Wallpaper") { controller.restoreOriginalWallpaper() }
                .disabled(controller.busy)
        }
        if let work = controller.currentWork {
            Button(controller.isFavourite(work.id) ? "Unfavourite" : "Favourite") {
                controller.toggleFavourite(work.id)
            }
            .keyboardShortcut("f")
            Button("Never Show Again") { controller.block(work.id) }
            Button("View at \(work.collection)") {
                if let url = URL(string: work.collectionURL) { NSWorkspace.shared.open(url) }
            }
        }
        Divider()
        Button("Open artbip…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        LaunchAtLoginToggle()
        Button("About artbip") { showAbout() }
        Divider()
        Button("Quit artbip") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// macOS's standard About panel, populated with the bundle version and a
    /// licence/provenance note. An accessory app has no app menu, so this is
    /// the only place "About artbip" can live.
    private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"

        let body = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString(
            string: """
            Live with great paintings.

            Code is MIT-licensed. The 2,000-painting collection is public domain / CC0, \
            with each work's source and licence recorded in the manifest.

            Images come from the open-access programs of the Art Institute of Chicago, \
            the Met, Cleveland, the National Gallery of Art, the Rijksmuseum, and \
            Wikimedia Commons.

            """,
            attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "github.com/McGinn/artbip",
            attributes: [.font: body, .link: URL(string: "https://github.com/McGinn/artbip")!]))

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
