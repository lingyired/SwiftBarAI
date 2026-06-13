# menubar01 Development Guide

## 项目功能总结

menubar01 是一款 macOS 菜单栏自定义工具，用 Swift 编写，基于 AppKit + SwiftUI。
用户把一个包含 `manifest.json` + 入口脚本的目录丢进"插件目录"，menubar01
就会把它渲染成 macOS 顶部状态栏项目和下拉菜单。

### 核心能力
- **单插件格式** — 一个目录里 `manifest.json`（元数据 + 入口声明）+ 一个
  入口脚本（任何语言、任何文件名），就是全部。完整规范见
  [`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md)。
- **三种 `PluginType`**：
  - `Executable`（默认）— 一次性脚本，stdout 解析为菜单
  - `Shortcut` — Apple Shortcuts 封装（通过 AppleScript 调用 Shortcuts.app）
  - `Ephemeral` — 通过 `menubar01://setephemeralplugin` URL 临时展示的菜单项
- **丰富的菜单参数**：每行支持 `href=`、`bash=`、`terminal=`、`color=`、
  `font=`、`size=`、`refresh=`、`dropdown=`、`notify=`、`webview=` 等键值对
  （详见 `MenuLineParameters`）。
- **`manifest.json` 元数据**：name / version / author / description / aboutUrl /
  image / type / entry / refreshInterval / schedule / runInBash / environment /
  dependencies / parameters / hideAbout / hideRunInTerminal / hideLastUpdated /
  hideDisablePlugin / hideMenubar01。脚本内**不**再解析任何 `<swiftbar.*>` /
  `<xbar.*>` 标签。
- **`parameters`** — manifest 声明的 string / number / boolean / select 参数，
  持久化到 `<plugin-folder>/vars.json`，以 `MENUBAR01_PARAM_<NAME>` 环境变量
  注入脚本。
- **终端启动**：菜单点击可在 Terminal.app / iTerm2 / Ghostty / Kitty 中执行脚本
  （详见 `AppShared`）。
- **系统通知**：脚本可通过 `notify=` / `alert=` 触发 `UNUserNotificationCenter`
  通知。
- **Siri/Shortcuts 集成**：提供 `GetPluginsIntent`、`EnablePluginIntent`、
  `DisablePluginIntent`、`ReloadPluginIntent`、`SetEphemeralPluginIntent` 五个
  Intent。
- **URL Scheme**：`menubar01://` 处理 `refreshplugin`、`enableplugin`、
  `addplugin`、`setephemeralplugin`、`notify`、`copysystemreport` 等。
  旧的 `swiftbar://` **不**被识别 — 见
  [`changes/2026-06-13-drop-legacy-compat.md`](changes/2026-06-13-drop-legacy-compat.md)。
- **插件仓库**："Get Plugins…" 窗口基于
  [`PluginRepository`](SwiftBar/UI/Plugin%20Repository/PluginRepository.swift)
  远程目录，提供浏览、搜索、安装、卸载。
- **休眠/唤醒响应**：系统休眠时停止所有插件，唤醒后重新调度，并刷新
  `OS_LAST_SLEEP_TIME` / `OS_LAST_WAKE_TIME` 环境变量。
- **诊断系统**：随时生成系统报告（`PluginManager.currentSystemReport(reason:)`），
  可复制到剪贴板或写入
  `~/Library/Application Support/menubar01/Diagnostics/latest-system-report.txt`。
- **两种发布渠道**：直接分发版（带 Sparkle 自动更新）和 Mac App Store 版
  （无 Sparkle、沙盒友好），通过 `MAC_APP_STORE` 编译开关切换。

### 架构分层
1. **App 层** — `main.swift`、`AppDelegate` + `+Menu` / `+Toolbar` / `+Intents`
   扩展，处理生命周期、URL 路由、Siri/Shortcuts。
2. **Plugin 层** — `Plugin` 协议 + 三种实现（`ShortcutPlugin` /
   `EphemeralPlugin` + `FolderPlugin` 作为 `Executable` 的发现管线装载器）。
   `PluginManager` 单例调度（`pluginInvokeQueue` + `menuUpdateQueue` 两个
   `OperationQueue`）。老的 `ExecutablePlugin` / `StreamablePlugin` /
   `PackagedPlugin` 在 `changes/2026-06-13-delete-orphan-plugins.md` 中删除。
3. **MenuBar 层** — `MenubarItem` + `MenuItemNode` + `MenuDiff` +
   `FoldableMenuItemView`，对 `NSStatusItem` 和 `NSMenu` 做增量更新
   （基于值等价的 `MenuItemNode: Equatable`）。

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

> `docs/00-README.md` 起的 14 份内部开发者文档是从 SwiftBar 上游同步过来的
> 副本，头部仍带 SwiftBar 字样。逐份重写是 follow-up（见
> [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) § 4）。

---

## Build Commands
- Open project: `open menubar01.xcodeproj`
- Build: Press "Play" in Xcode
- Test: Run unit tests through Xcode's Test Navigator
- Debug: Enable Plugin Debug Mode with `defaults write com.lingyi.menubar01 PluginDebugMode -bool YES`

## Code Style Guidelines
- **Imports**: Group by standard libraries first, then third-party libraries
- **Naming**: Use descriptive camelCase variables, PascalCase for types
- **Types**: Swift strong typing with proper optionals handling
- **Error Handling**: Use do/catch blocks, proper error propagation
- **File Organization**: Keep related functionality in dedicated files
- **UI**: Use SwiftUI for new UI components when possible
- **Comments**: Document public APIs and complex logic
- **Dependencies**: menubar01 uses HotKey, LaunchAtLogin, Preferences, Sparkle, SwifCron

## Terminal Support
menubar01 supports running scripts in these terminals:
- macOS Terminal.app
- iTerm2
- Ghostty
- Kitty

## Environment Variables
MENUBAR01_VERSION, MENUBAR01_BUILD, MENUBAR01_PLUGINS_PATH, MENUBAR01_PLUGIN_PATH,
MENUBAR01_PLUGIN_PACKAGE_PATH, MENUBAR01_PLUGIN_CACHE_PATH, MENUBAR01_PLUGIN_DATA_PATH,
MENUBAR01_PLUGIN_REFRESH_REASON, MENUBAR01_LAUNCH_TIME, MENUBAR01_PARAM_*,
OS_APPEARANCE, OS_VERSION_MAJOR, OS_VERSION_MINOR, OS_VERSION_PATCH,
OS_LAST_SLEEP_TIME, OS_LAST_WAKE_TIME

> 旧的 `SWIFTBAR_*` 变量**不**再设置 — SwiftBar 插件直接读取会得到空值。

## 变更记录规则（changes/）

所有非平凡的改动（新功能、修复、重构、构建/发布流程变更、影响用户可见行为的文档更新）**必须**在 [`changes/`](changes/) 目录下新建一条记录。

- **目录规范**：[`changes/README.md`](changes/README.md) 包含文件命名、模板、生命周期和 AI 协作约定，是这条规则的权威来源。
- **文件命名**：`YYYY-MM-DD-<short-slug>.md`，例：`2026-06-12-fix-shell-quoting-bug.md`。
- **落盘时机**：与代码改动放在**同一个 commit**（或紧随其后的紧密 commit），并在 commit 后回填 commit SHA 和 `Status: done`。
- **不删除旧记录**；必要时归档到 `changes/archive/`。
- **纯 typo / 注释级修改可豁免**。
- AI 助手（Trae AI / Claude 等）在做任何非平凡改动时，**必须**先读 `changes/README.md` 再动手，并在 commit 前创建对应的 `changes/*.md` 文件。
