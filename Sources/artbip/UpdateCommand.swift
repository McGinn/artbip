import ArgumentParser
import ArtbipCore
import Foundation

/// Report whether a newer release exists.
///
/// The menu-bar app checks once a day on its own, but plenty of people run only
/// the launchd daemon and never open the app, so the check has to be reachable
/// from the CLI too. Prints and exits; it never downloads or installs anything.
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check whether a newer artbip release is available.")

    @Option(help: "Version to compare against (default: this build).")
    var current: String?

    func run() async throws {
        let mine = current
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        do {
            let latest = try await UpdateCheck.fetchLatest()
            switch UpdateCheck.compare(current: mine, against: latest) {
            case .updateAvailable(let version, let url):
                print("update available: \(mine) -> \(version)")
                print(url.absoluteString)
            case .upToDate:
                print("up to date (\(mine); latest release is \(latest.version))")
            }
        } catch {
            // Exit non-zero so a script can tell "no update" from "could not
            // reach GitHub"; both are silent successes otherwise.
            throw ValidationError("could not check for updates: \(error)")
        }
    }
}
