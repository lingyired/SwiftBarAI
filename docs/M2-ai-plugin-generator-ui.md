# M2 — AI Plugin Generator live preview UI

> Status: design note for the M2 deliverable of
> [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.5 / §6.
> Implementation lives in `menubar01/UI/Plugin Generator/`.

## Milestone description (quoted from §6)

> **M2** — Live preview UI in the Plugin Repository window.
> Existing dependency: `PluginRepositoryView`, `PluginEntryView`.

## In scope (M2)

- **SwiftUI sheet** (`AIGeneratorSheet`) with a request `TextEditor`,
  a "Generate" button, and a result panel that renders the
  `manifest.json` body, the entry script, the explanation, and the
  `promptId` for the latest `GeneratedPlugin`.
- **`AIGeneratorViewModel`** — `@MainActor` `ObservableObject`
  that owns the request text, the loading state, the latest
  `GeneratedPlugin`, and the error state. Calls
  `AIPluginGenerator.generate(request:context:)` through the M1
  protocol surface (no LLM code in this milestone).
- **Menu wiring** — adds a "Generate plugin with AI…" item to the
  existing menubar01 app menu (`AppDelegate+Menu.swift` →
  `AppMenu`). The item opens a standalone `NSWindow` hosted by a
  SwiftUI `NSHostingController`.
- **Save stub** — "Save to Plugin Folder" flips a flag on the VM
  that the view shows as an alert ("M3 will wire this to
  `PluginManager.importPlugin`"). No disk I/O in M2.
- **9 Swift Testing tests** in
  `menubar01Tests/AIGeneratorViewModelTests.swift` covering the
  VM state machine, error surface, save stub, and reset path
  through a test-only `CapturingMockAIPluginGenerator`.

## Deferred (M3 and later)

- **Sandboxed dry-run / live menu preview** — the §1.3 mention is
  M3 territory (capability-gate install flow). M2 shows the
  manifest + script body as text only.
- **Re-generate with follow-up** — iteration language ("use
  Fahrenheit") lands with the real LLM-backed factory.
- **Save to Plugin Folder (wired)** — actual
  `PluginManager.importPlugin(from:)` call. M3 consumes the
  `GeneratedPlugin.encodedAsBundle()` helper M1 shipped.
- **Real LLM-backed factory** — `makeLocal` / `makeRemote` still
  return `MockAIPluginGenerator`. The VM is wired against the M1
  protocol so the factory swap is a one-line change.
- **Generator history persistence** — the
  `~/Library/Application Support/menubar01/AIGenerator/{promptId}/`
  tree from §4 lands in M5.

## VM → view contract

The view never holds state. Every piece of UI is a function of the
VM's `@Published` properties. The VM exposes `func generate()
async`, `func reset()`, and `func requestSaveToPluginFolder()`.
The async generator call is fired with `Task { await
viewModel.generate() }` from the button action.
