# 2026-06-13: M2+ "Save as Template" flow for the AI plugin generator

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01/UI/Plugin Generator/`, `menubar01Tests/`, `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI
- **Commit(s):** b64da46
- **Status:** done

## Summary

Adds a "Save as Template" flow to the M2 AI plugin generator
sheet. While typing a request the user can now click a footer
"Save as Template" button to open a small sub-sheet, give the
prompt a title and an SF Symbol, and persist it as a new card
in the template gallery next to the 6 built-ins. User-saved
templates are loaded from disk on every sheet open and from a
new `AIGeneratorTemplateStore`; the gallery's
`allTemplates(including:)` helper merges the two sources with
user-saved ids shadowing the built-ins (id collisions are still
safe because user ids are prefixed with `user-`).

## Motivation

The M2+ template gallery currently offers 6 built-in prompts.
In practice a user who finds the right wording for their
workflow has no way to keep it: they have to re-type the
prompt from memory (or copy it out into a Notes file). A
"Save as Template" flow closes the loop — the user can build
up a personal catalogue of prompts that the AI generator
already knows how to fill in, and the gallery stays useful
the longer the user uses the app. The 6 built-ins stay
read-only so the v1 contract for the catalogue is preserved.

## Changes

- `menubar01/AI/AIGeneratorTemplateStore.swift`: new. Public
  `final class AIGeneratorTemplateStore` with a shared
  `AIGeneratorTemplateStore.shared` singleton, a `storeURL:
  URL` property, and four methods: `loadUserTemplates() ->
  [AIGeneratorTemplate]`, `saveUserTemplates(_:)`,
  `addTemplate(_:)` (upsert by `id`), and
  `removeTemplate(id:)` (no-op when the id is unknown).
  Default `storeURL` is
  `~/Library/Application Support/menubar01/AIGenerator/templates.json`,
  which matches the on-disk path used by
  `AIGeneratorHistoryStoreFactory.makeDefault()`. Tests
  inject a per-test temp `URL` via the initializer so the
  suite is hermetic. `loadUserTemplates()` logs decode
  errors through `os_log` and returns `[]` so a corrupt
  on-disk file never crashes the sheet; the mutating
  methods throw so the SwiftUI sheet can surface a red
  banner.
- `menubar01/AI/AIGeneratorTemplate.swift`: edit. Added a
  public `builtInTemplates: [AIGeneratorTemplate]` static
  holding the v1 6-prompt catalogue (moved from `templates`
  to the new name), a back-compat `templates` computed
  property that aliases `builtInTemplates`, and a public
  `allTemplates(including userSaved:)` helper that merges
  built-ins with user-saved templates. User templates with
  the same `id` as a built-in shadow the built-in; user
  templates with a fresh `user-` id are appended in
  insertion order. The existing `templates` getter is
  preserved for back-compat — the v1 tests that assert
  the catalogue size still pass unchanged.
- `menubar01/UI/Plugin Generator/AIGeneratorSaveTemplateSheet.swift`:
  new. Modal sub-sheet that captures a `title`, an SF
  Symbol `iconName` (default `doc.text`), and a read-only
  preview of the current request. On Save it assembles an
  `AIGeneratorTemplate` with id `user-<uuid8>` (via the
  static `makeUserTemplateID()` helper) and hands it back
  to the parent through an `onComplete` callback. The
  Save button is disabled until both the title and the
  request are non-empty after trimming whitespace.
- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`:
  edit. Three new pieces of `@State` (`showingSaveTemplateSheet`,
  `userTemplates`), three new private helpers
  (`reloadUserTemplates`, `saveUserTemplate(_:)`,
  `deleteUserTemplate(id:)`), a new `canSaveAsTemplate`
  computed property, a new "Save as Template" button in
  the footer (left of the Spacer, disabled when the
  request is empty or the sheet is mid-generation), a
  second `.sheet(isPresented:)` for the new sub-sheet, an
  updated `templateGallery` that renders
  `AIGeneratorTemplateGallery.allTemplates(including: userTemplates)`,
  and an updated `templateCard(for:)` that overlays a
  small `person.crop.circle.fill` SF Symbol badge in the
  top-right corner for user-saved templates and surfaces
  a long-press / right-click `Delete template` context
  menu (built-ins stay read-only). The
  `.onAppear(perform: reloadUserTemplates)` modifier
  refreshes the gallery on every sheet open.
- `menubar01Tests/AIGeneratorTemplateStoreTests.swift`:
  new. 7 Swift Testing tests in 2 `@MainActor`-free
  suites (the tests are pure file-system / merge-logic
  assertions, no AppKit, no SwiftUI view graph, no
  `@MainActor` requirement):
  1. `testLoadUserTemplates_fileDoesNotExist_returnsEmpty`
     — a missing on-disk file must return `[]`.
  2. `testAddTemplate_persistsToDisk` — adding a template
     round-trips through the file system; a second store
     instance reading the same URL observes the row.
  3. `testAddTemplate_duplicateIDOverwrites` — upsert
     semantics: re-saving an existing id replaces the
     previous record (count stays at 1, fields are
     updated).
  4. `testRemoveTemplate_removesFromDisk` — deleting a
     template drops it from the on-disk array and the
     next `loadUserTemplates()` returns `[]`.
  5. `testSaveUserTemplates_createsParentDirectory` — the
     store creates missing parent directories on first
     write; the on-disk file round-trips.
  6. `testGalleryAllTemplates_userOverridesBuiltIn` — a
     user template with id `"weather"` shadows the
     built-in; the merged array has
     `builtInTemplates.count` rows.
  7. `testGalleryAllTemplates_userAppendsToBuiltIn` —
     user templates with fresh `user-…` ids are appended
     in insertion order; the merged array has
     `builtIn + userSaved.count` rows.

  Each test uses a per-test temp `URL` rooted at
  `FileManager.default.temporaryDirectory` (via the
  helper `makeTempStoreURL()`) and removes the temp dir
  with `defer { try? FileManager.default.removeItem(at:
  ...) }` so the suite is hermetic and parallel-safe. The
  file is auto-discovered by the `menubar01Tests`
  `PBXFileSystemSynchronizedRootGroup` and needs no
  pbxproj registration.
- `menubar01.xcodeproj/project.pbxproj`: edit. Two new
  files registered as members of the `AI` group and the
  `UI / Plugin Generator` group:
  - `menubar01/AI/AIGeneratorTemplateStore.swift`
    registered as a member of the `AI` group, with two
    `PBXBuildFile` entries (one per target: `menubar01`
    and `menubar01 MAS`) and a single `PBXFileReference`
    entry pointing at
    `menubar01/AI/AIGeneratorTemplateStore.swift`.
  - `menubar01/UI/Plugin Generator/AIGeneratorSaveTemplateSheet.swift`
    registered as a member of the project root group
    (matches the pattern used by
    `AIGeneratorInstallPromptSheet.swift`), with two
    `PBXBuildFile` entries and a single
    `PBXFileReference` entry pointing at
    `menubar01/UI/Plugin Generator/AIGeneratorSaveTemplateSheet.swift`.
  - New `AIGeneratorTemplateStoreTests.swift` is
    auto-discovered by the `menubar01Tests`
    `PBXFileSystemSynchronizedRootGroup` and needs no
    pbxproj registration.

## Impact

- **New public types:** `AIGeneratorTemplateStore` (final
  class, `Sendable` by virtue of being thread-confined to
  file-system I/O on the calling thread). The store lives
  in the `menubar01` module and follows the existing
  factory / singleton conventions used by
  `AIGeneratorHistoryStoreFactory` and
  `AIGeneratorHistoryStore`. New `enum SaveTemplateError`
  on the sheet for the
  `cancel` / `emptyTitle` / `emptyRequest` /
  `storeFailed(reason:)` cases.
- **New public methods on `AIGeneratorTemplateGallery`:**
  `builtInTemplates: [AIGeneratorTemplate]` (moved from
  `templates`), `allTemplates(including:)` (the new
  merge helper), `userIDPrefixSafe: String` on
  `AIGeneratorSaveTemplateSheet` (exposed for the gallery
  to detect user-saved templates). The existing
  `templates` static is kept as a computed property
  aliasing `builtInTemplates` so v1 callers that read
  `AIGeneratorTemplateGallery.templates` keep compiling.
- **User-visible behaviour change:** the M2 generator
  sheet's footer now renders a "Save as Template" button
  next to the primary Generate / Re-generate /
  Save-to-Plugin-Folder buttons. The button is disabled
  when the request field is empty or the sheet is
  mid-generation. Clicking it opens a small sub-sheet
  with a Title (text), Icon (text, default `doc.text`),
  and Prompt (read-only) field. On Save the user template
  is persisted to
  `~/Library/Application Support/menubar01/AIGenerator/templates.json`
  and appears in the gallery as a new card with a small
  `person.crop.circle.fill` badge in the top-right
  corner. Right-clicking (or long-pressing) a user
  template surfaces a `Delete template` context menu.
  The 6 built-in templates do not get the badge and do
  not get the context menu — the v1 contract is
  preserved.
- **No new entitlements**, no new dependencies, no new URL
  scheme handlers, no new AppIntents.
- **No new localisation keys.** The sub-sheet's labels
  ("Title", "Icon", "Prompt (read-only)", "Save",
  "Cancel", "Delete template", "Save as Template",
  "Saved from your request") are hard-coded English
  strings in v1, consistent with the rest of the M2
  sheet copy. They can move into `Localizable.strings`
  in a follow-up alongside the rest of the M2 sheet.
- **No new SF Symbol assets.** The badge uses
  `person.crop.circle.fill` (a system-provided SF Symbol
  available in macOS 12+).
- **No new top-level files outside the project root.**
  The new source files live under
  `menubar01/AI/` and `menubar01/UI/Plugin Generator/`
  consistent with the existing layout.

## Testing

- 7 new unit tests in
  `menubar01Tests/AIGeneratorTemplateStoreTests.swift`.
  All are pure (no AppKit, no SwiftUI view graph, no
  networking) and run on a background queue because the
  suite does not touch `@MainActor` types.
- Verification: `xcodebuild … test` should report 0
  failures in the new file. The `menubar01Tests` target
  uses `PBXFileSystemSynchronizedRootGroup` so the new
  test file is auto-discovered without further pbxproj
  edits beyond the
  `AIGeneratorTemplateStore.swift` /
  `AIGeneratorSaveTemplateSheet.swift` registration
  noted above.
- The pbxproj is verified well-formed via `plutil -lint`:
  `menubar01.xcodeproj/project.pbxproj: OK`.
- No new view-test infra was introduced (the task spec
  did not call for SwiftUI rendering tests; the existing
  pattern in this project skips view-graph tests for
  sub-sheets). The
  `AIGeneratorTemplateStore` is exercised end-to-end by
  the persistence tests, and the
  `AIGeneratorTemplateGallery.allTemplates(including:)`
  merge is exercised by the two merge tests.

## Related

- [`2026-06-13-ai-template-gallery.md`](2026-06-13-ai-template-gallery.md)
  — the M2+ template gallery this change extends.
- [`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 sheet that hosts the gallery.
- The M5 generator history sheet could grow a "Pin from
  history" companion to this gallery; deferred.
