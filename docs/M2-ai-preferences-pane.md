# M2+ — AI Preferences pane

> Status: in-progress. Pane + view model + 20 unit tests landed in this
> milestone; the real on-device / remote `AIPluginGenerator`
> implementations are still placeholder echoes and are tracked as
> separate follow-ups.

## Scope

The M2+ factory (shipped in `4075eb9`) reads four
`UserDefaults` keys and uses them to pick a provider:

| Key                                | Type   | Consumed by          |
| ---------------------------------- | ------ | -------------------- |
| `AIPluginGenerator.provider`       | String | always (`.rawValue`) |
| `AIPluginGenerator.localModelPath` | String | `.local` only        |
| `AIPluginGenerator.remoteEndpoint` | String | `.remote` only       |
| `AIPluginGenerator.remoteAPIKey`   | String | `.remote` only       |

If the provider key is missing or unparseable, the factory returns
`MockAIPluginGenerator` (offline, deterministic). The Preferences → AI
pane is the user-facing write surface for those four keys.

## Pane shape

A single SwiftUI view, `AIPreferencesView`, organised top-to-bottom
as: header → provider picker → provider-specific section → footer.

```
+-----------------------------------------------------------+
| AI Plugin Generator                                      |
| Choose which provider powers the “Generate plugin with    |
| AI…” workflow. …                                         |
+-----------------------------------------------------------+
| Provider       [Mock (offline)] [Local model] [Remote …]  | <- segmented
+-----------------------------------------------------------+
| (mock)        The generator will use the offline mock …   |
| — or —                                                   |
| (local)       Model file  [/path/to/model.gguf] [Choose…] |
|               ⚠️ File does not exist. … (red, if missing) |
| — or —                                                   |
| (remote)      Endpoint URL [https://api.example.com/v1/…] |
|               ⚠️ Not a valid URL. …   (yellow, if invalid) |
|               API key     [•••••••••••••]                 |
|               ⚠️ API key is empty. …   (yellow, if empty) |
+-----------------------------------------------------------+
| [Reset]                                       [Save]     |
| ✓ Saved.                                                | <- toast
+-----------------------------------------------------------+
```

### Provider picker

`Picker(selection: $viewModel.provider)` with a `.segmented` style,
iterating over `AIPluginGeneratorProvider.allCases`. Each case uses
`provider.displayName` (added in this milestone) for the segment
label: `"Mock (offline)"`, `"Local model"`, `"Remote model"`. The
explanatory copy below the picker is what tells the user *what* each
provider actually does.

### Validation rules

- **Mock**: no input fields. The body is a 1-line caption ("offline
  / deterministic / no LLM call").
- **Local**:
  - Path empty → muted hint ("Pick a GGUF / on-device model file…").
  - Path set, file exists → muted positive hint.
  - Path set, file **does not exist** → **red** warning with
    `exclamationmark.triangle.fill`. Factory will fall back to mock.
- **Remote**:
  - Endpoint empty → muted hint.
  - Endpoint non-empty, `URL(string:)` returns nil → **yellow**
    warning ("Not a valid URL. The factory will fall back to mock
    on next generate.").
  - Endpoint parses as URL → muted positive hint.
  - API key empty → **yellow** warning ("API key is empty. …").
  - API key non-empty → muted hint ("Stored in UserDefaults (v1).
    A future Keychain migration is planned.").

The pane is *advisory*: it does **not** block Save. The factory's
own `os_log` warning is the diagnostic for a misconfigured provider
on the next generate, and a "Test connection" button that shells
out to a live LLM was deliberately out of scope (cost, failure
modes, and the karpathy "simplicity first" principle).

## View model

```swift
@MainActor
final class AIPreferencesViewModel: ObservableObject {
    @Published var provider: AIPluginGeneratorProvider
    @Published var localModelPath: String
    @Published var remoteEndpoint: String
    @Published var remoteAPIKey: String

    let prefs: PreferencesStore

    init(prefs: PreferencesStore = .shared) { … }
    func save()  { … }   // 4 keys; empty strings removed, not written as ""
    func reset() { … }   // 4 keys cleared, published state snapped back to defaults
}
```

`init` reads each key from `prefs.defaults` and falls back to the
factory defaults: `.mock` for the provider, `""` for the three
strings. Malformed provider values (anything not in the enum) also
fall back to `.mock` — the same defensive behaviour the factory
itself has.

`save()` writes the four keys; for the three string fields, an
empty value is `removeObject(forKey:)` rather than `set("", forKey:)`
so the factory's "missing key → mock" check fires on the next
generate. `prefs.defaults.synchronize()` is called at the end of
both `save()` and `reset()` for symmetry with the factory read
path.

`reset()` clears all four keys and re-pulls the (now-empty) state
into the published properties so the UI snaps back to the factory
defaults. This matches the user-visible behaviour: clicking Reset
should change the picker back to "Mock (offline)" and clear the
three input fields, not just zero out the prefs.

## Tests

`menubar01Tests/AIPreferencesViewModelTests.swift` — 20 Swift
Testing tests across four suites. Every test uses a fresh
`UserDefaults(suiteName: "menubar01.tests.aiPrefs.<UUID>")` so
parallel test runs and the suite / standard split never stomp each
other.

- **`AIPreferencesViewModelInitTests`** (8 tests): reads
  `provider` / `localModelPath` / `remoteEndpoint` / `remoteAPIKey`
  from prefs; the `.remote` provider variant; missing-key defaults
  (`.mock` + `""` strings); malformed provider key (`.mock`).
- **`AIPreferencesViewModelSaveTests`** (7 tests): writes each of
  the four keys; the three "clears when empty" cases (verifies
  `removeObject` fires, not `set("")`).
- **`AIPreferencesViewModelResetTests`** (3 tests): clears all four
  prefs keys; the published state snaps back; reset is idempotent
  on an empty store.
- **`AIPreferencesViewModelRoundTripTests`** (2 tests):
  write-then-reinit in a fresh VM; reset-then-reinit returns the
  factory defaults.

## Pane registration

`menubar01/UI/Preferences/PreferencesView.swift`:

```swift
extension Preferences.PaneIdentifier {
    …
    static let ai = Self("ai")
    …
}

preferencePanes.append(
    Preferences.Pane(
        identifier: .ai,
        title: Localizable.Preferences.AI.localized,
        toolbarIcon: Preferences.PaneIdentifier.ai.image
    ) { AIPreferencesView() }
)
```

The toolbar icon is `NSImage(systemSymbolName: "wand.and.stars",
accessibilityDescription: "AI")` on macOS 11+; on 10.15 it falls
back to the app icon (the SF Symbol isn't available pre-Big-Sur).
The new key `Localizable.Preferences.AI` (`"PF_AI"`) was added to
`Localizable.swift` and all six `.lproj/Localizable.strings` files.

## Split: pane writes prefs, factory reads them

The pane **does not** build an `AIPluginGenerator` instance — that
is the factory's job. The pane writes prefs; the next
`AIPluginGeneratorFactory.makeDefault(prefs:)` call (triggered by
the next "Generate plugin with AI…" click) reads them. This is the
cleanest split:

- "User-facing config" (the pane) — owns the
  `UserDefaults` round-trip and the validation copy.
- "Build an instance" (the factory) — owns the
  `AIPluginGenerator` choice, the read-side fallbacks, and the
  future per-provider advanced fields.

A follow-up may add a public `AIPluginGeneratorFactory.makeRemote(...)`
so other surfaces (e.g. a "Test connection" button) can build an
instance directly; this milestone does not.

## Security: API key in `UserDefaults`

`AIPluginGenerator.remoteAPIKey` is stored in `UserDefaults` (i.e.
`~/Library/Preferences/com.lingyi.menubar01.plist`, plaintext).
This is **acceptable for v1** because:

- The app sandbox is the security boundary.
- A future `LocalAIPluginGenerator` and a future
  `RemoteAIPluginGenerator` will be the actual readers of the key;
  they will only ever be called from the in-process generator
  pipeline.
- A future `KeychainService` migration is already on the radar
  (the project ships
  `menubar01/UI/Settings/KeychainService.swift` for general secret
  storage).

The pane's body copy states this explicitly: "Stored in
UserDefaults (v1). A future Keychain migration is planned." When
the Keychain migration lands, the view model will swap
`prefs.defaults.set(...)` for `KeychainService.shared.set(...)` and
the pane's `SecureField` will continue to work without UI changes.

## Out of scope (follow-ups)

- `LocalAIPluginGenerator` (GGUF / llama.cpp).
- `RemoteAIPluginGenerator` (URLSession-backed, OpenAI-compatible).
- Per-provider advanced fields (temperature, max tokens, model
  name) — added when the real providers land.
- Keychain migration for `AIPluginGenerator.remoteAPIKey`.
- A public `AIPluginGeneratorFactory.makeRemote(...)` for callers
  that want to build an instance without going through
  `makeDefault(prefs:)`.
- A "Test connection" affordance — explicitly not added in this
  milestone.
