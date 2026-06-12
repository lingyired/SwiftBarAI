# 2026-06-12: Add StatusItemMonitor to capture the actual cause of the icon-disappears bug

- **Type:** diagnostic
- **Scope:** MenuBar / AppDelegate
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
Add a passive, opt-in **diagnostic monitor** for the SwiftBar fallback
`NSStatusItem` so we can see *exactly* which code path is touching the
status bar button (and what state it is in) at the moment it goes
blank. No fix is attempted in this record — we are done guessing.

The monitor:
- Polls the status item's `isVisible`, `button?.image`,
  `button?.title`, `button?.alphaValue`, `button?.frame`, and
  `button?.window != nil` every 0.5 s on the main runloop.
- KVO-watches `button.image` and `barItem.isVisible`; logs every
  change with a full call-stack so we can see which thread and
  which symbol caused the transition.
- Logs at `.error` level (with full call-stack) the moment it
  detects the dangerous "visible but no image" or "visible but
  no window" state.

`AppDelegate.applicationDidFinishLaunching` starts the monitor.
`PluginManager.barItem` (the lazy default SwiftBar fallback item)
attaches the monitor to its own `NSStatusItem` at construction
time. `AppVersion.patch` bumped 10 → 11.

## Motivation
After p9 the user reported the icon still disappears when hovering
the Toggle Plugins submenu. I have made five successive attempts at
this bug (p3, p4, p5, p7, p8, p9, p10) and the user has correctly
called out that I am *guessing* rather than *measuring*. The user's
exact ask was:

> 请从全局的角度看，我怀疑不仅仅是新增的代码的问题，而是原本的代码外部的也会导致这个问题，有办法监听到这个图标会消失的情况吧，然后打印 LOG 之类的

The right move is to stop patching and start **observing**. The
next fix attempt will be driven by what the monitor's logs show, not
by what I think the cause is.

## Changes
- `SwiftBar/MenuBar/StatusItemMonitor.swift` (new) — a singleton
  (`StatusItemMonitor.shared`) that:
  - `start()` schedules a 0.5 s `Timer` on the main runloop.
  - `monitor(_:)` KVO-attaches to the given `NSStatusItem`'s
    `isVisible` and to its `button?.image`.
  - `pollOnce()` reads the current `isVisible` / `image` / `title`
    / `alphaValue` / `frame` / `window != nil` of the monitored
    item, and emits a single log line per state change. When
    `isVisible == true && (image == nil || window == nil)` it
    emits at `.error` level with a full `Thread.callStackSymbols`
    stack so we know which thread caused the problem.
  - Has an unused `LoggingStatusBarButton: NSButton` subclass
    kept for future use if we ever need to wrap the button
    (NSStatusItem's actual button is `NSStatusBarButton`, a
    private AppKit class, so we cannot subclass it from user
    code).
- `SwiftBar.xcodeproj/project.pbxproj` — added
  `StatusItemMonitor.swift` to the MenuBar group, the file
  references, and the main Sources build phase.
- `SwiftBar/AppDelegate.swift:97-107` — `applicationDidFinishLaunching`
  calls `StatusItemMonitor.shared.start()`.
- `SwiftBar/Plugin/PluginManger.swift:427-435` — `barItem` lazy
  var now constructs the default `MenubarItem` and immediately
  calls `StatusItemMonitor.shared.monitor(item.barItem)` so the
  monitor is attached to the SwiftBar fallback `NSStatusItem` at
  the moment of creation (before any toggle / hover / rebuild
  can touch it).
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped from `10` to `11`.

## Impact
- **User-visible:** none (this is a pure observability layer).
  The startup log stamp is now `SwiftBar v… (b…-p11)`.
- **Console.app traffic:** the monitor will emit up to 2
  `poll` log lines per second while the app is running, plus
  KVO `image` and `isVisible` change events. When the bug
  fires, the suspicious-state log line at `.error` level will
  include a full call-stack — that is the data we need.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -f SwiftBar && open …/Debug/SwiftBar.app`.
  2. Console.app: confirm `[SwiftBar startup] SwiftBar v2.1.0 (b…-p11)`.
  3. Console.app: confirm `StatusItemMonitor: starting` appears
     in the system log (filter by `subsystem == com.ameba.SwiftBar`).
  4. Wait a few seconds; observe `StatusItemMonitor: poll vis=true
     img=true win=true title=<empty> alpha=1 frame=…` lines
     confirming the steady state.
  5. Click menu bar icon, hover "开关插件", wait for the bug.
  6. When the icon disappears, Console.app should show a line
     starting with `StatusItemMonitor: poll vis=true img=false
     win=… suspicious=YES` followed by `StatusItemMonitor: STACK
     <full call stack>`. Capture both.

## Next steps (after this record)
- Take the LOG output from step 6, identify the symbol at the
  top of the call stack (it will be one of `setVisibility`,
  `applyFallbackIcon`, AppKit internal `_NSDetachedTitlebar`,
  etc.), and craft a targeted fix.
- Remove `StatusItemMonitor.swift` once the bug is fixed.
