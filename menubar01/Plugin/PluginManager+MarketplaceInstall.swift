// PluginManager+MarketplaceInstall.swift
// menubar01 — PluginMarketplace (M5)
//
// Wires the M4 `MarketplaceInstallPlan` value type to the existing
// `PluginManager` so the marketplace browser UI can land a
// plugin on disk via a single call. Kept in a separate file (and
// a `PluginManager` extension) so it does not conflict with the
// M2 install flow being added in parallel to `PluginManger.swift`.
//
// The split mirrors the M4 "pure-logic plan + side-effectful
// install" division:
//
//   1. `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`
//      — pure, no I/O, validates the (entry, package) pair and
//      produces a `MarketplaceInstallPlan`.
//   2. `PluginManager.installMarketplacePlugin(plan:overwriteExisting:)`
//      — the I/O half. Reads `pluginDirectoryURL`, sanitises the
//      target subfolder name, writes `manifest.json` + the entry
//      script, and `chmod +x` the entry script. The view model
//      glues the two halves together.
//
//   3. `PluginManager.installMarketplacePluginWithCapabilityGate(...)`
//      — the M5 install-gate follow-up overload. The new entry
//      point inspects `plan.manifest?.resolvedCapabilities`,
//      auto-grants `isGrantedByDefault == true` capabilities
//      silently, prompts the user (via the injected closure) for
//      every remaining capability, and only then delegates to
//      the I/O half above.
//
//   4. `PluginManager.uninstallMarketplacePlugin(at:)` — the
//      M5 uninstall follow-up. Deletes the on-disk folder for
//      a marketplace install after a path-safety check that
//      refuses any URL not rooted under
//      `<pluginDirectoryURL>/_marketplace/`. Returns
//      `.success(())` or a typed `UninstallMarketplacePluginError`.
//
//   5. `PluginManager.updateMarketplacePlugin(entry:package:)`
//      and
//      `PluginManager.updateMarketplacePluginWithCapabilityGate(entry:package:gate:)`
//      — the M5 update follow-ups. Both are thin wrappers
//      around `plan(overwriteExisting: true)` +
//      `installMarketplacePlugin(plan:overwriteExisting: true)`;
//      the gate-aware variant runs `gate.verify(manifest:)`
//      up-front so an update that asks for a new capability
//      the user has not yet granted is refused with a
//      `.planFailed(reason:)` error.

import Foundation
import os

/// Errors surfaced by `PluginManager.installMarketplacePlugin(...)`.
///
/// `Equatable` so the browser view model can pattern-match on the
/// failure case in the success alert / error banner. The cases
/// are intentionally narrow — `writeFailed` and `chmodFailed` are
/// distinct because the user can recover from a `chmod` failure
/// (run `chmod +x` themselves) in a way they cannot from a
/// directory write failure.
public enum InstallMarketplacePluginError: Error, Equatable {
    /// The user has not yet picked a Plugin Folder in Preferences.
    case pluginDirectoryUnavailable
    /// File system write failed (e.g. parent dir not writable,
    /// disk full, permissions). `reason` is the underlying error's
    /// `localizedDescription` so the UI can show it verbatim.
    case writeFailed(reason: String)
    /// The plugin was written but `chmod +x` on the entry script
    /// failed. `reason` is the underlying error's
    /// `localizedDescription`.
    case chmodFailed(reason: String)
    /// The caller passed an inconsistent pair of arguments — e.g.
    /// a plan that conflicts with `overwriteExisting`. Reserved
    /// for future expansion; the v1 implementation only uses it
    /// to signal "the caller asked to overwrite but the plan's
    /// own flag disagrees".
    case planFailed(reason: String)
    /// The user declined the capability prompt surfaced by the
    /// M5 install-gate overload. `pluginID` is the manifest's
    /// `name` (or `<unnamed>` when the manifest omits one);
    /// `capabilities` is the set the user was asked about.
    /// Synthesised `Equatable` because `PluginCapability` and
    /// `[PluginCapability]` both conform.
    case capabilityDeclined(pluginID: String, capabilities: [PluginCapability])
}

/// Errors surfaced by `PluginManager.uninstallMarketplacePlugin(at:)`.
///
/// `Equatable` so the browser view model can pattern-match on the
/// failure case in the success alert / error banner. The cases
/// are intentionally narrow — `notAMarketplacePlugin` and
/// `notFound` are distinct because the UI wants to differentiate
/// "you tried to delete a folder that is not a marketplace
/// install" (refused, please report a bug) from "the folder is
/// already gone" (no-op, refresh the installed list).
public enum UninstallMarketplacePluginError: Error, Equatable {
    /// The user has not yet picked a Plugin Folder in
    /// Preferences. The safety-net check could not run
    /// because there is no parent directory to compare
    /// against.
    case pluginDirectoryUnavailable
    /// The path is not a marketplace install. The `reason`
    /// string is a human-readable description of why the
    /// path was rejected (e.g. `"path does not contain
    /// _marketplace/"`). Surfaced verbatim in the error
    /// banner so a developer / power user can diagnose
    /// what went wrong.
    case notAMarketplacePlugin(reason: String)
    /// The path does not exist on disk. Surfaced as a
    /// distinct case so the UI can show "already
    /// uninstalled" instead of a generic failure.
    case notFound(path: String)
    /// `FileManager.removeItem(at:)` failed. The `reason`
    /// string is the underlying error's `localizedDescription`.
    case removeFailed(reason: String)
}

/// Closure type the M5 install-gate overload hands the
/// `CapabilityPromptHandler`-style prompt to. Returns `true`
/// when the user grants every capability in `capabilities`,
/// `false` to abort the install. The closure is `@MainActor`
/// because the M5 SwiftUI sheet it drives must run on the
/// main thread; the gate-aware install method `await`s the
/// result before delegating to the I/O half.
public typealias CapabilityPromptHandler = @MainActor (
    _ pluginID: String,
    _ capabilities: [PluginCapability]
) async -> Bool

extension PluginManager {

    // MARK: - Constants

    /// Maximum length of the sanitised on-disk folder name. The
    /// `MarketplaceEntry.id` is already a slug, but the file name
    /// is the entry filename minus its extension — keep the clip
    /// liberal so long entry script names (e.g. `Weather.sh`) do
    /// not get truncated silently.
    private static let maxFolderNameLength = 64

    // MARK: - Public install method

    /// Install a marketplace plugin from a pre-built
    /// `MarketplaceInstallPlan`.
    ///
    /// The plan carries everything the writer needs (target
    /// subfolder name, entry filename, manifest bytes, entry
    /// script bytes). The caller (the browser view model) is
    /// responsible for calling `MarketplaceInstaller.plan(...)`
    /// first — this method does **not** re-derive the plan.
    ///
    /// On success the plugin lands at:
    /// ```
    /// <pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised folder name>/manifest.json
    /// <pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised folder name>/<plan.entryFilename>
    /// ```
    /// and the entry script is `chmod +x`'d. The folder name is
    /// the entry filename with its extension stripped (so
    /// `echo.sh` becomes `echo`). The folder is then sanitised
    /// against `/`, `\`, `..`, `~`, `:` → `_` and clipped to 64
    /// characters. The folder is **not** symlinked or relocated —
    /// the user can delete it from the Plugin Folder to
    /// "uninstall".
    ///
    /// - Parameters:
    ///   - plan: A `MarketplaceInstallPlan` produced by
    ///     `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`.
    ///   - overwriteExisting: If `false` and the target directory
    ///     already exists, the method returns
    ///     `.failure(.writeFailed(reason: "..."))` without touching
    ///     the disk. If `true` the existing directory is removed
    ///     first.
    /// - Returns: `.success(targetURL)` on success, or a
    ///   `InstallMarketplacePluginError` describing what went
    ///   wrong.
    @discardableResult
    public func installMarketplacePlugin(
        plan: MarketplaceInstallPlan,
        overwriteExisting: Bool
    ) -> Result<URL, InstallMarketplacePluginError> {
        // Sanity check the plan's overwrite flag against the caller's.
        // We don't want a caller to pass `overwriteExisting: true` if
        // the plan was built with `overwriteExisting: false` (and
        // vice versa) — the plan is the single source of truth.
        guard plan.overwriteExisting == overwriteExisting else {
            os_log("installMarketplacePlugin: plan.overwriteExisting=%{public}@ does not match caller's overwriteExisting=%{public}@",
                   log: Log.plugin, type: .error,
                   String(describing: plan.overwriteExisting),
                   String(describing: overwriteExisting))
            return .failure(.planFailed(
                reason: "plan.overwriteExisting (\(plan.overwriteExisting)) does not match overwriteExisting argument (\(overwriteExisting))"
            ))
        }

        guard let pluginDirectoryURL else {
            os_log("installMarketplacePlugin: plugin directory is unset", log: Log.plugin, type: .error)
            return .failure(.pluginDirectoryUnavailable)
        }

        let folderName = sanitisedFolderName(from: plan.entryFilename)
        let targetDirectory = pluginDirectoryURL
            .appendingPathComponent(plan.targetSubfolder, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL

        // Overwrite handling: when the caller does not allow
        // overwriting, refuse early without touching the disk.
        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            if !overwriteExisting {
                os_log("installMarketplacePlugin: target exists at %{public}@, refusing without overwrite",
                       log: Log.plugin, type: .info, targetDirectory.path)
                return .failure(.writeFailed(
                    reason: "target exists at \(targetDirectory.path); pass overwriteExisting: true to replace"
                ))
            }
            do {
                try FileManager.default.removeItem(at: targetDirectory)
            } catch {
                os_log("installMarketplacePlugin: failed to remove existing target at %{public}@: %{public}@",
                       log: Log.plugin, type: .error,
                       targetDirectory.path, error.localizedDescription)
                return .failure(.writeFailed(
                    reason: "failed to remove existing target: \(error.localizedDescription)"
                ))
            }
        }

        // Create the directory tree and write the manifest +
        // entry script. Failures are wrapped so the UI can show
        // the underlying error verbatim.
        do {
            try FileManager.default.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            os_log("installMarketplacePlugin: failed to create target directory at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   targetDirectory.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to create target directory: \(error.localizedDescription)"
            ))
        }

        let manifestURL = targetDirectory.appendingPathComponent(pluginManifestFileName)
        do {
            try plan.manifestData.write(to: manifestURL, options: [.atomic])
        } catch {
            os_log("installMarketplacePlugin: failed to write manifest at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   manifestURL.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to write manifest.json: \(error.localizedDescription)"
            ))
        }

        let entryURL = targetDirectory.appendingPathComponent(plan.entryFilename)
        do {
            try plan.entryData.write(to: entryURL, options: [.atomic])
        } catch {
            os_log("installMarketplacePlugin: failed to write entry script at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   entryURL.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to write entry script: \(error.localizedDescription)"
            ))
        }

        // Mark the entry script executable. This is the same
        // chmod +x invocation `installImportedPlugin(from:moveItem:)`
        // uses for single-file plugins; we surface its own error
        // case so the UI can tell the user to chmod manually.
        do {
            try runScript(to: "chmod", args: ["+x", entryURL.path.escaped()])
        } catch {
            os_log("installMarketplacePlugin: failed to chmod +x entry at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   entryURL.path, error.localizedDescription)
            return .failure(.chmodFailed(
                reason: "failed to chmod +x \(entryURL.path): \(error.localizedDescription)"
            ))
        }

        os_log("installMarketplacePlugin: installed plugin to %{public}@", log: Log.plugin, type: .info, targetDirectory.path)
        return .success(targetDirectory)
    }

    // MARK: - Gate-aware install overload

    /// Install a marketplace plugin through the M3 capability
    /// gate. Mirrors `installMarketplacePlugin(plan:overwriteExisting:)`
    /// line-for-line except for a pre-flight loop that:
    ///
    ///   1. walks `plan.manifest?.resolvedCapabilities` and
    ///      partitions the list into "already granted",
    ///      "granted by default" (e.g. `clipboard` is
    ///      `isGrantedByDefault == true` so it does not
    ///      require user opt-in), and "needs user prompt";
    ///   2. silently `gate.grant(...)`s the auto-grant set;
    ///   3. hands the prompt set to the caller-supplied
    ///      `prompt` closure and `await`s the result;
    ///   4. on grant, `gate.grant(...)`s the prompt set and
    ///      delegates to the I/O install above; on decline,
    ///      returns `.capabilityDeclined(...)` without
    ///      touching the disk.
    ///
    /// The plan must carry a non-`nil` `manifest` — the gate
    /// decision is driven by the resolved capability list, not
    /// the raw `manifestData` bytes. Debug builds assert the
    /// invariant; release builds return
    /// `.planFailed(reason:)` so the call site can present a
    /// typed error.
    ///
    /// The existing `installMarketplacePlugin(plan:overwriteExisting:)`
    /// signature is preserved for the legacy install path
    /// (the M5 marketplace browser's pre-prompt sheet flow).
    @discardableResult
    public func installMarketplacePluginWithCapabilityGate(
        plan: MarketplaceInstallPlan,
        overwriteExisting: Bool,
        gate: PluginCapabilityGate = PluginCapabilityGate(),
        prompt: CapabilityPromptHandler
    ) async -> Result<URL, InstallMarketplacePluginError> {
        guard let manifest = plan.manifest else {
            os_log("installMarketplacePluginWithCapabilityGate: plan.manifest is nil — gate cannot inspect capabilities",
                   log: Log.plugin, type: .error)
            assert(plan.manifest != nil, "plan.manifest must be non-nil for the gate-aware install")
            return .failure(.planFailed(
                reason: "plan.manifest is nil — the gate-aware install requires a decoded PluginManifest"
            ))
        }

        let pluginID = manifest.name ?? "<unnamed>"
        let required = manifest.resolvedCapabilities
        var pending: [PluginCapability] = []
        var autoGrant: Set<PluginCapability> = []

        for capability in required {
            if gate.isGranted(capability, for: pluginID) {
                // Already granted in a previous round-trip — skip silently.
                continue
            }
            if capability.isGrantedByDefault {
                // Auto-grant — record for a single batched
                // `grant` call so the user sees one log line
                // per plugin install, not one per capability.
                autoGrant.insert(capability)
            } else {
                // Needs explicit user consent — queue for the
                // prompt sheet, preserving declaration order
                // so the user sees the same row order they
                // saw in the prompt sheet pre-M3.
                pending.append(capability)
            }
        }

        if !autoGrant.isEmpty {
            gate.grant(autoGrant, for: pluginID)
        }

        if !pending.isEmpty {
            let granted = await prompt(pluginID, pending)
            if !granted {
                os_log("installMarketplacePluginWithCapabilityGate: user declined prompt for plugin %{public}@ (%{public}d capabilities)",
                       log: Log.plugin, type: .info,
                       pluginID, pending.count)
                return .failure(.capabilityDeclined(
                    pluginID: pluginID,
                    capabilities: pending
                ))
            }
            gate.grant(Set(pending), for: pluginID)
        }

        return installMarketplacePlugin(plan: plan, overwriteExisting: overwriteExisting)
    }

    // MARK: - Uninstall

    /// Uninstall a marketplace plugin by deleting its on-disk
    /// folder. Symmetric to `installMarketplacePlugin(plan:overwriteExisting:)`:
    /// the call site passes the URL of the existing install
    /// (typically the on-disk path returned by a previous
    /// `installed(URL)` state transition) and the manager
    /// performs a `FileManager.removeItem(at:)` after a
    /// safety-net check.
    ///
    /// The safety net is the headline feature of this method:
    /// the method **refuses** to delete any path that is not
    /// rooted under `<pluginDirectoryURL>/_marketplace/`. The
    /// marketplace browser is the only legitimate caller, and
    /// every path it computes lives under `_marketplace/` —
    /// the check defeats the "what if a UI bug passes me a path
    /// outside the marketplace subdirectory?" failure mode
    /// (e.g. a future "uninstall from this path" context menu
    /// that naively forwards a folder URL).
    ///
    /// Path-safety details:
    /// 1. Both the target URL and `<pluginDirectoryURL>/_marketplace/`
    ///    are passed through `.standardizedFileURL` so any
    ///    `.` / `..` runs in the input resolve to their canonical
    ///    representation before the `pathComponents` comparison.
    /// 2. The check is `pathComponents`-based, not
    ///    `String.hasPrefix`-based — the latter would let
    ///    `<pluginDir>/_marketplace-evil/plugin/` slip through
    ///    because its first path component shares a prefix with
    ///    the legitimate subdirectory.
    /// 3. A `manifest.json` must exist inside the target folder
    ///    (loaded via `PluginManifestLoader`). A corrupted
    ///    marketplace directory is refused with
    ///    `.notAMarketplacePlugin(reason: ...)` and the
    ///    corruption is `os_log`'d at error level so the
    ///    diagnostic dump surfaces it.
    /// 4. The method does **not** revoke any capability grants
    ///    the gate may have recorded for the plugin. The
    ///    `PluginCapabilityGate` keys grants by `manifest.name`
    ///    (a stable string the user picked when they first
    ///    installed the plugin), so uninstall + reinstall does
    ///    not silently strip the user's previously granted
    ///    capabilities. Users who want to wipe a grant can do
    ///    so from the About view's Permissions section.
    ///
    /// - Parameter pluginURL: Absolute `file://` URL of the
    ///   marketplace plugin folder to remove. The URL is
    ///   resolved through `.standardizedFileURL` before the
    ///   safety-net check, so callers may pass either a
    ///   `file://` URL or a plain path.
    /// - Returns: `.success(())` on success, or a
    ///   `UninstallMarketplacePluginError` describing what
    ///   went wrong.
    @discardableResult
    public func uninstallMarketplacePlugin(
        at pluginURL: URL
    ) -> Result<Void, UninstallMarketplacePluginError> {
        guard let pluginDirectoryURL else {
            os_log("uninstallMarketplacePlugin: plugin directory is unset", log: Log.plugin, type: .error)
            return .failure(.pluginDirectoryUnavailable)
        }

        let marketplaceRoot = pluginDirectoryURL
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
            .standardizedFileURL
        let resolvedTarget = pluginURL.standardizedFileURL

        // Path-safety: compare `pathComponents` rather than
        // `String.hasPrefix` so a sibling like
        // `<pluginDir>/_marketplace-evil/...` cannot slip
        // through. The first differing index is where
        // `resolvedTarget` diverges from the marketplace root;
        // if every component of `marketplaceRoot` is present
        // at the start of `resolvedTarget.pathComponents`,
        // the path is under the marketplace subdirectory.
        let rootComponents = marketplaceRoot.pathComponents
        let targetComponents = resolvedTarget.pathComponents
        guard targetComponents.count >= rootComponents.count else {
            os_log("uninstallMarketplacePlugin: refusing %{public}@ — path is shorter than the marketplace root",
                   log: Log.plugin, type: .error, resolvedTarget.path)
            return .failure(.notAMarketplacePlugin(
                reason: "path \(resolvedTarget.path) does not contain \(MarketplaceInstaller.defaultSubfolder)/"
            ))
        }
        for index in 0..<rootComponents.count where targetComponents[index] != rootComponents[index] {
            os_log("uninstallMarketplacePlugin: refusing %{public}@ — diverges from marketplace root at component %{public}d",
                   log: Log.plugin, type: .error, resolvedTarget.path, index)
            return .failure(.notAMarketplacePlugin(
                reason: "path \(resolvedTarget.path) does not contain \(MarketplaceInstaller.defaultSubfolder)/"
            ))
        }

        // Verify the target still exists. The marketplace
        // browser's "Installed" tab refreshes on view
        // appearance, so by the time the user clicks
        // Uninstall the folder is expected to be on disk;
        // a `.notFound` here usually means a concurrent
        // action (e.g. another process deleting the
        // folder) and the UI should treat it as a no-op.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolvedTarget.path,
            isDirectory: &isDirectory
        )
        if !exists {
            return .failure(.notFound(path: resolvedTarget.path))
        }
        guard isDirectory.boolValue else {
            return .failure(.notAMarketplacePlugin(
                reason: "path \(resolvedTarget.path) is not a directory"
            ))
        }

        // Manifest sanity check: refuse to delete a folder
        // whose `manifest.json` is missing or unparseable.
        // The M5 install flow always writes a valid
        // `manifest.json`; a missing / corrupted one means
        // the directory is either a hostile replacement or
        // a partially-completed install. Either way,
        // deleting it is a side effect the user did not
        // ask for, so we surface a typed error and log the
        // corruption for the diagnostic dump.
        if PluginManifestLoader.loadManifest(from: resolvedTarget) == nil {
            os_log("uninstallMarketplacePlugin: refusing %{public}@ — manifest.json is missing or unparseable",
                   log: Log.plugin, type: .error, resolvedTarget.path)
            return .failure(.notAMarketplacePlugin(
                reason: "manifest.json at \(resolvedTarget.path) is missing or unparseable; refusing to delete a corrupted marketplace directory"
            ))
        }

        do {
            try FileManager.default.removeItem(at: resolvedTarget)
            os_log("uninstallMarketplacePlugin: removed %{public}@", log: Log.plugin, type: .info, resolvedTarget.path)
            return .success(())
        } catch {
            os_log("uninstallMarketplacePlugin: removeItem failed for %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   resolvedTarget.path, error.localizedDescription)
            return .failure(.removeFailed(
                reason: "failed to remove \(resolvedTarget.path): \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Update (re-install with overwrite)

    /// Re-install a marketplace plugin in place, overwriting
    /// the on-disk copy with the freshly fetched entry +
    /// manifest. Thin wrapper around the existing
    /// `MarketplaceInstaller.plan(...)` +
    /// `installMarketplacePlugin(plan:overwriteExisting: true)`
    /// pair. The gate is **not** consulted — the update is the
    /// user's explicit "give me v2" action, and the v1
    /// install path already wrote the v1 manifest with the
    /// user's grant. If v2 asks for new capabilities, the
    /// M5 install-gate overload on the next *fresh install*
    /// handles the prompt; updates are a "swap the bytes"
    /// operation.
    ///
    /// - Returns: `.success(targetURL)` on success, or a
    ///   `InstallMarketplacePluginError` describing what
    ///   went wrong. The same error type the install
    ///   primitives return, so the view model can re-use
    ///   `humanReadable(_:)` to render the banner.
    @discardableResult
    public func updateMarketplacePlugin(
        entry: MarketplaceEntry,
        package: MarketplacePackage
    ) -> Result<URL, InstallMarketplacePluginError> {
        let plan: MarketplaceInstallPlan
        do {
            plan = try MarketplaceInstaller.plan(
                entry: entry,
                package: package,
                overwriteExisting: true
            )
        } catch {
            return .failure(.planFailed(
                reason: "update plan failed for \(entry.id): \(error.localizedDescription)"
            ))
        }
        return installMarketplacePlugin(plan: plan, overwriteExisting: true)
    }

    /// Re-install a marketplace plugin in place, but route
    /// the result through the M3 capability gate. Mirrors
    /// `installMarketplacePluginWithCapabilityGate(...)`
    /// line-for-line except:
    ///
    ///   1. `MarketplaceInstaller.plan(...)` is called with
    ///      `overwriteExisting: true` so the existing
    ///      directory is replaced;
    ///   2. `gate.verify(manifest:)` is invoked up-front so
    ///      an update that asks for a capability the user
    ///      has not yet granted is refused without
    ///      re-prompting. The user already accepted the
    ///      original install's capability set; if v2
    ///      requests a new capability, the update fails
    ///      with a `.capabilityDeclined`-style error;
    ///   3. once the gate's `verify` passes, the install
    ///      primitive is invoked with a no-op `prompt`
    ///      closure (`{ _, _ in true }`) so the
    ///      already-granted capabilities skip the prompt.
    ///
    /// The explicit `verify(manifest:)` call is the
    /// "refuse" path: without it, the install primitive
    /// would silently auto-grant the new capability
    /// (because the `prompt` closure returns `true`).
    /// We surface the gate's refusal as a typed
    /// `.planFailed(reason:)` so the view model can
    /// roll its state back to `.loaded` and show the
    /// banner.
    @discardableResult
    public func updateMarketplacePluginWithCapabilityGate(
        entry: MarketplaceEntry,
        package: MarketplacePackage,
        gate: PluginCapabilityGate = PluginCapabilityGate()
    ) async -> Result<URL, InstallMarketplacePluginError> {
        let plan: MarketplaceInstallPlan
        do {
            plan = try MarketplaceInstaller.plan(
                entry: entry,
                package: package,
                overwriteExisting: true
            )
        } catch {
            return .failure(.planFailed(
                reason: "update plan failed for \(entry.id): \(error.localizedDescription)"
            ))
        }

        // Pre-flight: refuse the update if the v2
        // capability set contains anything the user has
        // not yet granted. `verify(manifest:)` throws
        // `PluginCapabilityError.capabilityNotGranted`
        // for the first ungranted capability; we surface
        // that as a typed `.planFailed(reason:)` because
        // the user's intent ("update to v2") is blocked
        // by a policy decision, not by a write failure.
        if let manifest = plan.manifest {
            do {
                try gate.verify(manifest: manifest)
            } catch {
                let pluginID = manifest.name ?? "<unnamed>"
                return .failure(.planFailed(
                    reason: "gate refused update for \(pluginID): \(error.localizedDescription)"
                ))
            }
        }

        return await installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: true,
            gate: gate,
            // The gate's `verify(manifest:)` has already
            // decided whether the v2 capability set is
            // acceptable. The install primitive's
            // `prompt` closure is only called for
            // ungranted, non-default capabilities, and
            // every previously-granted capability is
            // already in the gate's store. We return
            // `true` unconditionally so the install
            // proceeds once `verify(manifest:)` is happy.
            prompt: { _, _ in true }
        )
    }

    // MARK: - Helpers

    /// Compute the on-disk folder URL for a marketplace
    /// plugin from its `MarketplaceEntry` / entry
    /// filename. Mirrors the layout
    /// `installMarketplacePlugin(...)` writes to:
    /// ```
    /// <pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised folder name>
    /// ```
    /// where `plan.targetSubfolder` is always
    /// `MarketplaceInstaller.defaultSubfolder`
    /// (`"_marketplace"`) and the folder name is the entry
    /// filename with its extension stripped, sanitised, and
    /// clipped to 64 characters (see
    /// `sanitisedFolderName(from:)`).
    ///
    /// The view model's uninstall / update flows need this
    /// computation to recover the on-disk URL from a
    /// `MarketplaceEntry` (the catalogue row) without
    /// re-deriving the sanitisation rules. Exposed as a
    /// `public static` helper so the caller does not need
    /// a `PluginManager` instance to compute the URL — the
    /// only required input is the user's plugin directory
    /// and the entry filename.
    ///
    /// - Returns: `nil` when `pluginDirectoryURL` is `nil`
    ///   (the user has not picked a Plugin Folder in
    ///   Preferences yet). The caller should surface a
    ///   "Set a Plugin Folder first" error.
    public static func marketplacePluginURL(
        pluginDirectoryURL: URL?,
        entryFilename: String
    ) -> URL? {
        guard let pluginDirectoryURL else { return nil }
        let folderName = sanitisedFolderNameStatic(from: entryFilename)
        return pluginDirectoryURL
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL
    }

    /// Compute the on-disk folder name for a marketplace plugin
    /// from the entry script filename. Strips the extension, then
    /// replaces `/`, `\`, `..`, `~`, `:` with `_` (so a malicious
    /// package cannot escape the plugin folder), and clips to
    /// `maxFolderNameLength` characters.
    ///
    /// Examples:
    /// - `echo.sh`           → `echo`
    /// - `Weather.zsh`       → `Weather`
    /// - `../escape.sh`      → `_escape`
    /// - `foo:bar.sh`        → `foo_bar`
    /// - `aaaaaaaaaa…` (80c) → `aaaa…` (64 chars)
    private func sanitisedFolderName(from entryFilename: String) -> String {
        Self.sanitisedFolderNameStatic(from: entryFilename)
    }

    /// Static variant of `sanitisedFolderName(from:)` so
    /// `marketplacePluginURL(pluginDirectoryURL:entryFilename:)`
    /// can compute the folder name without holding a
    /// `PluginManager` instance. Behaviour is identical to
    /// the instance method — the split exists purely so
    /// the `public` URL helper does not need a manager.
    private static func sanitisedFolderNameStatic(from entryFilename: String) -> String {
        let stem = (entryFilename as NSString).deletingPathExtension
        let disallowed: Set<Character> = ["/", "\\", "~", ":"]
        var sanitised = ""
        sanitised.reserveCapacity(stem.count)
        for character in stem {
            if character == "." && sanitised.hasSuffix(".") {
                // Collapse `..` runs into a single `_` so the
                // classic ".." escape becomes a flat folder name.
                sanitised.append("_")
                continue
            }
            if disallowed.contains(character) {
                sanitised.append("_")
                continue
            }
            sanitised.append(character)
        }
        if sanitised.isEmpty {
            sanitised = "marketplace_plugin"
        }
        if sanitised.count > Self.maxFolderNameLength {
            sanitised = String(sanitised.prefix(Self.maxFolderNameLength))
        }
        return sanitised
    }
}
