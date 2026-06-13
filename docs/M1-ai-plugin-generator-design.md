# M1 — AI Plugin Generator skeleton

> Status: **done** (M1). Tracks `AI_PLUGIN_ARCHITECTURE.md` §1.5 / §6
> / §7. M2+ UI work, real LLM calls, and capability gating are out
> of scope for this milestone.

## Goal

Ship the data shapes, the protocol, and a deterministic mock
implementation of `AIPluginGenerator` so the rest of the app can be
wired up against a real (but trivial) generator before any network or
model-loading code lands.

## API sketch (from `AI_PLUGIN_ARCHITECTURE.md` §7)

```swift
public struct AIGeneratorContext {
    public var model: String
    public var city: String?
    public var refreshIntervalSeconds: Int?
    public var language: String
    public static let empty = AIGeneratorContext(model: "gpt-4o-mini")
}

public protocol AIPluginGenerator {
    func generate(request: String, context: AIGeneratorContext) async throws -> GeneratedPlugin
}

public enum AIPluginGeneratorFactory {
    public static func makeDefault() -> AIPluginGenerator
    public static func makeLocal(modelPath: URL) -> AIPluginGenerator
    public static func makeRemote(endpoint: URL, apiKey: String) -> AIPluginGenerator
}
```

The M1 implementation matches this sketch 1-to-1; the only additive
change is a `GeneratedPlugin.encodedAsBundle()` helper that returns
`(manifestData, entryFilename, entryData)` for the future M3 install
flow.

## In M1

- `AIGeneratorContext`, `GeneratedPlugin`, `AIGeneratorError`,
  `AIPluginGenerator` protocol.
- `MockAIPluginGenerator` — a deterministic, network-free
  implementation that returns a hard-coded "Echo" plugin for every
  call. `promptId` is `SHA256(request + "|" + context.model)`
  (lowercase hex); the
  `testMockGenerator_promptIdIsDeterministic` test pins the
  algorithm down by re-computing the same hash on the fly.
- `AIPluginGeneratorFactory` — all three factory methods
  (`makeDefault`, `makeLocal`, `makeRemote`) return
  `MockAIPluginGenerator`. The `local` and `remote` paths are
  deliberate stubs, not unfinished work.
- Four Swift Testing tests in
  `menubar01Tests/AIPluginGeneratorTests.swift`.

## Deferred to M2+

- **Plugin Repository UI** — the "Generate plugin…" button, the
  request sheet, the live menu preview, the install / iterate flow.
- **Real LLM call** — `makeLocal` (llama.cpp / GGUF) and
  `makeRemote` (OpenAI / Anthropic HTTP).
- **Capability gate** — `AIGeneratorError.unsafeRequest` /
  `unrenderableMenu` are reserved for M3.
- **Generator history persistence** — the
  `~/Library/Application Support/menubar01/AIGenerator/{promptId}/`
  tree from architecture doc §4 lands in M5.
- **Marketplace install** — separate `PluginMarketplace` module
  (architecture §1.6 / M4).

## Files added

| File | Purpose |
| --- | --- |
| `menubar01/AI/AIGenerator.swift` | `AIGeneratorContext`, `GeneratedPlugin`, `AIGeneratorError`, `AIPluginGenerator` protocol |
| `menubar01/AI/MockAIPluginGenerator.swift` | Deterministic SHA256-based mock |
| `menubar01/AI/AIPluginGeneratorFactory.swift` | `makeDefault` / `makeLocal` / `makeRemote` (all return the mock in v1) |
| `menubar01Tests/AIPluginGeneratorTests.swift` | 4 Swift Testing tests |
| `docs/M1-ai-plugin-generator-design.md` | This design note |
