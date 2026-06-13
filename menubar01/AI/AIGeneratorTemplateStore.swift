// AIGeneratorTemplateStore.swift
// menubar01 — AI Plugin Generator (M2+ user-saved template store)
//
// File-system-backed persistence for the user-saved portion of the
// M2+ template gallery. The v1 catalogue lives in
// `AIGeneratorTemplateGallery` and is hard-coded; the v2 extension
// is a JSON file under
// `~/Library/Application Support/menubar01/AIGenerator/templates.json`
// holding the array of `AIGeneratorTemplate` the user has saved
// from the M2 sheet's "Save as Template" sub-sheet.
//
// Persistence model:
// - `addTemplate(_:)` upserts by `id` — re-saving an existing
//   id overwrites the previous record (so a user who edits a
//   user template and re-saves gets the new copy).
// - `removeTemplate(id:)` deletes by `id` — no-op when the id is
//   unknown so the call site can stay one-liner.
// - `loadUserTemplates()` is called at sheet-open time and after
//   every save / delete so the gallery is rebuilt from disk
//   instead of being mutated in place (avoids a stale in-memory
//   copy diverging from disk).
//
// Built-in templates (the 6 in `AIGeneratorTemplateGallery`) are
// NEVER persisted here — they live in code. The sheet's
// `allTemplates(including:)` helper is responsible for merging
// the two sources, with user templates shadowing built-ins when
// ids collide (this lets us hand out `user-<uuid8>` ids and
// keep the v1 contract that the 6 built-in ids are stable).
//
// I/O errors are surfaced as thrown `Error` from the mutating
// methods so the SwiftUI sheet can show a red banner. The
// read path swallows I/O errors (logs through `os_log`) and
// returns an empty array — a corrupt / missing templates file
// is a recoverable UX state, not a crash.

import Foundation
import os

/// File-system store for the user-saved portion of the AI
/// plugin generator's template gallery.
///
/// Backed by a single JSON file (`templates.json`) under
/// `~/Library/Application Support/menubar01/AIGenerator/`. All
/// mutating operations are synchronous and throw; reads return
/// an empty array on any failure so the gallery can render
/// even with a corrupt on-disk file.
///
/// The default file path is rooted at the user's Application
/// Support directory; tests inject a `storeURL` pointing at a
/// per-test temp file to keep the suite hermetic.
public final class AIGeneratorTemplateStore {
    /// Shared instance. The M2 sheet's "Save as Template" flow
    /// reads / writes through this singleton so the on-disk file
    /// stays in sync with the in-memory gallery.
    public static let shared = AIGeneratorTemplateStore()

    /// On-disk location of `templates.json`. Exposed so tests
    /// can verify the file was written and so a future "Reveal
    /// in Finder" command can build the URL without going
    /// through the initializer.
    public let storeURL: URL

    /// Designated initializer.
    ///
    /// - Parameter storeURL: On-disk location to read from /
    ///   write to. Defaults to
    ///   `~/Library/Application Support/menubar01/AIGenerator/templates.json`
    ///   which matches the on-disk path used by the
    ///   `AIGeneratorHistoryStore` factory. Tests pass a
    ///   per-test temp URL to keep assertions hermetic.
    public init(storeURL: URL? = nil) {
        if let storeURL = storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storeURL = appSupport
                .appendingPathComponent("menubar01", isDirectory: true)
                .appendingPathComponent("AIGenerator", isDirectory: true)
                .appendingPathComponent("templates.json")
        }
    }

    /// Load the persisted user-saved templates.
    ///
    /// Returns an empty array when the on-disk file does not
    /// exist (first run, or a fresh install). On any decode
    /// error the method logs through `os_log` and returns an
    /// empty array — the gallery will still render, just with
    /// no user-saved templates, which is the safest UX
    /// fallback. The file is never auto-deleted on decode
    /// failure so the user can recover the contents by hand.
    public func loadUserTemplates() -> [AIGeneratorTemplate] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let payload = try JSONDecoder().decode(
                StoredTemplates.self, from: data
            )
            return payload.templates
        } catch {
            os_log(
                "Failed to load user templates: %{public}@",
                log: Log.plugin,
                type: .error,
                error.localizedDescription
            )
            return []
        }
    }

    /// Replace the persisted set of user templates with
    /// `templates`. Creates the parent directory on first call
    /// and writes atomically so a crash mid-write never leaves
    /// a half-decoded file on disk.
    public func saveUserTemplates(_ templates: [AIGeneratorTemplate]) throws {
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let payload = StoredTemplates(version: 1, templates: templates)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: storeURL, options: .atomic)
    }

    /// Upsert `template` into the persisted store.
    ///
    /// Re-saving an existing `id` overwrites the previous
    /// record (so editing and re-saving is idempotent). Saves
    /// are sequenced through `loadUserTemplates()` /
    /// `saveUserTemplates(_:)` so a concurrent call is safe
    /// enough for the M2 single-window sheet — there is no
    /// real concurrency to defend against, but the read /
    /// modify / write pattern keeps the on-disk file as the
    /// single source of truth.
    public func addTemplate(_ template: AIGeneratorTemplate) throws {
        var current = loadUserTemplates()
        if let idx = current.firstIndex(where: { $0.id == template.id }) {
            current[idx] = template
        } else {
            current.append(template)
        }
        try saveUserTemplates(current)
    }

    /// Remove a user-saved template by `id`.
    ///
    /// No-op (does not throw) when the id is unknown so the
    /// SwiftUI sheet's "Delete template" context menu can
    /// stay one-liner. Re-saves the trimmed array so a deleted
    /// record never reappears from a stale read.
    public func removeTemplate(id: String) throws {
        var current = loadUserTemplates()
        current.removeAll(where: { $0.id == id })
        try saveUserTemplates(current)
    }

    /// On-disk file shape. Versioned so a future migration
    /// can branch on the integer without breaking the
    /// `Codable` contract.
    private struct StoredTemplates: Codable {
        let version: Int
        let templates: [AIGeneratorTemplate]
    }
}
