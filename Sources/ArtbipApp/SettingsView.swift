import ArtbipCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: RotationController

    private let intervals = [15, 30, 60, 120, 240, 480, 720, 1440, 2880, 10080, 20160, 43200]
    private let budgets = [512, 1024, 2048, 4096, 8192]

    private func intervalLabel(_ m: Int) -> String {
        switch m {
        case ..<60: "\(m) minutes"
        case 60: "1 hour"
        case ..<1440: "\(m / 60) hours"
        case 1440: "1 day"
        case ..<10080: "\(m / 1440) days"
        case 10080: "1 week"
        case ..<43200: "\(m / 10080) weeks"
        case 43200: "1 month"
        default: "\(m / 43200) months"
        }
    }

    var body: some View {
        Form {
            Section("Rotation") {
                Picker("Change artwork every", selection: Binding(
                    get: { controller.settings.intervalMinutes },
                    set: { v in controller.updateSettings { $0.intervalMinutes = v } })) {
                    ForEach(intervals, id: \.self) { m in
                        Text(intervalLabel(m)).tag(m)
                    }
                }
                Toggle("Rotate favourites only", isOn: Binding(
                    get: { controller.settings.favouritesOnly },
                    set: { v in controller.updateSettings { $0.favouritesOnly = v } }))
            }

            Section("Appearance") {
                Picker("Background", selection: Binding(
                    get: { controller.settings.background },
                    set: { v in
                        controller.updateSettings { $0.background = v }
                        controller.refreshWallpaper()
                    })) {
                    Text("Blurred artwork").tag("blur")
                    Text("Palette colour").tag("palette")
                }
                Toggle("Wall label (title, artist, date)", isOn: Binding(
                    get: { controller.settings.label },
                    set: { v in
                        controller.updateSettings { $0.label = v }
                        controller.refreshWallpaper()
                    }))
                Slider(value: Binding(
                    get: { controller.settings.marginFraction },
                    set: { v in controller.updateSettings { $0.marginFraction = v } }),
                    in: 0.01...0.15) {
                    Text("Margin")
                } minimumValueLabel: {
                    Text("tight").font(.caption)
                } maximumValueLabel: {
                    Text("airy").font(.caption)
                } onEditingChanged: { editing in
                    // Re-compose once at drag end, not per tick mid-drag.
                    if !editing { controller.refreshWallpaper() }
                }
            }

            Section("Storage") {
                Picker("Image cache budget", selection: Binding(
                    get: { controller.settings.cacheBudgetMB },
                    set: { v in controller.updateSettings { $0.cacheBudgetMB = v } })) {
                    ForEach(budgets, id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                }
                LabeledContent("Runtime directory", value: controller.store.dir.path)
            }

            Section("Collection") {
                LabeledContent("Works", value: "\(controller.manifest.works.count)")
                LabeledContent("Favourites", value: "\(controller.state.favourites.count)")
                LabeledContent("Blocked", value: "\(controller.state.blocklist.count)")
                LabeledContent("Left in this cycle", value: "\(controller.state.queue.count)")
            }
        }
        .formStyle(.grouped)
    }
}
