# 2026-06-13 — M2+: AI Preferences pane

- **Type:** feat
- **Scope:** `menubar01/UI/Preferences/`, `menubar01.xcodeproj/project.pbxproj`, `menubar01/AI/AIPluginGeneratorFactory.swift`, `menubar01/Resources/Localization/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** e033493
- **Status:** done

## Summary

Add an "AI" tab to the Preferences window that lets the user pick the
active provider (`mock` / `local` / `remote`) and configure the
corresponding `modelPath` / `endpoint` / `apiKey`. The pane writes the
four `AIPluginGenerator.*` keys consumed by
`AIPluginGeneratorFactory.makeDefault(prefs:)` (shipped in 4075eb9).

## Motivation

The M2+ real-LLM factory commit (4075eb9) shipped four read-only prefs
keys (`AIPluginGenerator.provider`, `…localModelPath`, `…remoteEndpoint`,
`…remoteAPIKey`). Nothing in the codebase writes them. Without a UI, the
user has no way to opt in to a real provider — every "Generate plugin
with AI…" click falls through to `MockAIPluginGenerator`. This pane is
the missing write surface.

## Changes

- **New pane**: `menubar01/UI/Preferences/AIPreferencesView.swift`
  - `@MainActor` SwiftUI view, ~330 LoC.
  - Provider picker (segmented control over the three
    `AIPluginGeneratorProvider` cases, each with a `displayName`).
  - Per-provider section:
    - **mock** — one-line "offline / deterministic" caption.
    - **local** — read-only TextField showing the current path +
      "Choose…" `NSOpenPanel` button. Red warning when the path is set
      but the file does not exist.
    - **remote** — endpoint `TextField` (with URL validity hint) +
      `SecureField` for the API key (with empty-key yellow warning).
  - Footer: Reset (clears all 4 keys, re-pulls defaults into the
    published state) and Save (writes the 4 keys, fires a 2.5 s toast).
- **New view model**: `AIPreferencesViewModel` (in the same file) wraps
  `PreferencesStore` reads / writes. Empty strings are removed (not
  written) so the factory's "missing key → mock" fallback fires
  correctly.
- **Enum augmentation**: `AIPluginGeneratorProvider.displayName` is
  added in `menubar01/AI/AIPluginGeneratorFactory.swift` (was
  previously not surfaced anywhere).
- **Localization**: new key `Localizable.Preferences.AI` ("AI")
  added to all six `.lproj/Localizable.strings` files plus
  `Localizable.swift`.
- **Pane registration**: `menubar01/UI/Preferences/PreferencesView.swift`
  adds a `.ai` `PaneIdentifier` (with a `wand.and.stars` SF Symbol on
  macOS 11+), and a new `Preferences.Pane(...)` slot in
  `preferencePanes`.
- **Tests**: `menubar01Tests/AIPreferencesViewModelTests.swift`, 20
  Swift Testing tests covering init (provider / model path / endpoint /
  API key reads + missing-key + malformed-key defaults), save (each of
  the 4 keys, plus empty-string removal for the 3 string fields),
  reset (all-4-clear + UI state snap-back + idempotence on empty
  store), and round-trip (write then re-read in a fresh VM, and
  reset-then-reinit defaults).
- **pbxproj**: `AIPreferencesView.swift` registered in the
  Preferences sub-group and added to the menubar01 + MAS Sources
  build phases. The test file is auto-discovered by the test target's
  `PBXFileSystemSynchronizedRootGroup`.

## Impact

- **User-visible**: the Preferences window now has an "AI" tab (with a
  wand-and-stars icon). Saving the form updates the prefs keys; the
  next "click Generate" in the AI plugin generator sheet will use the
  new provider. Reset clears all four keys, returning the user to the
  default mock.
- **Non-Goals** (deliberately out of scope, per the karpathy
  "simplicity first" principle):
  - No "Test connection" button. The factory's existing `os_log`
    warning is the diagnostic for a misconfigured provider.
  - No Keychain migration. The API key is stored in `UserDefaults`
    (plaintext). The app sandbox is the security boundary in v1; a
    future follow-up should migrate to Keychain (see design note).
  - No write surface for additional fields the real on-device /
    remote providers will eventually need (temperature, max tokens,
    model name, etc.). The pane writes only the four keys the factory
    reads today.

## Testing

- **New**: 20 Swift Testing tests in
  `menubar01Tests/AIPreferencesViewModelTests.swift`. All pass.
- **Suite**: `xcodebuild … test` — 262 tests passed, 2 pre-existing
  failures (`GeneratorHistoryExporterTests/testExport_missingDirectorySurfacesFailure`
  and `AIGeneratorViewModelMenuTreeJSONTests/testGenerate_menuTreeJSONContainsHrefFromParameters`).
  Both pre-date this change (they are M5 history-UI leftovers); the
  baseline (`git stash`-equivalent) is also broken with the same
  failures.

## Related

- Cross-references:
  - `4075eb9` (M2+ real-LLM factory): the 4 read-only prefs keys this
    pane writes.
  - `4075eb9` (M2 install-prompt sheet): the consumer of the
    `MockAIPluginGenerator` this pane lets the user opt out of.
  - `changes/2026-06-13-m5-generator-history-ui.md`: the in-flight M5
    history-UI work; not touched by this change.
- Follow-ups:
  - `LocalAIPluginGenerator` (GGUF / llama.cpp) — the
    `LocalEchoAIPluginGenerator` placeholder will be replaced.
  - `RemoteAIPluginGenerator` (URLSession-backed) — the
    `RemoteEchoAIPluginGenerator` placeholder will be replaced.
  - Keychain migration for `AIPluginGenerator.remoteAPIKey`.
  - Possible per-provider advanced fields (temperature, max tokens,
    model name) once the real providers land.
