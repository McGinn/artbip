import ArgumentParser
import ArtbipCore
import Foundation

/// Print the settings the app has actually resolved, as opposed to the raw
/// JSON on disk.
///
/// The two differ whenever defaults fill a missing key, a value is clamped, or
/// an older file is migrated to a newer shape — all of which are invisible if
/// you only `cat settings.json`. Several settings (panel opacity, shortcuts)
/// are edited by hand, so there needs to be a way to see what the app made of
/// the edit.
struct SettingsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Show the resolved settings, including defaults and migrations.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let store = try opts.store()
        let s = store.loadSettings()

        print("rotation")
        print("  schedule            \(s.scheduleMode) (every \(s.intervalMinutes) min)")
        print("  favourites only     \(s.favouritesOnly)")
        print("\ncomposition")
        print("  background          \(s.background)")
        print("  wall label          \(s.label)")
        print("  margin              \(String(format: "%.3f", s.marginFraction))")
        print("\ninfo panel")
        print("  window opacity      \(String(format: "%.2f", s.infoWindowOpacity))")
        print("  artist expanded     \(s.infoArtistExpanded)")
        print("  school expanded     \(s.infoSchoolExpanded)")
        print("\nglobal shortcuts")
        for action in Shortcut.Action.allCases {
            let sc = s.shortcut(action)
            let shown = sc.isBound ? "\(sc.label)  (code \(sc.code), mods \(sc.modifiers))"
                                   : "not set"
            print("  \(action.title.padding(toLength: 24, withPad: " ", startingAt: 0))\(shown)")
        }
        print("\nstorage")
        print("  cache budget        \(s.cacheBudgetMB) MB")
        print("  prefetch            \(s.prefetchCount)")
    }
}
