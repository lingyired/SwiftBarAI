import Foundation

/// Build-time version stamp used to verify which build is running.
///
/// `major` is sourced from `CFBundleShortVersionString` in the host app's
/// `Info.plist` and should only be bumped on user-visible releases.
///
/// `patch` is a hand-maintained counter that I increment on each
/// non-trivial code change so the user can confirm a fresh build is
/// running by glancing at the "Toggle Plugins" submenu header.
enum AppVersion {
    /// Marketing version, e.g. "1.6.2". Sourced from Info.plist.
    static var major: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Build number, e.g. "170". Sourced from Info.plist.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Hand-maintained sub-version. Bump this every time a code change is
    /// shipped so the user can see at a glance whether they are running
    /// the latest build.
    static let patch: Int = 28

    /// Short label for the menu, e.g. "v1.6.2 (170-p1)".
    static var shortLabel: String {
        "v\(major) (b\(build)-p\(patch))"
    }

    /// Slightly longer label including the bundle name.
    static var fullLabel: String {
        "SwiftBar \(shortLabel)"
    }
}
