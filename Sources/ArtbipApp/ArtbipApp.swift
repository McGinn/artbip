import AppKit
import ArtbipCore
import ServiceManagement
import SwiftUI

@main
struct ArtbipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = RotationController()

    var body: some Scene {
        MenuBarExtra("artbip", systemImage: "photo.artframe") {
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
        if let work = controller.currentWork {
            Text(work.title)
            Text("\(work.artist)\(work.dateDisplay.map { ", \($0)" } ?? "")")
        } else {
            Text("Nothing shown yet")
        }
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
        Divider()
        Button("Quit artbip") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
