# 2026-06-13: Mac App Store build configuration audit

- **Type:** chore
- **Scope:** `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI
- **Commit(s):** 37eeb3c
- **Status:** done

## Summary

Audit the two Xcode targets (`menubar01` direct distribution, `menubar01
MAS` Mac App Store) against the five build-configuration invariants
called out in the task description. Four invariants were already
correct; one (the MAS bundle identifier) was wrong and has been fixed,
plus a cosmetic cleanup of the MAS Release `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
declaration that used an `[arch=*]` override instead of a plain
assignment. No entitlements or source files were touched.

## Motivation

`MIGRATION_PLAN.md` § 2.1 records the post-migration state as
"Bundle identifier: `com.lingyi.menubar01` (Debug + Release × MAS +
non-MAS = 4 places)". That meant both `menubar01` and `menubar01
MAS` shipped with `CFBundleIdentifier = com.lingyi.menubar01`, which
collides with the direct-distribution build and prevents the MAS build
from being submitted to App Store Connect (Apple requires a unique
bundle identifier per app, and will reject an app whose identifier
matches one already in the store — and on the same Mac two apps
sharing a bundle identifier cannot coexist). The audit pass separates
the two with the conventional `.mas` suffix.

While in the file the MAS Release configuration was using a slightly
odd pair of settings (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = ""` plus
`"SWIFT_ACTIVE_COMPILATION_CONDITIONS[arch=*]" = MAC_APP_STORE`) to
set the Swift flag. That is functionally equivalent to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAC_APP_STORE`, so the pair
was collapsed to the plain form for consistency with the Debug
configuration.

## Changes

- `menubar01.xcodeproj/project.pbxproj`:
  - `39224E2825F4344600BABF21` (Debug, `menubar01 MAS`):
    `PRODUCT_BUNDLE_IDENTIFIER` `com.lingyi.menubar01` → `com.lingyi.menubar01.mas`.
  - `39224E2925F4344600BABF21` (Release, `menubar01 MAS`):
    `PRODUCT_BUNDLE_IDENTIFIER` `com.lingyi.menubar01` → `com.lingyi.menubar01.mas`,
    and the two-line
    `SWIFT_ACTIVE_COMPILATION_CONDITIONS = ""; "SWIFT_ACTIVE_COMPILATION_CONDITIONS[arch=*]" = MAC_APP_STORE;`
    collapsed to
    `SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAC_APP_STORE;`.

## What was already correct (verified, not changed)

| # | Invariant | Verified state |
| - | --- | --- |
| 1 | `menubar01 MAS` has `MAC_APP_STORE` in its Swift compilation conditions | Debug: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG MAC_APP_STORE"`. Release: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAC_APP_STORE` (and `menubar01MAS.xcconfig` sets `MAC_APP_STORE = YES`). |
| 2 | `menubar01 MAS` does not link Sparkle | `39224E1425F4344600BABF21` Frameworks phase lists LaunchAtLogin / Preferences / SwifCron / HotKey only. `packageProductDependencies` for the MAS target does not include the Sparkle product (only the non-MAS `menubar01` target references it). |
| 3 | `menubar01 MAS` is sandboxed | `CODE_SIGN_ENTITLEMENTS = "menubar01/Resources/menubar01 MAS.entitlements"`; that file declares `com.apple.security.app-sandbox = true`. The non-MAS `menubar01.entitlements` does not declare the sandbox entitlement. |
| 4 | `menubar01` (non-MAS) does not define `MAC_APP_STORE` | Project-level Debug has `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` only; non-MAS Release leaves the setting unset; no `GCC_PREPROCESSOR_DEFINITIONS = … MAC_APP_STORE …` anywhere on the non-MAS target. |
| 5 | MAS bundle ID is App Store specific | Now `com.lingyi.menubar01.mas` (was `com.lingyi.menubar01`, same as non-MAS). |

## Entitlements

`Glob **/*.entitlements` finds exactly two:

- `menubar01/Resources/menubar01.entitlements` — direct distribution. No `com.apple.security.app-sandbox`. Existing automation / temp-exception keys preserved as-is.
- `menubar01/Resources/menubar01 MAS.entitlements` — Mac App Store. Declares `com.apple.security.app-sandbox = true` plus `com.apple.security.automation.apple-events`, `com.apple.security.files.user-selected.read-write`, and the same `com.apple.Terminal` / `/bin` / `/etc/profile` temporary exceptions.

No entitlement files were modified.

## Impact

- The MAS `.app` will now have `CFBundleIdentifier = com.lingyi.menubar01.mas`, distinct from the direct-distribution `com.lingyi.menubar01`. Any user data previously stored under `~/Library/Containers/com.lingyi.menubar01/` (or other sandboxed paths) by an earlier MAS build will not be picked up by the new bundle id — accept that this is a one-time migration for the first MAS upload.
- The `MIGRATION_PLAN.md` § 2.1 line "Bundle identifier: `com.lingyi.menubar01` (Debug + Release × MAS + non-MAS = 4 places)" is now stale and should be updated in a follow-up doc commit; it is intentionally not edited in this audit (doc churn is out of scope).

## Testing

- `xcodebuild -project menubar01.xcodeproj -scheme menubar01 -configuration Release -destination 'platform=macOS' build` → **BUILD SUCCEEDED**. (The audit's primary verification target.)
- `xcodebuild -project menubar01.xcodeproj -scheme "menubar01 MAS" -configuration Release -destination 'platform=macOS' build` → fails on code-signing ("requires a development team") and on a pre-existing, unrelated set of `cannot find X in scope` errors in `AppDelegate.swift` / `AppDelegate+Menu.swift` / `PluginManger.swift` (the MAS Sources phase is missing `PluginGeneratorMenuCommand.swift`, `MarketplaceBrowserMenuCommand.swift`, `GeneratorHistoryMenuCommand.swift`, `AppVersion.swift`, `SystemNotificationName.swift`, `ShortcutPlugin.swift`, and `AppDelegate.swift` still imports `SPUUpdater` from Sparkle). These are pre-existing — they predate this audit and are not caused by it; they are out of scope for the five-condition audit checklist and are flagged here for a follow-up.

## Related

- `MIGRATION_PLAN.md` § 2.1, § 2.2 — final product shape (the bundle-id sentence will need a follow-up doc edit).
- `menubar01/Resources/menubar01MAS.xcconfig` — `MAC_APP_STORE = YES`. Still in place; used as the MAS target's `baseConfigurationReference` even though no `$(MAC_APP_STORE)` substitution is performed by the build settings (the Swift flag is set directly).
