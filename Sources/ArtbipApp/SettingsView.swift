import ArtbipCore
import SwiftUI

/// A single row in the "Change artwork" picker: a fixed sub-daily interval, or
/// one of the clock-anchored cadences that reveal extra controls below.
private enum RotationChoice: Hashable {
    case interval(Int)   // minutes
    case daily, weekly, monthly
}

struct SettingsView: View {
    @EnvironmentObject var controller: RotationController

    private let budgets = [512, 1024, 2048, 4096, 8192]

    // Sub-daily cadences offered directly. Anything coarser is a clock schedule
    // (daily/weekly/monthly) so it fires at a predictable time of day.
    private let intervals = [15, 30, 60, 120, 180, 360, 720]

    private func intervalLabel(_ m: Int) -> String {
        switch m {
        case ..<60: return "Every \(m) minutes"
        case 60: return "Every hour"
        default: return m % 60 == 0 ? "Every \(m / 60) hours" : "Every \(m) minutes"
        }
    }

    // Always include the stored interval so a legacy value never leaves the
    // picker blank; new installs just see the standard list.
    private var intervalOptions: [Int] {
        let m = controller.settings.intervalMinutes
        return (intervals.contains(m) || controller.settings.scheduleMode != "interval")
            ? intervals : (intervals + [m]).sorted()
    }

    private var currentChoice: RotationChoice {
        switch controller.settings.scheduleMode {
        case "daily": return .daily
        case "weekly": return .weekly
        case "monthly": return .monthly
        default: return .interval(controller.settings.intervalMinutes)
        }
    }

    private func apply(_ choice: RotationChoice) {
        controller.updateSettings { s in
            switch choice {
            case .interval(let m): s.scheduleMode = "interval"; s.intervalMinutes = m
            case .daily: s.scheduleMode = "daily"
            case .weekly: s.scheduleMode = "weekly"
            case .monthly: s.scheduleMode = "monthly"
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: controller.settings.scheduleHour,
                                      minute: controller.settings.scheduleMinute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                controller.updateSettings {
                    $0.scheduleHour = c.hour ?? 9
                    $0.scheduleMinute = c.minute ?? 0
                }
            })
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        Form {
            Section("Rotation") {
                Picker("Change artwork", selection: Binding(
                    get: { currentChoice },
                    set: { apply($0) })) {
                    ForEach(intervalOptions, id: \.self) { m in
                        Text(intervalLabel(m)).tag(RotationChoice.interval(m))
                    }
                    Text("Every day").tag(RotationChoice.daily)
                    Text("Every week").tag(RotationChoice.weekly)
                    Text("Every month").tag(RotationChoice.monthly)
                }

                // Reveal only the controls the chosen cadence needs.
                if controller.settings.scheduleMode == "weekly" {
                    Picker("On", selection: Binding(
                        get: { controller.settings.scheduleWeekday },
                        set: { v in controller.updateSettings { $0.scheduleWeekday = v } })) {
                        ForEach(1...7, id: \.self) { wd in
                            Text(RotationSchedule.weekdayName(wd)).tag(wd)
                        }
                    }
                }
                if controller.settings.scheduleMode == "monthly" {
                    Picker("On the", selection: Binding(
                        get: { controller.settings.scheduleDay },
                        set: { v in controller.updateSettings { $0.scheduleDay = v } })) {
                        ForEach(1...28, id: \.self) { d in
                            Text(ordinal(d)).tag(d)
                        }
                    }
                }
                if controller.settings.scheduleMode != "interval" {
                    DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
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

            Section("Shortcut") {
                LabeledContent("Show artwork info") {
                    ShortcutRecorder()
                }
                Text("Works from any app. Menu shortcuts only fire while the menu is open, so this is the one that reaches you mid-task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
