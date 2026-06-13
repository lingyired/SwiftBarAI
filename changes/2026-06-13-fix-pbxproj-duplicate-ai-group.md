# 2026-06-13: Remove duplicate AI group children from root group

- **Type:** chore
- **Scope:** `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Strip the three leftover `AIGeneratorHistoryEntry.swift`,
`AIGeneratorHistoryStore.swift`, and `AIGeneratorMenuNode.swift`
children entries that the root project group carried in addition to
the `AI` group. `pbxproj.add_file(force=True)` (in pbxproj 4.3.3)
inserted the file reference into both the explicit `AI` group and
the catch-all root group, which Xcode surfaces on every build as
the "file reference is a member of multiple groups" warning.

## Motivation

Every `xcodebuild` invocation produced three identical warnings:

```
warning: The file reference for "menubar01/AI/AIGeneratorHistoryEntry.swift" is a member of multiple groups ("AI" and "")
warning: The file reference for "menubar01/AI/AIGeneratorHistoryStore.swift" is a member of multiple groups ("AI" and "")
warning: The file reference for "menubar01/AI/AIGeneratorMenuNode.swift" is a member of multiple groups ("AI" and "")
```

The membership is cosmetic — the file references, build file
entries, and Sources build phase entries were all correct — but
the noise makes real warnings hard to spot in the build log, and
Xcode's own "Refresh" / "Convert to membership-in-only-one-group"
prompt triggers on the duplicate membership. The fix is to leave
the file reference in the `AI` group (where it logically belongs
since the path is `menubar01/AI/...`) and drop the duplicate
children entry from the root group.

## Changes

- `menubar01.xcodeproj/project.pbxproj` — removed three lines from
  the root `PBXGroup` (id `3920747125460FD000213DBE`) children
  array: the two consecutive children entries
  `6B6D4C6E86A4F030A93DD9DB /* AIGeneratorHistoryEntry.swift */`
  and `DE9D408C85249D9BB0AF1DD4 /* AIGeneratorHistoryStore.swift */`
  between `PluginCapabilityGate.swift` and
  `PluginManager+MarketplaceInstall.swift`, and the lone
  `AB3F44F2B40C403EDCC0F57F /* AIGeneratorMenuNode.swift */`
  between `GeneratorHistoryMenuCommand.swift` and
  `GeneratorHistoryExporter.swift`.

No other lines changed. The `AI` group's children array (lines
382–384) still lists all three files, the three `PBXFileReference`
entries (lines 277, 290, 302) are intact, the four
`PBXBuildFile` entries (lines 14, 115, 127, 192) are intact, and
the four `PBXSourcesBuildPhase` entries (lines 1012–1013, 1022,
1096) are intact.

## Impact

- Three "member of multiple groups" warnings silenced at every
  build.
- No source file membership in any other group was touched.
- No `PBXFileReference`, `PBXBuildFile`, `PBXSourcesBuildPhase`,
  or `PBXFileSystemSynchronizedRootGroup` entry was modified.
- No build setting, deployment target, or compile flag was
  touched.
- The file's effective compilation is unchanged: it is still
  compiled into both the non-MAS and MAS targets, and it is still
  visible under the `AI` group in the Xcode navigator.

## Testing

- `plutil -lint menubar01.xcodeproj/project.pbxproj`
  → `OK` (file is well-formed OpenStep plist).
- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -destination 'platform=macOS' -configuration Debug
  build-for-testing 2>&1 | grep -E "warning:|error:"`
  → empty output (zero warnings, zero errors).
- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -destination 'platform=macOS' test 2>&1 | tail -3`
  → `** TEST SUCCEEDED **` (full test suite, including the M2
  history Regenerate tests that exercise
  `AIGeneratorHistoryEntry` / `AIGeneratorMenuNode` paths, all
  pass).

## Related

- `e033493` (feat: M2 AI preferences pane, M5 history follow-ups,
  M5 marketplace install prompt) — the commit that introduced the
  three file references via `pbxproj.add_file(force=True)` and
  produced the duplicate-group warnings this record removes.
- `c60a88c` (feat(ai): M5 history Regenerate opens M2 sheet with
  original request) — a follow-up that adds
  `GeneratorHistoryMenuCommandTests.swift`; the new tests pass
  under the fixed pbxproj and confirm the build phase wiring is
  intact.
