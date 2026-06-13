# 2026-06-13 — docs: M2 / M3 / M5 feature documentation

> **Status:** open → done
> **Authors:** Trae AI (M3 generation)
> **Date:** 2026-06-13

## Summary

Closes the documentation gap for the M2+ AI streaming layer,
the M3 plugin capabilities gate (with the M2+ AI install
prompt, the M5 marketplace install prompt, and the plugin
About view's Permissions section), and the M5 history export
with Finder reveal. Adds a "Recent additions" section to the
root `README.md` linking to the new entries.

## Why

Each of the underlying changes had a `changes/<date>-*.md`
record, but the user-facing / contributor-facing entry point
— the `docs/` tree and the root `README.md` — did not
describe the new behaviour. New contributors trying to
follow the M2+ streaming or the M3 capability flow had to
reconstruct the design from the `changes/` records and the
Swift source.

## What changed

### New docs

- **`docs/M2-ai-streaming.md`** — describes the new
  `AIPluginGenerator.stream(request:context:)` protocol
  method, the `AIPluginGeneratorStreamEvent` enum
  (`.textDelta(_)` / `.finished(_)`), the
  `RemoteAIPluginGenerator.stream(...)` SSE implementation,
  the `AIGeneratorViewModel.streamingPreview` /
  `generateStreaming()` UX, the auto-fallback to
  non-streaming `generate()` for generators whose default
  `stream(...)` throws
  `AIGeneratorError.streamingUnsupported`, and how the M2
  sheet renders the streaming preview.

- **`docs/M3-plugin-capabilities.md`** — describes the
  `PluginCapability` enum (the v1.1 object form, the
  `isGrantedByDefault` rule, the five cases — `network`,
  `clipboard`, `notifications`, `calendar`, `fileWrite`),
  the `PluginCapabilityGate` (`grant` / `revoke` / `granted`
  / `isGranted` / `verify` and the on-disk schema
  `PluginCapabilityGate.grants.v1`), the install flow
  integration through
  `PluginManager.installMarketplacePluginWithCapabilityGate(...)`,
  the M5 marketplace browser's "Permissions" sub-sheet, the
  M2 AI generator's "Install" prompt sheet, and the plugin
  About view's "Permissions" section (with the new revoke
  button).

- **`docs/M5-history-export-reveal.md`** — describes the
  `NSSavePanel` flow, the new `revealInFinder(_:)` step
  (with the `NSWorkspace.shared.activateFileViewerSelecting`
  call), the `MANIFEST.json` written at the zip root
  (`appVersion`, `appBuild`, `exportedAt`, `entryCount`,
  `provider`), and the user-facing success banner.

### README update

- **`README.md`** — adds a top-level "Recent additions"
  section linking to the three new docs and the existing
  `docs/M5-marketplace-install-prompt.md`. Placed
  immediately above the existing "Highlights" section so
  the four most recent user-visible features are the first
  thing a new contributor reads.

## Risks

None. Documentation-only change. The underlying code is
unaffected; the only side-effect is that contributors can
now find the streaming / capability / export-reveal
behaviour without grepping the source.

## Follow-ups

None of the docs entries are auto-generated; future
features should follow the same `docs/M<N>-*.md` pattern
referenced from the "Recent additions" section of
`README.md`.

## Related records

- [`2026-06-13-remote-ai-streaming.md`](2026-06-13-remote-ai-streaming.md)
- [`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
- [`2026-06-13-m3-capability-gate.md`](2026-06-13-m3-capability-gate.md)
- [`2026-06-13-capability-gate-extension.md`](2026-06-13-capability-gate-extension.md)
- [`2026-06-13-m2-install-prompt-sheet.md`](2026-06-13-m2-install-prompt-sheet.md)
- [`2026-06-13-m5-marketplace-install-prompt.md`](2026-06-13-m5-marketplace-install-prompt.md)
- [`2026-06-13-marketplace-install-capability-gate.md`](2026-06-13-marketplace-install-capability-gate.md)
- [`2026-06-13-plugin-capabilities-about-ui.md`](2026-06-13-plugin-capabilities-about-ui.md)
- [`2026-06-13-history-exporter-manifest.md`](2026-06-13-history-exporter-manifest.md)
- [`2026-06-13-history-export-reveal-in-finder.md`](2026-06-13-history-export-reveal-in-finder.md)
