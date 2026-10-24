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
    @State private var confirmClearCache = false

    private let budgets = [512, 1024, 2048, 4096, 8192]
    private var budgetOptions: [Int] { Array(Set(budgets + [controller.settings.cacheBudgetMB])).sorted() }
    private var cacheUsage: String {
        guard let bytes = controller.cacheBytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    #if !ARTBIP_APP_STORE
    /// The answer to the last check: in progress, a newer version, already
    /// the latest, or could not tell — plus when it last succeeded.
    @ViewBuilder private var updateStatus: some View {
        if controller.updateCheckInProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            }
        } else if case .updateAvailable(let v, _) = controller.availableUpdate {
            Text("Version \(v) is available. You have \(appVersion).").font(.caption)
            Button("Open the Release Page…") { Feedback.openLatestRelease() }
        } else if controller.updateCheckFailed {
            Text("Couldn't reach GitHub to check for updates. Try again later.")
                .font(.caption).foregroundStyle(.secondary)
        } else if case .upToDate = controller.availableUpdate {
            Text(AppVersion(appVersion) == nil
                 ? "This is a development build, so it isn't compared with releases."
                 : "artbip \(appVersion) is the latest version.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let last = controller.settings.lastUpdateCheck, !controller.updateCheckInProgress {
            Text("Last checked \(last.formatted(.relative(presentation: .named))).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    #endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

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
            Section("Rotation status") {
                Text(controller.diagnostics.summary)
                    .font(.caption).textSelection(.enabled)
            }
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

                Picker("Rotate from", selection: Binding(
                    get: { controller.rotationSource },
                    set: { controller.selectRotationSource($0) })) {
                    Text("All artworks").tag("all")
                    Text("Favourites").tag("favourites")
                    ForEach(controller.state.collections) { collection in
                        Text(collection.name).tag(collection.id.uuidString)
                    }
                }
                if Rotator.eligible(controller.manifest, state: controller.state, settings: controller.settings).isEmpty {
                    Text("No artworks available in this rotation source. Add works or choose another source.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Content") {
                Toggle("Hide NSFW artworks", isOn: Binding(
                    get: { controller.settings.hideNSFW },
                    set: { controller.setHideNSFW($0) }))
                Text("Leaves out works with explicit nudity, sexual content or graphic violence, in rotation and in the gallery.")
                    .font(.caption).foregroundStyle(.secondary)
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

            Section("Shortcuts") {
                ForEach(Shortcut.Action.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                }
                Text("Every shortcut here works from any app, whichever one you are in. There are no menu-only shortcuts: inside a menu-bar app those fire only while the menu is already open, which is no use mid-task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Downloaded images", value: cacheUsage)
                Picker("Maximum download storage", selection: Binding(
                    get: { controller.settings.cacheBudgetMB },
                    set: { v in controller.updateSettings { $0.cacheBudgetMB = v } })) {
                    ForEach(budgetOptions, id: \.self) { mb in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .binary)).tag(mb)
                    }
                }
                Text("Original images and thumbnails share this limit. The least recently used downloads are removed automatically. Saved collections and favourites are kept; images download again when needed.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(controller.clearingCache ? "Clearing…" : "Clear downloaded images…") {
                        confirmClearCache = true
                    }.disabled(controller.clearingCache || controller.busy || controller.cacheBytes == 0)
                    Button("Refresh usage") { Task { await controller.refreshCacheUsage() } }
                        .disabled(controller.clearingCache)
                }
                if let message = controller.cacheMessage {
                    Text(message).font(.caption).textSelection(.enabled)
                }
            }

            #if ARTBIP_APP_STORE
            // Mac App Store builds update only through the App Store
            // (App Review 2.4.5(vii)), and carry no external payment or
            // sponsorship links.
            Section("Updates") {
                LabeledContent("This version", value: appVersion)
                Text("Updates arrive through the Mac App Store.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Support") {
                if Feedback.writeReviewURL != nil {
                    Button("Rate artbip on the App Store…") { Feedback.rateOnAppStore() }
                }
                Button("Request a Feature…") { Feedback.requestFeature() }
                Text("artbip is free, with no account or subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            Section("Updates") {
                LabeledContent("This version", value: appVersion)
                updateStatus
                Toggle("Check for new versions", isOn: Binding(
                    get: { controller.settings.updateCheckEnabled },
                    set: { v in controller.updateSettings { $0.updateCheckEnabled = v } }))
                Button("Check Now") { controller.checkForUpdate(force: true) }
                    .disabled(controller.updateCheckInProgress)
                Text("When it starts, at most once a day, artbip asks GitHub whether a newer release exists. The request carries nothing about you or how you use the app. Apart from this, artbip only downloads artwork images from museum and Wikimedia servers. With checks off, new versions — including corrections to the collection — will not reach you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Support") {
                Button("Sponsor artbip…") { Feedback.sponsor() }
                Button("Request a Feature…") { Feedback.requestFeature() }
                Text("artbip is free and open source, with no account or subscription. Sponsorship is a way to say thanks; it unlocks nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Collection") {
                LabeledContent("Works", value: "\(controller.manifest.works.count)")
                LabeledContent("Favourites", value: "\(controller.state.favourites.count)")
                LabeledContent("Blocked", value: "\(controller.state.blocklist.count)")
                LabeledContent("Left in this cycle", value: "\(controller.state.queue.count)")
            }
        }
        .formStyle(.grouped)
        .task { await controller.refreshCacheUsage() }
        .confirmationDialog("Clear downloaded images?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear Downloads", role: .destructive) { Task { await controller.clearDownloads() } }
        } message: {
            Text("Removes downloaded originals and thumbnails. Your current wallpaper, saved collections, favourites, history and settings are kept. Images will download again when needed, so they will need an internet connection.")
        }
    }
}
