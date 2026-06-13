// AIGeneratorHistoryStore.swift
// menubar01 — AI Plugin Generator (M5)
//
// Persistence layer for `AIPluginGenerator` runs. Backed by the file
// system under
// `~/Library/Application Support/menubar01/AIGenerator/{promptId}/` per
// `AI_PLUGIN_ARCHITECTURE.md` §4. The protocol is small (`record` /
// `listAll` / `delete` / `deleteAll`) so the future M2 UI can swap in
// an in-memory or remote store without changing the call sites.

import Foundation
import os

// MARK: - Error

/// Errors surfaced by the history store.
///
/// Cases are intentionally narrow: `CocoaError` codes and the like
/// are wrapped as `ioFailure(reason:)` strings so the UI can show a
/// single, stable error type.
public enum AIGeneratorHistoryError: Error, Equatable {
    /// A read or write to the file system failed. The reason is the
    /// underlying `Error.localizedDescription` (or a synthesised one)
    /// so the UI can surface it verbatim.
    case ioFailure(reason: String)
    /// `response.json` could not be decoded into
    /// `AIGeneratorHistoryEntry`. The reason is the underlying decode
    /// error's `localizedDescription`.
    case decodingFailed(reason: String)

    /// Human-readable reason for the error. `AIGeneratorHistoryError`
    /// does not conform to `LocalizedError` (the M5 store-test suite
    /// does not need the localisation plumbing), so callers that
    /// want to surface the error verbatim should read `reason`
    /// rather than `error.localizedDescription` (which would
    /// return the default NSError description).
    public var reason: String {
        switch self {
        case .ioFailure(let reason), .decodingFailed(let reason):
            return reason
        }
    }
}

// MARK: - Protocol

/// Persistence surface for `AIGeneratorHistoryEntry` records.
///
/// All four operations are synchronous and throw. The M2 generator
/// UI is expected to call them on a background queue (the directory
/// traversal in `listAll` scales linearly with the number of runs,
/// but each run is a single `response.json` of a few hundred bytes).
public protocol AIGeneratorHistoryStore {
    /// Persist `entry` to disk. Idempotent w.r.t. `promptId`: a
    /// second `record(...)` with the same id overwrites the previous
    /// directory atomically.
    func record(_ entry: AIGeneratorHistoryEntry) throws

    /// Return every persisted entry, newest first.
    func listAll() throws -> [AIGeneratorHistoryEntry]

    /// Remove the entry for `promptId`. No-op if the id is unknown.
    func delete(promptId: String) throws

    /// Remove every entry under the store's root directory.
    func deleteAll() throws
}

// MARK: - File-system implementation

/// `AIGeneratorHistoryStore` implementation that writes one
/// subdirectory per entry under `rootDirectory`.
///
/// Layout (per the architecture doc §4):
/// ```
/// {rootDirectory}/{promptId}/request.txt
/// {rootDirectory}/{promptId}/response.json
/// {rootDirectory}/{promptId}/menu.json   // optional
/// ```
///
/// `request.txt` is the verbatim `entry.request` so the user can
/// `cat` it without decoding JSON. `response.json` is the
/// self-describing JSON produced by `AIGeneratorHistoryEntry`'s
/// custom `Codable`. `menu.json` is written only when
/// `entry.menuTreeJSON != nil` — the v1 generator never fills it in,
/// but the field is part of the on-disk contract so M5+ can start
/// populating it without a schema break.
public final class FileSystemAIGeneratorHistoryStore: AIGeneratorHistoryStore {
    /// Name of the per-entry subdirectory for `request.txt`. Public
    /// so the future M2 UI can build a "Reveal in Finder" command
    /// without hard-coding the magic string.
    public static let requestFilename = "request.txt"

    /// Name of the per-entry JSON file. See `requestFilename`.
    public static let responseFilename = "response.json"

    /// Name of the per-entry menu-tree JSON file. See
    /// `requestFilename`.
    public static let menuFilename = "menu.json"

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - rootDirectory: Parent directory under which one
    ///     `{promptId}/` subdirectory is created per entry.
    ///   - fileManager: File manager used for all disk I/O. Defaults
    ///     to `.default`. Tests pass a custom value when they need
    ///     to swap in a mock; in practice a temp `rootDirectory` is
    ///     enough.
    ///   - encoder: JSON encoder used for `response.json` and
    ///     `menu.json`. Defaults to pretty-printed, sorted-key output
    ///     with `withoutEscapingSlashes` so the files are
    ///     human-readable when the user opens them in an editor.
    ///   - decoder: JSON decoder used by `listAll`. Defaults to
    ///     ISO-8601 date decoding so files written by the default
    ///     encoder round-trip.
    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = FileSystemAIGeneratorHistoryStore.defaultEncoder(),
        decoder: JSONDecoder = FileSystemAIGeneratorHistoryStore.defaultDecoder()
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Builds the default pretty-printed encoder.
    public static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Builds the default decoder matching `defaultEncoder()`.
    public static func defaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - AIGeneratorHistoryStore

    public func record(_ entry: AIGeneratorHistoryEntry) throws {
        let entryDirectory = self.entryDirectory(for: entry.promptId)
        do {
            try fileManager.createDirectory(
                at: entryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to create \(entryDirectory.path): \(error.localizedDescription)"
            )
        }

        try writeRequestFile(entry: entry, in: entryDirectory)
        try writeResponseFile(entry: entry, in: entryDirectory)
        try writeMenuFile(entry: entry, in: entryDirectory)
    }

    public func listAll() throws -> [AIGeneratorHistoryEntry] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // An empty store has no root directory yet — treat as an
            // empty list so the first `record(...)` works without a
            // pre-existing directory.
            return []
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
            // Same as above, for the case where the platform surfaces
            // "no such file" as a POSIX error instead of a Cocoa one.
            return []
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to enumerate \(rootDirectory.path): \(error.localizedDescription)"
            )
        }

        var entries: [AIGeneratorHistoryEntry] = []
        entries.reserveCapacity(contents.count)
        for candidate in contents {
            guard isDirectory(candidate) else { continue }
            let responseURL = candidate.appendingPathComponent(Self.responseFilename)
            guard fileManager.fileExists(atPath: responseURL.path) else { continue }
            do {
                let data = try Data(contentsOf: responseURL)
                let entry = try decoder.decode(AIGeneratorHistoryEntry.self, from: data)
                entries.append(entry)
            } catch {
                // A corrupt entry should not poison the rest of the
                // listing — log and skip. The user can `deleteAll()`
                // to reset the store.
                os_log(
                    "AIGeneratorHistoryStore: failed to read %{public}@: %{public}@",
                    log: Self.log,
                    type: .error,
                    responseURL.path,
                    error.localizedDescription
                )
            }
        }

        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(promptId: String) throws {
        let entryDirectory = self.entryDirectory(for: promptId)
        guard fileManager.fileExists(atPath: entryDirectory.path) else { return }
        do {
            try fileManager.removeItem(at: entryDirectory)
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to remove \(entryDirectory.path): \(error.localizedDescription)"
            )
        }
    }

    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        do {
            // `contentsOfDirectory` is read-only — enumerate first
            // and remove each child individually so a stray
            // non-directory file (e.g. a `README.md` the user dropped
            // in by mistake) does not block the wipe.
            let children = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for child in children {
                try fileManager.removeItem(at: child)
            }
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to wipe \(rootDirectory.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    /// Returns the `{rootDirectory}/{promptId}/` subdirectory URL.
    private func entryDirectory(for promptId: String) -> URL {
        return rootDirectory.appendingPathComponent(promptId, isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    private func writeRequestFile(
        entry: AIGeneratorHistoryEntry,
        in directory: URL
    ) throws {
        let url = directory.appendingPathComponent(Self.requestFilename)
        do {
            try Data(entry.request.utf8).write(to: url, options: [.atomic])
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to write \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private func writeResponseFile(
        entry: AIGeneratorHistoryEntry,
        in directory: URL
    ) throws {
        let url = directory.appendingPathComponent(Self.responseFilename)
        let data: Data
        do {
            data = try encoder.encode(entry)
        } catch {
            throw AIGeneratorHistoryError.decodingFailed(
                reason: "Failed to encode response.json for \(entry.promptId): \(error.localizedDescription)"
            )
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw AIGeneratorHistoryError.ioFailure(
                reason: "Failed to write \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private func writeMenuFile(
        entry: AIGeneratorHistoryEntry,
        in directory: URL
    ) throws {
        let url = directory.appendingPathComponent(Self.menuFilename)
        if let menuData = entry.menuTreeJSON {
            do {
                try menuData.write(to: url, options: [.atomic])
            } catch {
                throw AIGeneratorHistoryError.ioFailure(
                    reason: "Failed to write \(url.path): \(error.localizedDescription)"
                )
            }
        } else {
            // No menu data — remove a stale `menu.json` from a
            // previous record call so the directory accurately
            // reflects the current entry.
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    throw AIGeneratorHistoryError.ioFailure(
                        reason: "Failed to remove stale \(url.path): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGeneratorHistory")
}

// MARK: - Factory

/// Builds the default `AIGeneratorHistoryStore` instance.
///
/// `makeDefault()` returns a `FileSystemAIGeneratorHistoryStore`
/// rooted at
/// `~/Library/Application Support/menubar01/AIGenerator/`. The
/// factory exists so the call site (M2 generator UI) does not have
/// to know the on-disk path and so the future M5+ tests can swap
/// in a memory-backed store without touching the UI.
public enum AIGeneratorHistoryStoreFactory {
    /// Returns the file-system-backed history store rooted at
    /// `~/Library/Application Support/menubar01/AIGenerator/`.
    public static func makeDefault() -> AIGeneratorHistoryStore {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let rootDirectory = support
            .appendingPathComponent("menubar01", isDirectory: true)
            .appendingPathComponent("AIGenerator", isDirectory: true)
        return FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }
}
