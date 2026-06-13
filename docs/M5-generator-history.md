# 2026-06-13: AIGenerator history store (M5)

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Implements M5 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§6: the on-disk persistence layer for `AIPluginGenerator` runs. M5
ships the in-memory record type, a small `AIGeneratorHistoryStore`
protocol, a file-system implementation, and a default factory. No
UI, no remote provider, no entry-script sandbox — those land in M2+.

## Source (quoted from `AI_PLUGIN_ARCHITECTURE.md` §4 / §6)

> The generator's prompt body, the model's response, and the
> rendered menu tree are stored locally at
> `~/Library/Application Support/menubar01/AIGenerator/{promptId}/`.
> The user can wipe all generator history from a single menu item
> in Preferences → Advanced.

> **M5** | Persistence layer for generator history. |
> `~/Library/Application Support/menubar01/`

## On-disk layout

```
~/Library/Application Support/menubar01/AIGenerator/{promptId}/
├── request.txt    # verbatim user request, UTF-8
├── response.json  # self-describing JSON (promptId, createdAt, request,
│                  # model, pluginManifest, pluginEntryScript,
│                  # pluginExplanation, pluginPromptVersion, menuTreeJSON)
└── menu.json      # only when entry.menuTreeJSON != nil
```

`{promptId}` is the same `SHA256(request + "|" + model)` produced
by `MockAIPluginGenerator`, so re-running the same prompt
overwrites in place. `response.json` is pretty-printed with sorted
keys and `withoutEscapingSlashes` so the user can `cat` it.

## API surface

```swift
public struct AIGeneratorHistoryEntry: Codable, Identifiable, Equatable {
    public let promptId: String     // = id
    public let createdAt: Date
    public let request: String
    public let model: String
    public let plugin: GeneratedPlugin
    public let menuTreeJSON: Data?
}

public protocol AIGeneratorHistoryStore {
    func record(_ entry: AIGeneratorHistoryEntry) throws
    func listAll() throws -> [AIGeneratorHistoryEntry]  // newest first
    func delete(promptId: String) throws
    func deleteAll() throws
}

public final class FileSystemAIGeneratorHistoryStore: AIGeneratorHistoryStore {
    public init(rootDirectory: URL, fileManager: FileManager = .default,
                encoder: JSONEncoder = ..., decoder: JSONDecoder = ...)
}

public enum AIGeneratorHistoryStoreFactory {
    public static func makeDefault() -> AIGeneratorHistoryStore
}
```

## DI boundary and factory

The store's init takes a `rootDirectory: URL` plus optional
`fileManager` / `encoder` / `decoder` so unit tests use a unique
`NSTemporaryDirectory()` subdirectory per test.
`AIGeneratorHistoryStoreFactory.makeDefault()` hides the
`~/Library/Application Support/menubar01/AIGenerator/` path from
the future M2 UI and keeps the path movable behind a preference.
