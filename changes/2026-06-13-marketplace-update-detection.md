# M5 update-detection follow-up: marketplace browser surfaces available plugin updates from the catalogue

Status: in-progress
Commit: TBD

## Why

The M5 marketplace browser shipped in
[`2026-06-13-m5-marketplace-browser.md`](2026-06-13-m5-marketplace-browser.md)
and the uninstall / update follow-up
[`2026-06-13-marketplace-uninstall-and-update.md`](2026-06-13-marketplace-uninstall-and-update.md)
with an "Installed" tab that lists every marketplace plugin
on disk. The list shows the on-disk manifest's `version` (when
present) but never compares it against the catalogue row's
`version` — a user has no way to know a v2 is available
without flipping back to the Catalogue tab and visually
matching the version strings. This change adds the
comparison and surfaces a "Update available" badge on the
Installed rows where the catalogue is newer.

## What changed

### New `MarketplaceVersion` value type

`menubar01/Marketplace/MarketplaceVersion.swift` is a new
file declaring a small semver-style `MAJOR.MINOR.PATCH`
value type with:

- `init?(parsing:)` that accepts `"1.2.3"` / `"v1.2.3"` /
  `"V1.2.3"` / `"1.2"` / `"1"` and zero-fills the missing
  components. Returns `nil` for unparseable input (empty,
  non-numeric components, leading dot, …).
- A `Comparable` conformance that walks `major` → `minor`
  → `patch` in order — the natural semver ordering.
- `Equatable`, `Hashable`, `Sendable` synthesis so the
  value can flow between actors (`@MainActor` view model +
  free-form parser).
- A `displayString` helper that round-trips to
  `"major.minor.patch"` for the badge / detail label.

`Sendable` is the load-bearing conformance: the
`MarketplaceBrowserViewModel` is `@MainActor` but the
parser is intentionally callable from any context (the
cataloguer / remote client are off-main).

### `MarketplaceEntry` gains a `version` field

`menubar01/Marketplace/MarketplaceEntry.swift` adds
`public let version: String?` to the catalogue row
(`Optional<String>` so the `Codable` decoder accepts
existing catalogue JSON fixtures that omit the key —
the badge logic treats `nil` and the empty string the
same as unparseable / `.unknown`). The stub
`MarketplaceClient` populates the three seed entries
(`echo`, `todays-date`, `battery-watch`) with
`"1.0.0"`. The v2 remote client (M2 / M5 follow-up)
populates the same field from the catalogue JSON when
present.

### `InstalledPluginSnapshot` gains a parsed `manifestVersion`

`menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
adds `manifestVersion: MarketplaceVersion?` to the
`InstalledPluginSnapshot` struct and populates it inside
`refreshInstalledPlugins()`. The parser is called on the
manifest's `version` string and `nil` is preserved when
the manifest omits `version` or the string is
unparseable. The parsed value is `os_log`'d at info
level so the diagnostic dump can show the on-disk
version alongside the catalogue row's.

### New `UpdateAvailability` enum + `updateAvailability(for:)` helper

`MarketplaceBrowserViewModel.swift` declares:

```swift
public enum UpdateAvailability: Equatable {
    case unknown
    case upToDate
    case available(catalogueVersion: MarketplaceVersion)
    case aheadOfCatalogue(catalogueVersion: MarketplaceVersion)
}
```

`public func updateAvailability(for snapshot: InstalledPluginSnapshot) -> UpdateAvailability`
is a pure function that:

1. Returns `.unknown` if the snapshot has no
   `manifestVersion` (manifest omits / unparseable).
2. Looks up the matching catalogue row by the snapshot's
   on-disk folder name (with a case-insensitive `name`
   fallback for the v1 uninstall path which keys the
   target URL off `entry.name`). Returns `.unknown` if
   no row matches.
3. Returns `.unknown` if the catalogue's `version` is
   unparseable.
4. Returns `.available(catalogueVersion:)` /
   `.upToDate` / `.aheadOfCatalogue(catalogueVersion:)`
   per the `Comparable` ordering.

### Installed-tab UI: badge + detail label

`menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
adds:

- `updateBadge(for:)` — renders a small green pill
  (`.available(...)`) or a neutral blue pill
  (`.aheadOfCatalogue`) next to the version on the
  sidebar row. The `.available` case is wrapped in a
  `Button` that calls `runUpdateForInstalledSnapshot(snapshot)`
  so a single tap on the pill kicks off the update
  flow (the pill is a shortcut for "click the row +
  click Update"). The pill is disabled while an
  update is already in flight.
- `updatePill(text:systemImage:tint:)` — private helper
  that gives both the `.available` and
  `.aheadOfCatalogue` cases the same visual style.
- `updateDetailLabel(for:)` — adds a green
  "v1.0.0 → v1.2.3" label to the Installed detail
  pane's metadata row when a catalogue update is
  available, mirroring the sidebar pill so the user
  reads the version delta at a glance.

### Tests

- `menubar01Tests/MarketplaceVersionTests.swift` — 6 new
  tests covering the parser, the comparator, and the
  `displayString` / `Equatable` / `Hashable`
  synthesis. All passing.
- `menubar01Tests/MarketplaceUpdateAvailabilityTests.swift`
  — 5 new tests that build a temp marketplace install
  with a known manifest, populate the view model's
  catalogue, and assert the four
  `UpdateAvailability` cases (`.available`,
  `.upToDate`, `.aheadOfCatalogue`, `.unknown` from
  missing manifest version, `.unknown` from missing
  catalogue row). All passing.

### Project

- `menubar01.xcodeproj/project.pbxproj` registers
  `MarketplaceVersion.swift` as a member of the
  menubar01 target (PBXBuildFile, PBXFileReference,
  PBXGroup children, Sources phase). The test files
  do not need an explicit pbxproj entry — the test
  target uses `PBXFileSystemSynchronizedRootGroup` which
  auto-discovers files in `menubar01Tests/`.

## Verification

- `xcodebuild test -only-testing:menubar01Tests` — all
  11 new tests pass cleanly (5
  `MarketplaceUpdateAvailabilityTests` + 6
  `MarketplaceVersionTests`) and the rest of the
  suite (≈408 pre-existing tests) passes 5/8 in
  full-suite runs. The 3 cascade failures (≈50
  unrelated tests fail per cascade) are
  pre-existing test-infrastructure flakiness —
  one failing test takes down the whole batch
  because the test runner tears down the host
  process. None of the cascade failures are in
  the marketplace browser code; they hit
  `AIGeneratorTemplateGalleryTests`,
  `RemoteAIPluginGeneratorRetryTests`, etc.,
  which the v1 marketplace changes do not
  touch. Each cascade reproduces in the
  absence of my changes (it is a pre-existing
  concurrency issue in the `xctest` host
  process) and is documented inline as
  `changes/2026-06-13-marketplace-update-detection-test-flake.md`.

Status: done
