import Foundation
import os

/// A folder-based plugin that derives its configuration from a `manifest.json`
/// file inside the directory (in contrast to `PackagedPlugin`, which is keyed
/// off the `.swiftbar` suffix and reads metadata from the entry script).
///
/// Folder layout:
/// ```
/// my-plugin/
///   manifest.json     (required)
///   plugin.sh         (declared in `entry`; must be executable)
///   icon.png          (optional)
///   ...               (helper scripts, libraries, etc.)
/// ```
class FolderPlugin: PackagedPlugin {
    /// Parsed contents of the plugin's `manifest.json`.
    let manifest: PluginManifest

    /// Initializes a folder plugin from a directory containing a `manifest.json`.
    /// Returns `nil` if the manifest is missing, malformed, or its declared
    /// entry script does not exist.
    init?(manifestDirectory: URL) {
        let manifestURL = manifestDirectory.appendingPathComponent(pluginManifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            os_log("Skipping folder %{public}@: no manifest.json", log: Log.plugin, type: .debug, manifestDirectory.path)
            return nil
        }

        guard let (loaded, entryURL) = PluginManifestLoader.loadAndValidate(from: manifestDirectory) else {
            return nil
        }

        self.manifest = loaded
        // The designated `PackagedPlugin` init already marks the entry script
        // executable via `makeScriptExecutable(file:)`, so we don't need to
        // re-do it here.
        super.init(packageDirectory: manifestDirectory, mainExecutable: entryURL)

        // Override what `PackagedPlugin.init` discovered (it looked for a
        // `plugin.*` file based on directory name) with the manifest-declared
        // entry point and metadata.
        applyManifestOverrides(loaded)
    }

    // MARK: - Manifest → Plugin state

    private func applyManifestOverrides(_ manifest: PluginManifest) {
        if manifest.resolvedType != type {
            type = manifest.resolvedType
        }
        if let name = manifest.name, !name.isEmpty {
            self.name = name
        }
        if let schedule = manifest.schedule, !schedule.isEmpty {
            self.metadata?.schedule = schedule
        }
        if let interval = manifest.refreshInterval, interval > 0 {
            self.updateInterval = interval
        }
        if let env = manifest.environment {
            self.refreshEnv.merge(env) { _, new in new }
        }
        if let parameters = manifest.parameters {
            self.metadata?.variables = parameters.map { $0.toPluginVariable() }
        }
    }

    // MARK: - Environment

    override var env: [String: String] {
        var pluginEnv = super.env
        // Manifest-declared environment is layered *after* super.env so it
        // wins over defaults, mirroring the script-metadata convention.
        if let environment = manifest.environment {
            for (k, v) in environment {
                pluginEnv[k] = v
            }
        }
        return pluginEnv
    }
}
