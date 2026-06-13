// AIGeneratorMenuNode.swift
// menubar01 — AI Plugin Generator (M5 follow-up)
//
// Value type used to JSON-encode a synthetic menu tree for the
// M5 history sheet. The `AIGeneratorViewModel.generate()` hook
// parses the generator's `entryScript` into a tree of
// `AIGeneratorMenuNode`s and stores the JSON bytes in
// `AIGeneratorHistoryEntry.menuTreeJSON`. The history sheet can
// later decode the bytes back into a tree for rendering.
//
// The "synthetic" parse in v1 is intentionally minimal: every
// non-blank, non-comment line of the entry script becomes a
// top-level menu node whose `title` is the trimmed line text and
// whose `href` is the `href=` parameter (when present). A future
// round can replace this with a real sandboxed dry-run of the
// entry script that captures its stdout and reconstructs the
// tree via `MenuItemNode.buildMenuTree(from:)`.

import Foundation

/// A single node in the AI generator's recorded menu tree.
///
/// Mirrors the public subset of `MenuItemNode` (just `title`,
/// `href`, and `children`) so the value is `Codable` /
/// `Sendable` / `Equatable` and round-trips cleanly through
/// `JSONEncoder`. The full `MenuItemNode` carries internal
/// parsing state (`level`, `isSeparator`, `workingLine`) that
/// does not survive JSON round-tripping and would leak the
/// parser's implementation details to consumers, so it stays
/// out of this on-disk shape.
public struct AIGeneratorMenuNode: Codable, Equatable, Sendable {
    /// User-facing title of the menu item. Sourced from the
    /// line text of the entry script after stripping the
    /// surrounding `echo "..."` and the parameter block.
    public let title: String

    /// Optional `href=` parameter from the line, when the
    /// entry script produced a link-style menu item. `nil` for
    /// plain text items.
    public let href: String?

    /// Nested submenu children. Empty for leaf items.
    public let children: [AIGeneratorMenuNode]

    public init(
        title: String,
        href: String? = nil,
        children: [AIGeneratorMenuNode] = []
    ) {
        self.title = title
        self.href = href
        self.children = children
    }
}

// MARK: - Synthetic parser

public extension AIGeneratorMenuNode {
    /// Build a flat tree of menu nodes from an entry script.
    ///
    /// The simplest v1 implementation: walk the script
    /// line-by-line, skip blank lines and `#` / `//` comments,
    /// and emit one `AIGeneratorMenuNode` per remaining line
    /// whose `title` is the line itself and whose `href` is
    /// pulled from an inline `href=...` parameter when present.
    /// `---` lines become a `title: "---"` separator marker so
    /// the visual structure of the script is preserved.
    ///
    /// Returns `nil` when the script is empty or only contains
    /// comments / blank lines — the caller treats `nil` as
    /// "unparseable" and leaves `AIGeneratorHistoryEntry.menuTreeJSON`
    /// at its default `nil` value.
    static func parseEntryScript(_ entryScript: String) -> [AIGeneratorMenuNode]? {
        var nodes: [AIGeneratorMenuNode] = []
        for rawLine in entryScript.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip shell / Python / Ruby comments.
            if line.hasPrefix("#") || line.hasPrefix("//") { continue }
            // Shebang lines are not menu output.
            if line.hasPrefix("#!") { continue }

            // `---` is the menubar01 menu-output separator.
            if line == "---" {
                nodes.append(AIGeneratorMenuNode(title: "---"))
                continue
            }

            // Start with a working copy of the line. The
            // transformation order matters: strip the shell
            // `echo "..."` wrapper first so the parameter scan
            // below sees the inner string (not the `echo`
            // invocation).
            var working = line
            // Strip the typical `echo "..."` shell pattern. The
            // v1 menu tree is meant to mirror what running the
            // entry script would produce, so we surface the
            // inner string rather than the `echo` invocation.
            if working.hasPrefix("echo "), working.hasSuffix("\"") {
                let inner = String(working.dropFirst("echo ".count))
                if inner.hasPrefix("\""), inner.hasSuffix("\"") {
                    working = String(inner.dropFirst().dropLast())
                }
            }
            working = working.trimmingCharacters(in: .whitespaces)
            guard !working.isEmpty else { continue }

            // Pull out an `href=` parameter when present, then
            // strip the parameter block from the visible title.
            // The parameter syntax mirrors the on-disk `menubar01`
            // output grammar: `key=value` separated by `|`. The
            // value can be unquoted (`href=https://example.com`)
            // or wrapped in `"…"` to embed spaces (`href="Hello
            // World"`); both shapes are accepted, so the synthetic
            // tree produced by v1 matches what the real menu
            // parser would surface for a script like
            // `echo "Title | href=https://example.com"`.
            var href: String?
            // The regex matches the `href=…` run where the value
            // is everything up to the next `|` separator (or end
            // of line). Anchored on `=` so we do not pick up
            // `nothref=...` by accident.
            if let hrefRange = working.range(of: #"href=[^|]+"#, options: .regularExpression) {
                let match = String(working[hrefRange])
                let equalsIdx = match.firstIndex(of: "=")!
                let valueStart = match.index(after: equalsIdx)
                if valueStart < match.endIndex {
                    var value = String(match[valueStart..<match.endIndex])
                    // Strip a wrapping `"…"` pair when present
                    // (handles the `href="URL with spaces"`
                    // shape). The strip is a no-op for the bare
                    // `href=URL` form that the test scripts use.
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    href = value
                }
                working.removeSubrange(hrefRange)
            }
            // Strip any remaining `key=value` parameters separated by `|`.
            if let pipeIdx = working.firstIndex(of: "|") {
                working = String(working[..<pipeIdx])
            }
            working = working.trimmingCharacters(in: .whitespaces)
            guard !working.isEmpty else { continue }

            nodes.append(AIGeneratorMenuNode(title: working, href: href))
        }
        return nodes.isEmpty ? nil : nodes
    }

    /// JSON-encode the receiver as a `[AIGeneratorMenuNode]`
    /// array. `nil` when the receiver is empty so the caller
    /// can write the result straight into
    /// `AIGeneratorHistoryEntry.menuTreeJSON` without a
    /// `guard !nodes.isEmpty` check.
    func encodedAsJSONData() -> Data? {
        let nodes = self.collectedAsArray()
        guard !nodes.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(nodes)
    }

    /// Flatten a (potentially nested) tree into a top-level
    /// array. The v1 `parseEntryScript(_:)` only produces a
    /// flat list, but the helper exists so a future
    /// sandbox-driven parser can drop a tree straight into
    /// `AIGeneratorHistoryEntry.menuTreeJSON` without changing
    /// the encoding call site.
    private func collectedAsArray() -> [AIGeneratorMenuNode] {
        if children.isEmpty { return [self] }
        return [self] + children.flatMap { $0.collectedAsArray() }
    }
}
