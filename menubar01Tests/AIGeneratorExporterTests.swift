// AIGeneratorExporterTests.swift
// menubar01 — AI Plugin Generator (M2+ follow-up)
//
// Swift Testing coverage for `AIGeneratorExporter`. The exporter's
// UI entry point drives an `NSSavePanel`, which is a modal we
// cannot run from the test bundle; the tests exercise the
// lower-level `writeToTempDir(_:)` and
// `runZip(sourceDirectory:destination:)` helpers directly so we
// can assert on the on-disk shape (manifest.json + entry script
// at the staging dir's root, plus a valid zip with both files
// at the archive root) without driving the panel.
//
// Each test roots its own temp directory under
// `FileManager.default.temporaryDirectory` + a UUID and uses
// `defer { try? FileManager.default.removeItem(at: ...) }` for
// cleanup so the suite is hermetic and parallel-safe.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Build a `GeneratedPlugin` for the test bundle to round-trip
/// through the exporter. Default `entry` is `"export-test.sh"`
/// so a stray assertion can read it back verbatim; tests that
/// want to exercise the manifest-default fallback pass an
/// explicit `entry` parameter.
private func makePlugin(
    name: String? = "ExportTest",
    entry: String? = "export-test.sh",
    entryScript: String = "#!/bin/zsh\necho export-test\n"
) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = entry
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: entryScript,
        explanation: "exporter test",
        promptId: "exporter-test",
        promptVersion: "v-exporter-test"
    )
}

/// Allocate a fresh per-test temp directory under
/// `FileManager.default.temporaryDirectory` + a UUID. The
/// returned URL does not yet exist; `writeToTempDir(_:)`
/// creates it as a side effect of writing the manifest +
/// entry script.
private func makeTempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("aigen-exporter-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - writeToTempDir

struct AIGeneratorExporterWriteToTempDirTests {

    @Test func testWriteToTempDir_createsManifest() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plugin = makePlugin()
        let dir = try AIGeneratorExporter.writeToTempDir(plugin)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The exporter's contract: the staging dir is the
        // one we returned (a fresh per-call UUID under
        // `temporaryDirectory`), and `manifest.json` exists
        // at the dir's root.
        #expect(dir.lastPathComponent.hasPrefix("menubar01-export-"))
        let manifestURL = dir.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func testWriteToTempDir_createsEntryScript() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plugin = makePlugin(entry: "my-plugin.sh", entryScript: "#!/bin/zsh\necho hello\n")
        let dir = try AIGeneratorExporter.writeToTempDir(plugin)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The entry script must land at the staging dir's
        // root under the filename the manifest declared
        // (mirroring `PluginManager.installGeneratedPlugin`'s
        // behaviour).
        let entryURL = dir.appendingPathComponent("my-plugin.sh")
        #expect(FileManager.default.fileExists(atPath: entryURL.path))
        let body = try String(contentsOf: entryURL, encoding: .utf8)
        #expect(body.contains("echo hello"))
    }

    @Test func testWriteToTempDir_entryScriptIsExecutable() throws {
        // The staging dir's entry script should be marked
        // executable so a downstream unzip + `chmod +x`
        // round-trip is unnecessary. Skip on platforms where
        // `FileManager.attributesOfItem` does not surface
        // POSIX permissions (e.g. a non-Darwin test runner) —
        // the project's macOS-only deployment target makes
        // this a no-op for the production build, and the
        // fallback `false` keeps the test from asserting on
        // a meaningless value.
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plugin = makePlugin(entry: "exec-test.sh")
        let dir = try AIGeneratorExporter.writeToTempDir(plugin)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entryURL = dir.appendingPathComponent("exec-test.sh")
        let attrs = try FileManager.default.attributesOfItem(atPath: entryURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // 0o111 = owner / group / other execute bits. At
        // least one of them should be set for the file to be
        // considered executable.
        #expect((permissions & 0o111) != 0)
    }

    @Test func testWriteToTempDir_emptyManifestName_usesFallback() throws {
        // The manifest's `name` is nil → the exporter's
        // staging dir name still has to fall through to a
        // safe default (`generated-plugin`) so a downstream
        // `mkdir -p` / save panel default does not break.
        // The current `writeToTempDir` only uses the name to
        // suggest a save-panel filename, so the on-disk
        // staging dir name itself is the random UUID —
        // what we assert here is that the manifest name is
        // omitted from the encoded JSON when nil, which is
        // the contract the v1 install path also relies on.
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plugin = makePlugin(name: nil)
        let dir = try AIGeneratorExporter.writeToTempDir(plugin)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // A `nil` name is encoded as a JSON `null` (the
        // Codable representation), not omitted, because
        // `PluginManifest` does not implement a custom
        // `encode(to:)` that strips nils. The exporter's
        // downstream `exportPlugin(_:)` reads the name
        // through the `?? "generated-plugin"` fallback so a
        // null value is fine for the user-facing flow.
        #expect(json["name"] == nil || json["name"] is NSNull)
        // And the entry script must still be written at the
        // manifest-declared filename (which the test passes
        // as the default `"export-test.sh"`).
        let entryURL = dir.appendingPathComponent("export-test.sh")
        #expect(FileManager.default.fileExists(atPath: entryURL.path))
    }
}

// MARK: - runZip

struct AIGeneratorExporterRunZipTests {

    @Test func testExportPlugin_zipSucceeds_writesValidZip() throws {
        // Full flow without an `NSSavePanel`: stage the
        // plugin in a per-test temp dir, then run
        // `runZip(sourceDirectory:destination:)` to write
        // the zip at a known destination. The resulting
        // archive is then probed with `/usr/bin/unzip -l`
        // so we can assert that `manifest.json` and the
        // entry script both landed at the zip's root.
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plugin = makePlugin(entry: "full-flow.sh", entryScript: "#!/bin/zsh\necho full\n")
        let sourceDir = try AIGeneratorExporter.writeToTempDir(plugin)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigen-export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = AIGeneratorExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL
        )
        #expect(result == .success(destination: zipURL))

        // The zip is non-empty (sanity check: `runZip` did
        // not just touch the file and exit cleanly).
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attrs[.size] as? Int
        #expect((size ?? 0) > 0)

        // Both files are at the archive root, not inside a
        // subfolder — the v1 install layout
        // (`PluginManager.installGeneratedPlugin`) writes
        // them at the plugin folder's top level, so the
        // exported zip must match.
        let listing = GeneratorHistoryExporter.listContents(ofZipAt: zipURL)
        #expect(listing.contains("manifest.json"))
        #expect(listing.contains("full-flow.sh"))
    }
}
