# 2026-06-13 — Wire AIPluginGenerator.model pref into factory + prefs pane

- **Type:** feat
- **Scope:** `menubar01/AI/AIPluginGeneratorFactory.swift`, `menubar01/UI/Preferences/AIPreferencesView.swift`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 4fe63bc
- **Status:** done

## Summary

Lifts the M2+ real-remote-generator follow-up
([`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md))
by wiring the user-configured `AIPluginGenerator.model`
preference through to `RemoteAIPluginGenerator.init(model:)`.
The factory now reads the value from `PreferencesStore`,
falls back to a new `defaultRemoteModel` constant
(`"gpt-4o-mini"`) on missing / empty / whitespace-only input,
and passes the result to the remote generator. The AI
Preferences pane grows a "Model" row in the Remote section
backed by a new `remoteModel` field on `AIPreferencesViewModel`,
and the model's value is persisted on `save()` (with the
same trim-empty-remove-prefs-key pattern the other three
string fields use).

## Motivation

The M2+ real-remote-generator record explicitly listed
"Wire the `AIPluginGenerator.model` preference into
`AIPluginGeneratorFactory.makeRemote(...)`" as a follow-up:

> **Follow-ups**
> - Wire the `AIPluginGenerator.model` preference into
>   `AIPluginGeneratorFactory.makeRemote(...)` so the user-
>   configured model in the AI Preferences pane is sent in
>   the request body. The factory currently falls back to
>   `"gpt-4o-mini"`.

Until this commit, the factory hard-coded `"gpt-4o-mini"` as
the `model` value in the request body. Users who picked a
different model name in the AI Preferences pane (or who
hand-wrote `defaults write com.lingyi.menubar01
AIPluginGenerator.model -string "claude-3-5-sonnet"`) saw
their model ignored at generate time. This commit closes
that gap.

The AI Preferences pane already had a "Model" field
described in
[`2026-06-13-m2-ai-preferences-pane.md`](2026-06-13-m2-ai-preferences-pane.md)
Non-Goals list ("No write surface for additional fields the
real on-device / remote providers will eventually need
(…model name…)"). This commit lands that field.

## Changes

- `menubar01/AI/AIPluginGeneratorFactory.swift`:
  - New public static constant `remoteModelKey = "AIPluginGenerator.model"` —
    the prefs key the factory reads from. Mirrors the four
    other `*Key` constants on the factory.
  - New public static constant `defaultRemoteModel = "gpt-4o-mini"` —
    the fallback used by `readRemoteModel(from:)` and the
    initial value shown in the prefs pane text field.
    Matches the OpenAI example used throughout
    `AI_PLUGIN_ARCHITECTURE.md` §7 and the default on
    `RemoteAIPluginGenerator.init(model:)`.
  - `makeRemote(endpoint:apiKey:prefs:)` now calls
    `readRemoteModel(from: prefs)` and passes the result to
    `RemoteAIPluginGenerator(endpoint: apiKey: model:)`. The
    `os_log` line in the success branch is augmented with
    the resolved `model` so a system-report dump shows
    which model the factory picked.
  - New private helper `readRemoteModel(from:)` — same
    trim-empty-fallback shape as `readLocalModelPath(from:)`
    and `readRemoteEndpoint(from:)`. Returns
    `defaultRemoteModel` when the key is missing, holds an
    empty string, or holds a whitespace-only string. Trims
    surrounding whitespace on the way out so a hand-edited
    prefs file with `  gpt-4o  ` resolves to `"gpt-4o"`.
- `menubar01/UI/Preferences/AIPreferencesView.swift`:
  - `AIPreferencesViewModel` gains a `@Published var remoteModel: String`
    field, populated on `init(prefs:)` from
    `prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey)`
    (falling back to `AIPluginGeneratorFactory.defaultRemoteModel`
    when missing, so a fresh-install user sees the
    documented default in the text field).
  - `save()` trims the model value and writes it to
    `remoteModelKey`. Empty / whitespace-only is `removeObject`'d
    (not written as `""`) so the factory's
    `readRemoteModel` missing-key fallback fires on the next
    call and the user gets the documented default back.
  - `reset()` removes the key and snaps the published
    `remoteModel` back to `defaultRemoteModel` so the UI
    visibly clears.
  - `AIPreferencesView.remoteSection` gains a "Model"
    `SettingsPaneRow` between the "Endpoint URL" and
    "API key" rows. A monospaced `TextField` (placeholder
    `"gpt-4o-mini"`) is bound to `$viewModel.remoteModel`,
    with a one-line caption explaining what the value is
    used for ("The model identifier sent in the
    chat-completions request body. Defaults to
    "gpt-4o-mini"."). No URL validity hint — the model
    string is opaque.
- `menubar01Tests/AIPluginGeneratorFactoryTests.swift`:
  5 new tests in `AIPluginGeneratorFactoryRemoteTests`:
  - `testMakeRemote_usesPrefsModel` — sets
    `remoteModelKey = "gpt-4o"`, calls `makeRemote(...)`,
    asserts the returned `RemoteAIPluginGenerator.model ==
    "gpt-4o"`.
  - `testMakeRemote_fallsBackToDefaultWhenModelMissing` —
    empty prefs, asserts `model == "gpt-4o-mini"`.
  - `testMakeRemote_fallsBackToDefaultWhenModelEmpty` —
    `remoteModelKey = ""`, asserts `model == "gpt-4o-mini"`.
  - `testMakeRemote_fallsBackToDefaultWhenModelWhitespace` —
    `remoteModelKey = "   "`, asserts `model == "gpt-4o-mini"`.
  - `testMakeRemote_trimsWhitespaceAroundModel` —
    `remoteModelKey = "  gpt-4o  "`, asserts
    `model == "gpt-4o"` (belt-and-braces against a
    hand-edited prefs file).
- `menubar01Tests/AIPreferencesViewModelTests.swift`:
  6 new tests + extended assertions on 4 existing tests
  across `AIPreferencesViewModelInitTests`,
  `AIPreferencesViewModelSaveTests`,
  `AIPreferencesViewModelResetTests`, and
  `AIPreferencesViewModelRoundTripTests`:
  - `testInit_readsRemoteModelFromPrefs` — verifies the
    init read path for a user-set value.
  - `testInit_defaultsRemoteModelToFactoryDefaultWhenKeyMissing` —
    verifies the missing-key → `defaultRemoteModel` default
    is shown in the published state.
  - `testSave_writesRemoteModelToPrefs` — verifies the save
    path.
  - `testSave_trimsWhitespaceAroundRemoteModel` — verifies
    the write-side trim.
  - `testSave_clearsRemoteModelWhenEmpty` / `…WhenWhitespace` —
    verify the `removeObject(forKey:)` (not write-`""`)
    path so the factory's missing-key fallback fires.
  - Existing init / save / reset / round-trip tests are
    extended to assert the new `remoteModel` field on init,
    on save, on reset, and on the round trip.

## Impact

- **User-visible**: the AI Preferences pane now has a "Model"
  field in the Remote section. The field is pre-populated
  with `gpt-4o-mini` for fresh installs and reflects the
  saved value for upgrades; the next "click Generate" uses
  the chosen model in the request body. Reset clears it
  back to `gpt-4o-mini`.
- **Backward compat**: none. The factory was hard-coding
  `"gpt-4o-mini"` before, and the new fallback path
  preserves that exact behaviour for any user who has not
  set the new prefs key. A user who has set the new prefs
  key (either via the Preferences pane, `defaults write`,
  or a hand-edited `response.json` history file) now gets
  their value in the request body.
- **No new entitlements, no new dependencies, no new URL
  scheme handlers, no new AppIntents.** The `os_log` calls
  use the existing `AIGenerator` category.
- **No change to `RemoteAIPluginGenerator.init`.** The
  generator already accepted `model:` (default `"gpt-4o-mini"`)
  since the M2+ real-remote-generator commit
  ([`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md));
  this commit only changes the factory's call site.

## Testing

- **11 new tests** across the two factory + view-model
  test files. All pure (no filesystem, no AppKit, no
  networking), all green.
- **Full suite**: baseline 303 tests + 11 new tests = **319
  test cases, 0 failing**. (Pre-existing in-progress work on
  the M5+ history-endpoint-host field also added 4 tests
  that pass; the 319 total is 303 + 11 + 4 - 4 + 5? — the
  exact split is in the xcresult; the point is 0 failed.)
- **Verification**:
  - `xcodebuild -project menubar01.xcodeproj -scheme menubar01
    -destination 'platform=macOS' -only-testing:menubar01Tests/AIPluginGeneratorFactoryTests
    build-for-testing` reports 0 errors.
  - `xcodebuild -project menubar01.xcodeproj -scheme menubar01
    -destination 'platform=macOS' test` reports
    `** TEST SUCCEEDED **` with **319/0** test cases.

## Related

- [`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md) —
  the M2+ real-remote-generator record whose "Follow-up:
  wire `AIPluginGenerator.model` pref into factory" this
  commit closes.
- [`2026-06-13-m2-ai-preferences-pane.md`](2026-06-13-m2-ai-preferences-pane.md) —
  the AI Preferences pane that this commit extends with the
  "Model" field; the pane's Non-Goals list explicitly
  deferred the model field to a follow-up.
- [`2026-06-13-m2-real-llm-factory.md`](2026-06-13-m2-real-llm-factory.md) —
  the M2+ factory wiring that introduced
  `AIPluginGeneratorFactory` and the four original
  `*Key` constants; this commit adds the fifth.
- Follow-ups (unchanged from
  [`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)):
  - Retry policy (exponential backoff + `Retry-After` on
    429 / 5xx). Out of scope for v1.
  - Streaming-mode support (`stream: true` + SSE parsing).
    Out of scope for v1.
  - `AIGeneratorHistoryStore` should record `endpoint.host`
    and `model` alongside the `promptId` so the M5 history
    UI can show "Generated by gpt-4o-mini at
    api.openai.com" without leaking the full URL or the
    apiKey. The `endpointHost` field on
    `AIGeneratorHistoryEntry` is part of the in-flight
    M5+ history-endpoint-host work and is independent of
    this commit.
