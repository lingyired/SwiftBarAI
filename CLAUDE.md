# SwiftBar Development Guide

## 项目功能总结

SwiftBar 是一款 macOS 菜单栏自定义工具（BitBar/xbar 的官方继任者），用 Swift 编写，基于 AppKit + SwiftUI。用户只需将可执行脚本（任何语言）放入"插件目录"，脚本输出就会实时渲染为 macOS 顶部状态栏项目和下拉菜单。

### 核心能力
- **脚本即插件**：单文件可执行，文件名带刷新间隔（如 `battery.10s.sh`），输出按行解析为状态栏/下拉菜单节点。
- **五种插件类型**：
  - `ExecutablePlugin` — 有限时脚本（执行一次返回结果）
  - `StreamablePlugin` — 长流式脚本（持续输出，按行推送）
  - `ShortcutPlugin` — Apple Shortcuts 封装（通过 AppleScript 调用 Shortcuts.app）
  - `EphemeralPlugin` — 通过 `swiftbar://setephemeralplugin` URL 临时展示的菜单项
  - `PackagedPlugin` — `.swiftbar` 目录型插件包（自带 `plugin.sh`、`metadata.json`、图标等）
- **丰富的菜单参数**：每行支持 `href=`、`bash=`、`terminal=`、`color=`、`font=`、`size=`、`refresh=`、`dropdown=`、`notify=`、`webview=` 等键值对（详见 `MenuLineParameters`）。
- **插件内嵌元数据**：脚本首行可包含 `<swiftbar.refresh>`、`<swiftbar.schedule>`、`<swiftbar.image>`、`<swiftbar.click>`、`<swiftbar.triggers>` 等 xbar 风格元数据块。
- **终端启动**：菜单点击可在 Terminal.app / iTerm2 / Ghostty / Kitty 中执行脚本（详见 `AppShared`）。
- **系统通知**：脚本可通过 `notify=`/`alert=` 触发 `UNUserNotificationCenter` 通知。
- **Siri/Shortcuts 集成**：提供 `GetPluginsIntent`、`EnablePluginIntent`、`DisablePluginIntent`、`ReloadPluginIntent`、`SetEphemeralPluginIntent` 五个 Intent。
- **URL Scheme**：`swiftbar://` 处理 `refreshplugin`、`enableplugin`、`addplugin`、`setephemeralplugin`、`notify`、`copysystemreport` 等。
- **插件仓库**："Get Plugins…" 窗口基于 [swiftbar/swiftbar-plugins](https://github.com/swiftbar/swiftbar-plugins) 仓库，提供浏览、搜索、安装、卸载。
- **休眠/唤醒响应**：系统休眠时停止所有插件，唤醒后重新调度，并刷新 `OS_LAST_SLEEP_TIME` / `OS_LAST_WAKE_TIME` 环境变量。
- **诊断系统**：随时生成系统报告（`PluginManager.currentSystemReport(reason:)`），可复制到剪贴板或写入 `~/Library/Application Support/SwiftBar/Diagnostics/latest-system-report.txt`。
- **两种发布渠道**：直接分发版（带 Sparkle 自动更新）和 Mac App Store 版（无 Sparkle、沙盒友好），通过 `MAC_APP_STORE` 编译开关切换。

### 架构分层
1. **App 层** — `main.swift`、`AppDelegate` + `+Menu` / `+Toolbar` / `+Intents` 扩展，处理生命周期、URL 路由、Siri/Shortcuts。
2. **Plugin 层** — `Plugin` 协议与五种实现，由 `PluginManager` 单例调度（`pluginInvokeQueue` + `menuUpdateQueue` 两个 `OperationQueue`）。
3. **MenuBar 层** — `MenubarItem` + `MenuItemNode` + `MenuDiff` + `FoldableMenuItemView`，对 `NSStatusItem` 和 `NSMenu` 做增量更新（基于值等价的 `MenuItemNode: Equatable`）。

详细架构与模块说明见 [`docs/00-README.md`](docs/00-README.md)，按需读取：
- 项目总览 → [`docs/01-Project-Overview.md`](docs/01-Project-Overview.md)
- 架构分层 → [`docs/02-Architecture.md`](docs/02-Architecture.md)
- 应用生命周期 → [`docs/03-Application-Lifecycle.md`](docs/03-Application-Lifecycle.md)
- 插件系统 → [`docs/04-Plugin-System.md`](docs/04-Plugin-System.md)
- 菜单栏渲染 → [`docs/05-MenuBar-System.md`](docs/05-MenuBar-System.md)
- 脚本输出语法 → [`docs/06-Plugin-Output-Parsing.md`](docs/06-Plugin-Output-Parsing.md)
- 脚本执行 → [`docs/07-Script-Execution.md`](docs/07-Script-Execution.md)
- 偏好与存储 → [`docs/08-Preferences-and-Storage.md`](docs/08-Preferences-and-Storage.md)
- 插件仓库 → [`docs/09-Plugin-Repository.md`](docs/09-Plugin-Repository.md)
- Intents 与 URL Scheme → [`docs/10-Intents-and-URL-Scheme.md`](docs/10-Intents-and-URL-Scheme.md)
- 界面 → [`docs/11-User-Interface.md`](docs/11-User-Interface.md)
- 工具类 → [`docs/12-Utilities.md`](docs/12-Utilities.md)
- 构建与运行 → [`docs/13-Build-and-Run.md`](docs/13-Build-and-Run.md)

---

## Build Commands
- Open project: `open SwiftBar/SwiftBar.xcodeproj`
- Build: Press "Play" in Xcode
- Test: Run unit tests through Xcode's Test Navigator
- Debug: Enable Plugin Debug Mode with `defaults write com.ameba.SwiftBar PluginDebugMode -bool YES`

## Code Style Guidelines
- **Imports**: Group by standard libraries first, then third-party libraries
- **Naming**: Use descriptive camelCase variables, PascalCase for types
- **Types**: Swift strong typing with proper optionals handling
- **Error Handling**: Use do/catch blocks, proper error propagation
- **File Organization**: Keep related functionality in dedicated files
- **UI**: Use SwiftUI for new UI components when possible
- **Comments**: Document public APIs and complex logic
- **Dependencies**: SwiftBar uses HotKey, LaunchAtLogin, Preferences, Sparkle, SwiftCron

## Terminal Support
SwiftBar supports running scripts in these terminals:
- macOS Terminal.app
- iTerm2
- Ghostty
- Kitty

## Environment Variables
SWIFTBAR_VERSION, SWIFTBAR_BUILD, SWIFTBAR_PLUGINS_PATH, SWIFTBAR_PLUGIN_PATH, 
SWIFTBAR_PLUGIN_CACHE_PATH, SWIFTBAR_PLUGIN_DATA_PATH, SWIFTBAR_PLUGIN_REFRESH_REASON,
OS_APPEARANCE, OS_VERSION_MAJOR, OS_VERSION_MINOR, OS_VERSION_PATCH
