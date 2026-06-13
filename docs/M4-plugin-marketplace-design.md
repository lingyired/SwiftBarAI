# M4 — PluginMarketplace catalogue + install plan

> Status: design note for the M4 deliverable of
> [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.6.
> Implementation lives in `menubar01/Marketplace/`.

## Source sketch (quoted from `AI_PLUGIN_ARCHITECTURE.md` §1.6)

```swift
public struct MarketplaceEntry: Codable, Identifiable {
    public let id: String                 // stable slug
    public let name: String
    public let summary: String
    public let category: String
    public let previewImageURL: URL?
    public let installCount: Int
    public let rating: Double
    public let generatorPromptId: String  // provenance
    public let signedBy: String?          // publisher signature
}
```

M4 extends that sketch with `MarketplacePackage`
(`id` + `manifest: PluginManifest` + `entryScript` + `entryFilename`),
`MarketplaceError`, and the abstract `MarketplaceClient` protocol.

## In scope (M4 — this commit)

- **Data layer only.** Three new files plus a unit test file.
- **Deterministic stub client.** `StubMarketplaceClient` returns a
  hard-coded 3-entry catalogue (`echo`, `todays-date`,
  `battery-watch`) and matching `MarketplacePackage` payloads. No
  `URLSession`, no `Bundle.main`, no fixtures on disk — the test
  suite is fully self-contained.
- **Pure install plan.** `MarketplaceInstaller.plan(entry:package:)`
  validates the (entry, package) pair and returns a
  `MarketplaceInstallPlan` value. The plan has the target subfolder
  name (`_marketplace`), the entry filename, the serialised manifest
  bytes, the entry script bytes, and the `overwriteExisting` flag.
  No bytes hit disk in M4.

## Deferred (M5 and later)

- **Disk write.** Hooking `MarketplaceInstallPlan` into
  `PluginManager.importPlugin(from:)` and the existing
  `FolderPlugin` loader.
- **Browser UI.** The marketplace sheet, search, category filter,
  preview pane, and "Install" button — all of §1.6's user-visible
  flow.
- **Remote client.** `MarketplaceClientFactory.makeRemote(endpoint:)`
  is a no-op factory call today; the actual `RemoteMarketplaceClient`
  will land alongside the catalogue endpoint and a signing story.
- **Signing / notarisation.** Per `AI_PLUGIN_ARCHITECTURE.md` §5,
  out of scope for v1.

## New files

| Path | Role |
| --- | --- |
| `menubar01/Marketplace/MarketplaceEntry.swift` | `MarketplaceEntry`, `MarketplacePackage`, `MarketplaceError` |
| `menubar01/Marketplace/MarketplaceClient.swift` | `MarketplaceClient` protocol, `StubMarketplaceClient`, `MarketplaceClientFactory` |
| `menubar01/Marketplace/MarketplaceInstaller.swift` | `MarketplaceInstallPlan`, `MarketplaceInstaller.plan` |
| `menubar01Tests/MarketplaceTests.swift` | 6 Swift Testing tests covering catalogue, fetch, plan, and id-mismatch |
| `docs/M4-plugin-marketplace-design.md` | This file |

## Why a hard-coded catalogue

The stub catalogue is in code, not in a remote endpoint, on
purpose:

1. The unit test is deterministic — same 3 ids, same ratings, same
   scripts on every machine and every CI run.
2. M5 can swap the stub for a remote client without touching the
   `MarketplaceClient` protocol or the installer plan.
3. The `MarketplaceClientFactory.makeStub()` call site is the
   one place that decides which client a given build uses; flipping
   it to a remote factory is a one-line change in M5.
