# 2026-06-13: M2 AI plugin generator template gallery

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01/UI/Plugin Generator/`, `menubar01Tests/`, `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Adds a "Template Gallery" to the M2 AI plugin generator sheet.
The user can now one-click load a pre-made prompt into the
generator's request field from a horizontally-scrolling row of
6 curated template cards (Weather, Battery, Stock price, Hacker
News, Calendar, Docker). Picking a template fills the request
text but does NOT auto-generate — the user is expected to review
and tweak the prompt before clicking "Generate". The gallery
makes the M2 sheet feel more like a product (no more blank-page
prompt paralysis) and doubles as a "what can I generate?"
catalogue.

## Motivation

The M2 AI sheet currently asks the user to type a free-form
request from scratch. In practice users either:

1. Don't know what to type → close the sheet.
2. Type a vague prompt → get a vague plugin.
3. Spend 30 seconds crafting a precise prompt → never use the
   sheet again.

A template gallery solves all three: the user can pick a
realistic starting point, tweak the wording, and ship. The
gallery is also useful documentation — it tells the user "this
is the kind of plugin the generator can produce" by example,
which is more compelling than a blank text editor.

## Changes

- `menubar01/AI/AIGeneratorTemplate.swift`: new. Public
  `struct AIGeneratorTemplate: Identifiable, Hashable, Sendable`
  with `id`, `title`, `description`, `prompt`, and
  `systemImageName` (SF Symbol) fields. Public `enum
  AIGeneratorTemplateGallery` exposing the v1 catalogue as a
  static `templates: [AIGeneratorTemplate]` array. The 6 v1
  templates are: Weather (`cloud.sun`), Battery
  (`battery.100`), Stock price (`chart.line.uptrend.xyaxis`),
  Hacker News (`newspaper`), Calendar (`calendar`), and Docker
  (`shippingbox`). All SF Symbols are macOS 12+. The gallery
  is append-only — renaming or removing a template is a
  breaking change for anyone who has bookmarked one.
- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`: edit.
  New `templateGallery` view above the request `TextEditor`,
  rendered as a `ScrollView(.horizontal) { LazyHStack { ... } }`
  of 200x120-point rounded-rectangle cards. Each card shows an
  SF Symbol (24pt, accent-coloured), the title (semibold), and
  a 2-line secondary description. Tapping a card calls
  `viewModel.request = template.prompt` inside a
  `withAnimation(.easeInOut(duration: 0.15))` block and fires
  an `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`
  haptic so the user gets tap confirmation. The card does NOT
  call `viewModel.generate()` / `generateStreaming()` —
  loading a template is a fill-only operation per the v1
  contract.
- `menubar01Tests/AIGeneratorTemplateGalleryTests.swift`: new.
  5 Swift Testing tests in 1 `@MainActor` suite:
  1. `testGallery_hasExpectedNumberOfTemplates` — assert 6.
  2. `testGallery_templateIDsAreUnique` — every `id` in the
     gallery is distinct (so SwiftUI `ForEach` and any future
     bookmark/recently-used feature can use `id` as a key).
  3. `testGallery_templatePromptsAreNonEmpty` — every
     `prompt`, `title`, and `systemImageName` is non-empty
     after trimming whitespace.
  4. `testGallery_loadingTemplateIntoRequestField_doesNotAutoGenerate`
     — assigning a template's prompt to `viewModel.request` does
     NOT increment the mock generator's `generate` / `stream`
     call count. The VM stays in `.idle` with `latestPlugin`
     `nil`. Uses a test-local `CallCountingMockAIPluginGenerator`
     so the test does not depend on a sibling test type.
  5. `testGallery_loadingSameTemplateTwice_isIdempotent` —
     double-tap protection. No crash, no state duplication, no
     extra generator call.
- `menubar01.xcodeproj/project.pbxproj`: edit. New
  `AIGeneratorTemplate.swift` registered as a member of the
  `AI` group, with two `PBXBuildFile` entries (one per target:
  `menubar01` and `menubar01 MAS`) and a single
  `PBXFileReference` entry pointing at
  `menubar01/AI/AIGeneratorTemplate.swift`. New
  `AIGeneratorTemplateGalleryTests.swift` is auto-discovered by
  the `menubar01Tests` `PBXFileSystemSynchronizedRootGroup`
  and needs no pbxproj registration.

## Impact

- **New public types:** `AIGeneratorTemplate` (struct,
  value-typed, `Sendable`) and `AIGeneratorTemplateGallery`
  (enum, value-typed). Both live in the `menubar01` module and
  follow the existing public-API conventions used by
  `AIGeneratorContext`, `GeneratedPlugin`, and the
  `AIPluginGenerator` protocol.
- **User-visible behaviour change:** the M2 generator sheet
  now renders a horizontal "Start from a template" row of 6
  pre-made prompt cards above the request text editor. Tapping
  a card fills the request field with the template's prompt
  and gives a brief scale + haptic. Tapping a card never
  triggers a generator round-trip — the user must click
  "Generate" as before.
- **No new entitlements**, no new dependencies, no new URL
  scheme handlers, no new AppIntents.
- **No new localisation keys.** The gallery titles and
  descriptions are hard-coded English strings in v1,
  consistent with the rest of the M2 sheet copy. They can
  move into `Localizable.strings` in a follow-up alongside the
  rest of the M2 sheet.
- **No new SF Symbol assets.** All 6 symbols are
  system-provided SF Symbols available in macOS 12+.

## Testing

- 5 new unit tests in
  `menubar01Tests/AIGeneratorTemplateGalleryTests.swift`. All
  are pure (no AppKit, no SwiftUI view graph, no networking)
  and run on the main actor because the integration tests touch
  `AIGeneratorViewModel` (which is `@MainActor`).
- Verification: `xcodebuild … test` should report 0 failures
  in the new file. The `menubar01Tests` target uses
  `PBXFileSystemSynchronizedRootGroup` so the new test file
  is auto-discovered without further pbxproj edits beyond the
  `AIGeneratorTemplate.swift` registration noted above.
- The pbxproj is verified well-formed via `plutil -lint`:
  `menubar01.xcodeproj/project.pbxproj: OK`.
- No new view-test infra was introduced (the task spec called
  the SwiftUI rendering test "optional, skip if no view test
  infra" — there is no SwiftUI view-test infra in this
  project today, so the rendering test was not written).
  The four `viewModel`-level integration tests cover the
  "template loads into request field" contract end-to-end.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../../AI_PLUGIN_ARCHITECTURE.md)
  §1.5 (the M1 contract the M2 sheet consumes) and §6 (the
  M2 roadmap entry).
- [`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 sheet this change extends.
- The M5 generator history sheet could grow a "Pin from
  history" companion to this gallery; deferred.
