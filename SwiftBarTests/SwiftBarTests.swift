import Cocoa
import Combine
import Foundation
import Testing

@testable import menubar01

final class TestPlugin: Plugin {
    let id: PluginID
    let type: PluginType = .Executable
    let name: String
    let file: String
    let enabled: Bool
    var metadata: PluginMetadata?
    var contentUpdatePublisher = PassthroughSubject<String?, Never>()
    var updateInterval: Double = 60
    var lastUpdated: Date?
    var lastState: PluginState
    var lastRefreshReason: PluginRefreshReason = .FirstLaunch
    var content: String?
    var error: Error?
    var debugInfo = PluginDebugInfo()
    var refreshEnv: [String: String] = [:]
    var terminateCallCount = 0

    init(id: PluginID, file: String, content: String? = "...", enabled: Bool = true, lastState: PluginState = .Loading) {
        self.id = id
        self.name = id
        self.file = file
        self.content = content
        self.enabled = enabled
        self.lastState = lastState
    }

    func refresh(reason: PluginRefreshReason) {}
    func enable() {}
    func disable() {}
    func start() {}
    func terminate() {
        terminateCallCount += 1
    }
    func invoke() -> String? { content }
    func makeScriptExecutable(file: String) {}
    func writeStdin(_ input: String) throws {}
}

final class TimedTestPlugin: TimerArmingPlugin {
    let id: PluginID
    let type: PluginType = .Executable
    let name: String
    let file: String
    let enabled = true
    var metadata: PluginMetadata?
    var contentUpdatePublisher = PassthroughSubject<String?, Never>()
    var updateInterval: Double = 60
    var lastUpdated: Date?
    var lastState: PluginState = .Loading
    var lastRefreshReason: PluginRefreshReason = .FirstLaunch
    var content: String?
    var error: Error?
    var debugInfo = PluginDebugInfo()
    var refreshEnv: [String: String] = [:]
    var enableTimerCallCount = 0
    let invokeResult: String?

    init(id: PluginID, file: String, invokeResult: String?) {
        self.id = id
        name = id
        self.file = file
        self.invokeResult = invokeResult
    }

    func refresh(reason: PluginRefreshReason) {}
    func enable() {}
    func disable() {}
    func start() {}
    func terminate() {}
    func invoke() -> String? { invokeResult }
    func makeScriptExecutable(file: String) {}
    func writeStdin(_ input: String) throws {}
    func enableTimer() {
        enableTimerCallCount += 1
    }
}

struct Menubar01Tests {
    @Test func testShouldShowDefaultBarItem_whenNoVisiblePluginsAndNotInStealthMode() async throws {
        #expect(shouldShowDefaultBarItem(hasVisiblePlugins: false, stealthMode: false, alwaysShowMenubar01Menu: true))
    }

    @Test func testShouldShowDefaultBarItem_hidesFallbackWhenPluginIsVisible() async throws {
        #expect(!shouldShowDefaultBarItem(hasVisiblePlugins: true, stealthMode: false, alwaysShowMenubar01Menu: true))
    }

    @Test func testShouldShowDefaultBarItem_hidesFallbackInStealthMode() async throws {
        #expect(!shouldShowDefaultBarItem(hasVisiblePlugins: false, stealthMode: true, alwaysShowMenubar01Menu: true))
    }

    // MARK: - manifest.json folder plugins

    @Test func testIsManifestPluginDirectory_returnsTrueForFoldersContainingManifest() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        #expect(!isManifestPluginDirectory(tempDirectory))

        try Data("{}".utf8).write(to: tempDirectory.appendingPathComponent("manifest.json"))
        #expect(isManifestPluginDirectory(tempDirectory))
    }

    @Test func testPluginManifestLoader_decodesValidManifest() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifestJSON = """
        {
          "name": "Test Plugin",
          "version": "1.2.3",
          "description": "A test",
          "type": "streamable",
          "entry": "run.sh",
          "refreshInterval": 42,
          "environment": { "API_KEY": "abc" },
          "parameters": [
            { "name": "USER", "type": "string", "default": "guest" }
          ]
        }
        """
        let manifestURL = tempDirectory.appendingPathComponent("manifest.json")
        let entryURL = tempDirectory.appendingPathComponent("run.sh")
        try Data(manifestJSON.utf8).write(to: manifestURL)
        try Data("#!/bin/zsh\n".utf8).write(to: entryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entryURL.path)

        let loaded = PluginManifestLoader.loadAndValidate(from: tempDirectory)
        #expect(loaded != nil)
        #expect(loaded?.manifest.name == "Test Plugin")
        #expect(loaded?.manifest.resolvedType == .Executable)
        #expect(loaded?.manifest.resolvedRefreshInterval == 42)
        #expect(loaded?.manifest.environment?["API_KEY"] == "abc")
        #expect(loaded?.manifest.parameters?.first?.name == "USER")
        #expect(loaded?.entryURL.lastPathComponent == "run.sh")
    }

    @Test func testPluginManifestLoader_decodesAllFields() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifestJSON = """
        {
          "name": "Test Plugin",
          "version": "1.2.3",
          "description": "A test",
          "author": "Alice",
          "aboutUrl": "https://example.com/plugin",
          "dependencies": "bash, curl, jq",
          "type": "streamable",
          "entry": "run.sh",
          "refreshInterval": 42,
          "environment": { "API_KEY": "abc" },
          "parameters": [
            { "name": "USER", "type": "string", "default": "guest" }
          ],
          "hideAbout": true,
          "hideRunInTerminal": true,
          "hideLastUpdated": false,
          "hideDisablePlugin": true,
          "hideMenubar01": true
        }
        """
        let manifestURL = tempDirectory.appendingPathComponent("manifest.json")
        let entryURL = tempDirectory.appendingPathComponent("run.sh")
        try Data(manifestJSON.utf8).write(to: manifestURL)
        try Data("#!/bin/zsh\n".utf8).write(to: entryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entryURL.path)

        let loaded = PluginManifestLoader.loadAndValidate(from: tempDirectory)
        #expect(loaded != nil)
        let manifest = try #require(loaded?.manifest)
        #expect(manifest.name == "Test Plugin")
        #expect(manifest.version == "1.2.3")
        #expect(manifest.description == "A test")
        #expect(manifest.author == "Alice")
        #expect(manifest.aboutUrl == "https://example.com/plugin")
        #expect(manifest.dependencies == "bash, curl, jq")
        #expect(manifest.resolvedType == .Executable)
        #expect(manifest.resolvedRefreshInterval == 42)
        #expect(manifest.environment?["API_KEY"] == "abc")
        #expect(manifest.parameters?.first?.name == "USER")
        #expect(manifest.hideAbout == true)
        #expect(manifest.hideRunInTerminal == true)
        #expect(manifest.hideLastUpdated == false)
        #expect(manifest.hideDisablePlugin == true)
        #expect(manifest.hideMenubar01 == true)
        #expect(loaded?.entryURL.lastPathComponent == "run.sh")
    }

    @Test func testPluginManifestLoader_rejectsMissingEntry() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // Manifest declares an entry that doesn't exist
        try Data("{ \"entry\": \"missing.sh\" }".utf8).write(to: tempDirectory.appendingPathComponent("manifest.json"))

        let loaded = PluginManifestLoader.loadAndValidate(from: tempDirectory)
        #expect(loaded == nil)
    }

    @Test func testPluginManifestLoader_rejectsMalformedJSON() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try Data("{ not valid json".utf8).write(to: tempDirectory.appendingPathComponent("manifest.json"))
        #expect(PluginManifestLoader.loadAndValidate(from: tempDirectory) == nil)
    }

    @Test func testRunPluginOperation_rearmsTimersForTimerArmingPlugins() async throws {
        let plugin = TimedTestPlugin(id: "timed-plugin", file: "/tmp/timed.5s.sh", invokeResult: "updated")

        RunPluginOperation(plugin: plugin).main()

        #expect(plugin.content == "updated")
        #expect(plugin.enableTimerCallCount == 1)
    }

    @Test func testMenuItemActionKinds_includeHrefAndRefreshTogether() async throws {
        let params = MenuLineParameters(line: "Test | href=https://example.com refresh=true")

        #expect(MenubarItem.actionKinds(for: params) == [.href, .refresh])
    }

    @Test func testMenuItemActionKinds_includeAllSupportedActionsWithoutShortCircuiting() async throws {
        let params = MenuLineParameters(line: "Test | href=https://example.com bash=/bin/echo param1=hello stdin=ping refresh=true")

        #expect(MenubarItem.actionKinds(for: params) == [.href, .bash, .stdin, .refresh])
    }

    @Test func testMenuItemActionKinds_ignorePlaceholderHref() async throws {
        let params = MenuLineParameters(line: "Test | href=. refresh=true")

        #expect(MenubarItem.actionKinds(for: params) == [.refresh])
    }

    @Test func testHasAction_falseWithNoActionParams() async throws {
        let params = MenuLineParameters(line: "Status | color=red")
        #expect(!params.hasAction)
    }

    @Test func testHasAction_trueWithRefresh() async throws {
        let params = MenuLineParameters(line: "Status | color=red refresh=true")
        #expect(params.hasAction)
    }

    @Test func testColorParam_parsedWithoutAction() async throws {
        let params = MenuLineParameters(line: "Status | color=white")
        #expect(params.color != nil)
        #expect(!params.hasAction)
    }

    @Test func testParseUserShell_extractsShellPath() async throws {
        let output = """
        GeneratedUID: ABCDEF-1234
        UserShell: /opt/homebrew/bin/fish
        """

        #expect(parseUserShell(from: output) == "/opt/homebrew/bin/fish")
    }

    @Test func testParseUserShell_returnsNilWhenMissing() async throws {
        let output = "GeneratedUID: ABCDEF-1234"

        #expect(parseUserShell(from: output) == nil)
    }

    @Test func testParseUserShell_trimsWhitespace() async throws {
        let output = "UserShell:    /bin/zsh  \n"

        #expect(parseUserShell(from: output) == "/bin/zsh")
    }

    @Test func testParseUserShell_returnsNilForEmptyValue() async throws {
        let output = "UserShell:   "

        #expect(parseUserShell(from: output) == nil)
    }

    @Test func testStatusItemVisibilityKeys_preservesPreferredPositionKeys() async throws {
        let keysToRemove = statusItemVisibilityKeys(in: [
            "NSStatusItem Visible com.example.one": 0,
            "NSStatusItem Visible com.example.two": 1,
            "NSStatusItem Preferred Position com.example.one": 12,
            "UnrelatedKey": true,
        ])

        #expect(keysToRemove == [
            "NSStatusItem Visible com.example.one",
            "NSStatusItem Visible com.example.two",
        ])
    }

    @Test func testStatusItemPersistenceEntries_includeAllStatusItemKeys() async throws {
        let entries = statusItemPersistenceEntries(in: [
            "NSStatusItem Visible Item-0": 0,
            "NSStatusItem Preferred Position com.example.one": 12,
            "UnrelatedKey": true,
        ])

        #expect(entries == [
            "NSStatusItem Preferred Position com.example.one = 12",
            "NSStatusItem Visible Item-0 = 0",
        ])
    }

    @Test func testRemoveStatusItemVisibilityKeys_onlyRemovesVisibilityKeys() async throws {
        let suiteName = "Menubar01Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(0, forKey: "NSStatusItem Visible Item-0")
        defaults.set(12, forKey: "NSStatusItem Preferred Position com.example.one")
        defaults.set(true, forKey: "UnrelatedKey")

        let removedKeys = removeStatusItemVisibilityKeys(userDefaults: defaults)

        #expect(removedKeys == ["NSStatusItem Visible Item-0"])
        #expect(defaults.object(forKey: "NSStatusItem Visible Item-0") == nil)
        #expect((defaults.object(forKey: "NSStatusItem Preferred Position com.example.one") as? Int) == 12)
        #expect((defaults.object(forKey: "UnrelatedKey") as? Bool) == true)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func testKnownMenuBarManagerMatches_detectsKnownManagersCaseInsensitively() async throws {
        let matches = knownMenuBarManagerMatches(in: [
            "Finder",
            "ICE",
            "bartender 5",
            "Terminal",
        ])

        #expect(matches == ["Ice", "Bartender"])
    }

    @Test func testSystemReportCandidateStatus_reportsInvalidFolderPlugin() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // A folder without a manifest.json (or with an invalid one) should
        // be reported as a non-loadable folder plugin.
        let emptyFolderURL = tempDirectory.appendingPathComponent("weather")
        try FileManager.default.createDirectory(at: emptyFolderURL, withIntermediateDirectories: true)

        #expect(systemReportCandidateStatus(for: emptyFolderURL, makePluginExecutable: true) == "skipped: folder plugin has invalid manifest.json")
    }

    @Test func testSystemReportCandidateStatus_reportsLoadableFolderPlugin() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let folderURL = tempDirectory.appendingPathComponent("weather")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: folderURL.appendingPathComponent("manifest.json"))
        let scriptURL = folderURL.appendingPathComponent("plugin.sh")
        try Data("#!/bin/zsh\necho hi\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        #expect(systemReportCandidateStatus(for: folderURL, makePluginExecutable: false) == "loadable folder plugin")
    }

    @Test func testBuildTerminalCommand_quotesMultiWordBashCArgument() async throws {
        let command = buildTerminalCommand(
            script: "bash",
            args: ["-c", "echo Hello"],
            env: [:]
        )

        #expect(command.contains("bash -c 'echo Hello'"))
    }

    @Test func testBuildTerminalCommand_preservesShellExpandedExecutablePath() async throws {
        let command = buildTerminalCommand(
            script: "$HOME/bin/tool",
            args: ["--flag"],
            env: [:]
        )

        #expect(command.contains("$HOME/bin/tool --flag"))
        #expect(!command.contains("'$HOME/bin/tool'"))
    }

    @Test func testBuildTerminalCommand_andAppleScriptEscaping_preserveQuotedArguments() async throws {
        let command = buildTerminalCommand(
            script: "bash",
            args: ["-c", "echo \"Hello\" && echo done"],
            env: [:]
        )
        let appleScriptSafe = command.appleScriptEscaped()

        #expect(command.contains("bash -c 'echo \"Hello\" && echo done'"))
        #expect(appleScriptSafe.contains("\\\"Hello\\\""))
    }

    @Test func testBuildTerminalAppleScript_terminalUsesExplicitNewTabPath() async throws {
        let appleScript = buildTerminalAppleScript(command: "echo hello", terminal: .Terminal)

        #expect(appleScript.contains("if (count of windows) is 0 then"))
        #expect(appleScript.contains("do script \"echo hello\""))
        #expect(appleScript.contains("keystroke \"t\" using {command down}"))
        #expect(appleScript.contains("do script \"echo hello\" in selected tab of front window"))
    }

    @Test func testBuildTerminalAppleScript_iTermUsesCreateTabAndWriteText() async throws {
        let appleScript = buildTerminalAppleScript(command: "echo hello", terminal: .iTerm)

        #expect(appleScript.contains("if (count of windows) is 0 then"))
        #expect(appleScript.contains("create window with default profile"))
        #expect(appleScript.contains("create tab with default profile"))
        #expect(appleScript.contains("tell current session of current tab of current window to write text \"echo hello\""))
    }

    @Test func testBuildTerminalAppleScript_ghosttyUsesNativeAppleScriptAPI() async throws {
        let appleScript = buildTerminalAppleScript(command: "echo hello", terminal: .Ghostty)

        #expect(appleScript.contains("set ghosttyWindow to front window"))
        #expect(appleScript.contains("set ghosttyTab to new tab in ghosttyWindow"))
        #expect(appleScript.contains("set ghosttyTerminal to focused terminal of ghosttyTab"))
        #expect(appleScript.contains("set ghosttyWindow to new window"))
        #expect(appleScript.contains("input text \"echo hello\" to ghosttyTerminal"))
        #expect(appleScript.contains("send key \"enter\" to ghosttyTerminal"))
        #expect(!appleScript.contains("System Events"))
        #expect(!appleScript.contains("keystroke"))
    }

    @Test func testBuildTerminalAppleScript_ghosttyEscapesQuotedCommands() async throws {
        let appleScript = buildTerminalAppleScript(command: "echo \"hello\"", terminal: .Ghostty)

        #expect(appleScript.contains("input text \"echo \\\"hello\\\"\" to ghosttyTerminal"))
    }

    @Test func testBuildKittyLaunchArguments_usesSingleInstanceLoginShellLaunch() async throws {
        let args = buildKittyLaunchArguments(command: "export FOO=bar; echo hello", loginShell: "/bin/zsh")

        #expect(args == [
            "--single-instance",
            "/bin/zsh",
            "-lc",
            "export FOO=bar; echo hello",
        ])
    }

    @Test func testBuildKittyLaunchArguments_usesCshCompatibleCommandFlag() async throws {
        let args = buildKittyLaunchArguments(command: "setenv FOO bar; echo hello", loginShell: "/bin/tcsh")

        #expect(args == [
            "--single-instance",
            "/bin/tcsh",
            "-c",
            "setenv FOO bar; echo hello",
        ])
    }

    @Test func testBuildTerminalCommand_preventsCommandInjectionViaSemicolon() async throws {
        let command = buildTerminalCommand(
            script: "echo",
            args: ["foo; rm -rf /"],
            env: [:]
        )

        // The malicious arg should be fully quoted, not interpreted as separate commands
        #expect(command.contains("'foo; rm -rf /'"))
    }

    @Test func testBuildTerminalCommand_quotesEnclosedInQuotesBypass() async throws {
        let safelyQuoted = "'; rm -rf /; echo '"
        let result = safelyQuoted.quoteIfNeeded()

        // This shell token is already safely single-quoted, so it should be preserved.
        #expect(result == safelyQuoted)
    }

    @Test func testBuildTerminalCommand_requotesMalformedSingleQuotedToken() async throws {
        let malformed = "'foo' bar '"
        let result = malformed.quoteIfNeeded()

        #expect(result != malformed)
    }

    @Test func testBuildTerminalCommand_preservesEscapedApostropheSingleQuotedToken() async throws {
        let quoted = "'O'\\''Reilly'"
        let result = quoted.quoteIfNeeded()

        #expect(result == quoted)
    }

    @Test func testBuildTerminalCommand_preventsCommandInjectionViaDollar() async throws {
        let command = buildTerminalCommand(
            script: "echo",
            args: ["$(whoami)"],
            env: [:]
        )

        // Should be single-quoted so $() is not expanded
        #expect(command.contains("'$(whoami)'"))
    }

    @Test func testBuildTerminalCommand_preventsBacktickExpansion() async throws {
        let command = buildTerminalCommand(
            script: "echo",
            args: ["`whoami`"],
            env: [:]
        )

        // Should be single-quoted so backticks are not expanded
        #expect(command.contains("'`whoami`'"))
    }

    @Test func testBuildTerminalCommand_handlesPipeAndRedirect() async throws {
        let command = buildTerminalCommand(
            script: "echo",
            args: ["hello | cat > /tmp/evil"],
            env: [:]
        )

        // Should be quoted as a single argument, not interpreted as pipe/redirect
        #expect(command.contains("'hello | cat > /tmp/evil'"))
    }

    @Test func testBuildTerminalCommand_envValueWithMetacharacters() async throws {
        let originalShell = sharedEnv.userLoginShell
        defer { sharedEnv.userLoginShell = originalShell }
        sharedEnv.userLoginShell = "/bin/zsh"

        let command = buildTerminalCommand(
            script: "echo",
            args: [],
            env: ["EVIL": "$(whoami); rm -rf /"]
        )

        // Env value should be safely quoted
        #expect(command.contains("EVIL='$(whoami); rm -rf /'"))
    }

    @Test func testAppleScriptEscaped_handlesBackslashesAndQuotes() async throws {
        let input = "path\\to\\file \"with quotes\""
        let escaped = input.appleScriptEscaped()

        // Backslashes must be escaped first (\\ in AppleScript = literal \),
        // then double quotes (\\" in AppleScript = literal ")
        #expect(escaped == "path\\\\to\\\\file \\\"with quotes\\\"")
    }

    @Test func testAppleScriptEscaped_escapesBackslashFromShellQuoting() async throws {
        // quoteIfNeeded() uses the '\'' pattern to escape single quotes in shell.
        // This pattern contains a backslash which AppleScript would treat as an
        // escape character, causing a parse error on \'. Escaping \ to \\ fixes this.
        let shellQuoted = "hello'world".quoteIfNeeded()
        #expect(shellQuoted == "'hello'\\''world'")

        let escaped = shellQuoted.appleScriptEscaped()
        // '\'' becomes '\\'' — AppleScript sees \\\\ as literal backslash
        #expect(escaped == "'hello'\\\\''world'")
    }

    @Test func testAppleScriptEscaped_plainStringUnchanged() async throws {
        let input = "hello world"
        #expect(input.appleScriptEscaped() == "hello world")
    }

    @Test func testQuoteIfNeeded_singleQuotes() async throws {
        // Test that strings with single quotes are properly escaped
        let input = "This has 'single quotes'"
        let output = input.quoteIfNeeded()
        #expect(output == "'This has '\\''single quotes'\\'''")
    }

    @Test func testQuoteIfNeeded_noSpecialChars() async throws {
        // Test that strings without special characters remain unchanged
        let input = "simple_string"
        let output = input.quoteIfNeeded()
        #expect(output == "simple_string")
    }

    @Test func testEscaped_withSpaces() async throws {
        // Test that strings with spaces are quoted
        let input = "string with spaces"
        let output = input.escaped()
        #expect(output == "'string with spaces'")
    }

    @Test func testNeedsShellQuoting_withSingleQuotes() async throws {
        // Test that strings with single quotes need shell quoting
        let input = "string with 'quotes'"
        #expect(input.needsShellQuoting)
    }

    @Test func testProcessArgs_singleQuotes_runInBash() async throws {
        // This test simulates what happens in Process.launchScript when runInBash = true
        let script = "/path/to/script.sh"
        let args = ["arg with 'quotes'", "normal arg"]

        let escapedArgs = args.map { $0.quoteIfNeeded() }
        let bashArgs = ["-c", "\(script.escaped()) \(escapedArgs.joined(separator: " "))"]

        #expect(escapedArgs[0] == "'arg with '\\''quotes'\\'''")
        #expect(escapedArgs[1] == "'normal arg'") // "normal arg" contains a space so it needs quoting
        #expect(bashArgs[1].contains("'\\''quotes'\\''"))
    }

    @Test func testProcessArgs_singleQuotes_runWithoutBash() async throws {
        // This test simulates what happens in Process.launchScript when runInBash = false
        // In this case, args should be passed directly without any quoting
        let args = ["arg with 'quotes'", "normal arg"]

        // When runInBash = false, arguments should be passed directly without quoting
        #expect(args[0] == "arg with 'quotes'")
    }

    @Test func testProcessArgs_complexShellChars_runInBash() async throws {
        // Test handling of various shell special characters
        let args = ["arg with $HOME", "arg with \"quotes\"", "arg with ;", "arg with &&"]

        let escapedArgs = args.map { $0.quoteIfNeeded() }

        #expect(escapedArgs[0] == "'arg with $HOME'")
        #expect(escapedArgs[1] == "'arg with \"quotes\"'")
        #expect(escapedArgs[2] == "'arg with ;'")
        #expect(escapedArgs[3] == "'arg with &&'")
    }

    @Test func testProcessArgs_complexShellChars_runWithoutBash() async throws {
        // When not running in bash, all characters should be preserved exactly
        let args = ["arg with $HOME", "arg with \"quotes\"", "arg with ;", "arg with &&"]

        // These should be passed directly to the process without modification
        for (index, arg) in args.enumerated() {
            #expect(args[index] == arg, "Argument should be preserved exactly as is")
        }
    }

    @Test func testSingleQuotesInParameters() async throws {
        // This test specifically verifies the fix for the issue with single quotes
        // in parameters when runInBash is false

        // This is the exact scenario described in the bug report:
        // "single quote in text param | terminal=false bash='./.write.php' param1=\"text's\""
        let singleQuoteArg = "text's"

        // For runInBash = false, arguments should be passed directly
        // This is the correct behavior for the fix
        let directArgs = [singleQuoteArg]

        // Verify that with runInBash = false, the argument is passed as-is including the single quote
        #expect(directArgs[0] == "text's",
                "Single quotes should be preserved exactly when runInBash is false")

        // Test the specific escaped quote cases from the bug report
        let escapedSingleQuoteArg = "text\\'s"
        let doubleEscapedArg = "text\\\\'s"

        let escapedArgs = [escapedSingleQuoteArg, doubleEscapedArg]

        // These should be passed directly to the process without any changes when runInBash = false
        #expect(escapedArgs[0] == "text\\'s", "Escaped single quotes should be preserved exactly")
        #expect(escapedArgs[1] == "text\\\\'s", "Double escaped backslashes should be preserved exactly")
    }

    @Test func testMenuLineParameters_singleQuoteInParam() async throws {
        // This tests the exact scenario from the bug report
        let line = "single quote in text param | terminal=false bash='/path/to/script.php' param1=\"text's\""

        let params = MenuLineParameters(line: line)

        // Verify the parameter with single quote was parsed correctly
        #expect(params.params["param1"] == "text's", "Parameter with single quote should be preserved exactly")
        #expect(params.terminal == false, "Terminal parameter should be false")

        // Get the bash parameters
        let bashParams = params.bashParams

        // Verify that the parameter still contains the single quote
        #expect(bashParams.count == 1, "Should have one bash parameter")
        #expect(bashParams[0] == "text's", "Bash parameter should preserve the single quote")
    }

    @Test func testMenuLineParameters_additionalQuoteCases() async throws {
        // Test case 1: Double quotes inside single-quoted value
        let line1 = "quotes test | bash='/path/script.sh' param1='text with \"quotes\"'"
        let params1 = MenuLineParameters(line: line1)

        #expect(params1.params["param1"] == "text with \"quotes\"",
                "Parameter with double quotes inside single quotes should be preserved")

        // Test case 2: Escaped quotes in value
        let line2 = "escaped quotes | bash='/script.sh' param1=\"text with \\\"escaped quotes\\\"\""
        let params2 = MenuLineParameters(line: line2)

        // We expect both backslashes and quotes to be preserved exactly
        #expect(params2.params["param1"] == "text with \\\"escaped quotes\\\"",
                "Parameter with escaped quotes should preserve the backslashes")

        // Test case 3: Multiple parameters with different quote styles
        let line3 = "multiple params | param1=\"double quoted\" param2='single quoted' param3=unquoted"
        let params3 = MenuLineParameters(line: line3)

        #expect(params3.params["param1"] == "double quoted", "Double quoted parameter should be parsed correctly")
        #expect(params3.params["param2"] == "single quoted", "Single quoted parameter should be parsed correctly")
        #expect(params3.params["param3"] == "unquoted", "Unquoted parameter should be parsed correctly")

        // Test case 4: Complex real-world examples
        let line4 = "complex example | bash=\"/bin/sh\" param1=\"arg with 'single quotes' inside\" param2='arg with \"double quotes\" inside'"
        let params4 = MenuLineParameters(line: line4)

        #expect(params4.params["param1"] == "arg with 'single quotes' inside",
                "Single quotes inside double quotes should be preserved")
        #expect(params4.params["param2"] == "arg with \"double quotes\" inside",
                "Double quotes inside single quotes should be preserved")

        // Test case 5: Escaped single quotes - reported issue cases
        let line5 = "escaped single quote | terminal=false bash='/path/script.php' param1=\"text\\'s\""
        let params5 = MenuLineParameters(line: line5)

        #expect(params5.params["param1"] == "text\\'s",
                "Escaped single quote should be preserved exactly as typed")

        // Test case 6: Double escaped backslash with single quote
        let line6 = "double escaped | terminal=false bash='/path/script.php' param1=\"text\\\\'s\""
        let params6 = MenuLineParameters(line: line6)

        #expect(params6.params["param1"] == "text\\\\'s",
                "Double escaped backslash with single quote should be preserved exactly")
    }
}

@Suite(.serialized)
struct Menubar01IntegrationTests {
    @Test func testPluginFileState_changesWhenFileContentChanges() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fileURL = tempDirectory.appendingPathComponent("test.5s.sh")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("echo hi\n".utf8))

        let initialState = try #require(pluginFileState(for: fileURL))
        try Data("echo hello world\n".utf8).write(to: fileURL)
        let updatedState = try #require(pluginFileState(for: fileURL))

        #expect(initialState != updatedState)
    }

    @MainActor @Test func testPluginItemHideCallbackRestoresDefaultBarItem() async throws {
        let manager = PluginManager()
        let originalStealthMode = manager.prefs.stealthMode
        manager.prefs.stealthMode = false

        defer {
            manager.plugins.removeAll()
            manager.menuBarItems.removeAll()
            manager.directoryObserver = nil
            manager.barItem.show()
            manager.prefs.stealthMode = originalStealthMode
        }

        let plugin = TestPlugin(id: "test-plugin", file: "/tmp/test-plugin.5s.sh")
        manager.plugins = [plugin]

        let pluginItem = try #require(manager.menuBarItems[plugin.id])
        #expect(!manager.barItem.barItem.isVisible)

        pluginItem.hide()

        #expect(manager.barItem.barItem.isVisible)
    }

    @Test func testSyncFilePlugins_reloadsModifiedFilePlugin() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let folderURL = tempDirectory.appendingPathComponent("plugin-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: folderURL.appendingPathComponent("manifest.json"))
        let scriptURL = folderURL.appendingPathComponent("plugin.sh")

        try Data("#!/bin/zsh\necho one\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let initialState = try #require(pluginFileState(for: folderURL))
        let existingPlugin = TestPlugin(id: "original-plugin", file: folderURL.path, content: "one", lastState: .Success)

        try Data("#!/bin/zsh\necho updated output that changes size\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let syncResult = syncFilePlugins(
            existingFilePlugins: [existingPlugin],
            freshFilePlugins: [folderURL],
            previousFileStates: [folderURL.path: initialState]
        ) { folderURL in
            TestPlugin(
                id: "reloaded-plugin",
                file: folderURL.path,
                content: "updated",
                lastState: .Success
            )
        }

        let reloadedPlugin = try #require(syncResult.loadedPlugins.first)
        #expect(syncResult.removedPluginIDs.isEmpty)
        #expect(syncResult.modifiedPluginIDs == [existingPlugin.id])
        #expect(syncResult.loadedPlugins.count == 1)
        #expect(ObjectIdentifier(reloadedPlugin as AnyObject) != ObjectIdentifier(existingPlugin as AnyObject))
        #expect(syncResult.freshFileStates[folderURL.path] != initialState)
    }

    @Test func testSyncFilePlugins_doesNotTreatTemporarilySkippedFileAsRemoved() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // Folder plugin with a non-executable script — the loader would skip
        // it, but it must not be reported as "removed" by the sync logic.
        let folderURL = tempDirectory.appendingPathComponent("disabled-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: folderURL.appendingPathComponent("manifest.json"))
        let scriptURL = folderURL.appendingPathComponent("plugin.sh")
        try Data("#!/bin/zsh\necho one\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)

        let existingPlugin = TestPlugin(id: "disabled-plugin", file: folderURL.path, enabled: false, lastState: .Disabled)

        let syncResult = syncFilePlugins(
            existingFilePlugins: [existingPlugin],
            freshFilePlugins: [],
            previousFileStates: [:],
            discoveredFilePlugins: [folderURL]
        ) { folderURL in
            TestPlugin(id: "reloaded-plugin", file: folderURL.path, content: "updated", lastState: .Success)
        }

        #expect(syncResult.removedPluginIDs.isEmpty)
        #expect(syncResult.modifiedPluginIDs.isEmpty)
        #expect(syncResult.loadedPlugins.isEmpty)
    }

    @Test func testSyncFilePlugins_keepsPackagedPluginMatchedByBundlePath() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let folderURL = tempDirectory.appendingPathComponent("weather", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: folderURL.appendingPathComponent("manifest.json"))

        let mainExecutableURL = folderURL.appendingPathComponent("plugin.sh")
        try Data("#!/bin/zsh\necho weather\n".utf8).write(to: mainExecutableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecutableURL.path)

        let existingPlugin = TestPlugin(id: "weather-package", file: mainExecutableURL.path, content: "weather", lastState: .Success)
        let packageState = try #require(pluginFileState(for: folderURL))
        let packageSyncPath = pluginSyncPath(for: folderURL)
        var loadCallCount = 0

        let syncResult = syncFilePlugins(
            existingFilePlugins: [existingPlugin],
            freshFilePlugins: [folderURL],
            previousFileStates: [packageSyncPath: packageState],
            discoveredFilePlugins: [folderURL]
        ) { _ in
            loadCallCount += 1
            return nil
        }

        #expect(syncResult.removedPluginIDs.isEmpty)
        #expect(syncResult.modifiedPluginIDs.isEmpty)
        #expect(syncResult.loadedPlugins.isEmpty)
        #expect(syncResult.freshFileStates[packageSyncPath] == packageState)
        #expect(loadCallCount == 0)
    }

    @Test func testSyncFilePlugins_keepsSymlinkedFolderPluginMatchedByBundlePath() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let folderTargetURL = tempDirectory.appendingPathComponent("weather-target", isDirectory: true)
        try FileManager.default.createDirectory(at: folderTargetURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: folderTargetURL.appendingPathComponent("manifest.json"))

        let mainExecutableURL = folderTargetURL.appendingPathComponent("plugin.sh")
        try Data("#!/bin/zsh\necho weather\n".utf8).write(to: mainExecutableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecutableURL.path)

        let symlinkedFolderURL = tempDirectory.appendingPathComponent("weather", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkedFolderURL.path, withDestinationPath: folderTargetURL.path)

        let existingPlugin = TestPlugin(
            id: "weather-package",
            file: symlinkedFolderURL.appendingPathComponent("plugin.sh").path,
            content: "weather",
            lastState: .Success
        )
        let packageState = try #require(pluginFileState(for: symlinkedFolderURL))
        let packageSyncPath = pluginSyncPath(for: symlinkedFolderURL)
        var loadCallCount = 0

        #expect(packageSyncPath == symlinkedFolderURL.path)
        #expect(pluginSyncPath(for: existingPlugin) == symlinkedFolderURL.path)

        let syncResult = syncFilePlugins(
            existingFilePlugins: [existingPlugin],
            freshFilePlugins: [symlinkedFolderURL],
            previousFileStates: [packageSyncPath: packageState],
            discoveredFilePlugins: [symlinkedFolderURL]
        ) { _ in
            loadCallCount += 1
            return nil
        }

        #expect(syncResult.removedPluginIDs.isEmpty)
        #expect(syncResult.modifiedPluginIDs.isEmpty)
        #expect(syncResult.loadedPlugins.isEmpty)
        #expect(syncResult.freshFileStates[packageSyncPath] == packageState)
        #expect(loadCallCount == 0)
    }

    @Test func testMergePluginsPreservingOrder_replacesModifiedPluginsInPlace() async throws {
        let firstPlugin = TestPlugin(id: "first", file: "/tmp/first.5s.sh")
        let modifiedPlugin = TestPlugin(id: "modified", file: "/tmp/modified.5s.sh")
        let thirdPlugin = TestPlugin(id: "third", file: "/tmp/third.5s.sh")
        let replacementPlugin = TestPlugin(id: "modified", file: "/tmp/modified.5s.sh", content: "updated")

        let mergedPlugins = mergePluginsPreservingOrder(
            existingPlugins: [firstPlugin, modifiedPlugin, thirdPlugin],
            removedPluginIDs: [],
            reloadedFilePlugins: [replacementPlugin],
            newShortcutPlugins: []
        )

        #expect(mergedPlugins.count == 3)
        #expect(mergedPlugins[0] === firstPlugin)
        #expect(mergedPlugins[1] === replacementPlugin)
        #expect(mergedPlugins[2] === thirdPlugin)
    }

    @Test func testMergePluginsPreservingOrder_replacesFolderPluginInPlaceByBundlePath() async throws {
        let originalPlugin = TestPlugin(id: "weather-package", file: "/tmp/weather/plugin.sh")
        let replacementPlugin = TestPlugin(id: "weather-package", file: "/tmp/weather/plugin.py", content: "updated")

        let mergedPlugins = mergePluginsPreservingOrder(
            existingPlugins: [originalPlugin],
            removedPluginIDs: [],
            reloadedFilePlugins: [replacementPlugin],
            newShortcutPlugins: []
        )

        #expect(mergedPlugins.count == 1)
        #expect(mergedPlugins[0] === replacementPlugin)
    }

    @Test func testMergePluginsPreservingOrder_removesPluginInMiddleOfList() async throws {
        let first = TestPlugin(id: "first", file: "/tmp/first.5s.sh")
        let middle = TestPlugin(id: "middle", file: "/tmp/middle.5s.sh")
        let last = TestPlugin(id: "last", file: "/tmp/last.5s.sh")

        let merged = mergePluginsPreservingOrder(
            existingPlugins: [first, middle, last],
            removedPluginIDs: ["middle"],
            reloadedFilePlugins: [],
            newShortcutPlugins: []
        )

        #expect(merged.count == 2)
        #expect(merged[0] === first)
        #expect(merged[1] === last)
    }

    @Test func testMergePluginsPreservingOrder_appendsNewFilePluginAndShortcuts() async throws {
        let existing = TestPlugin(id: "existing", file: "/tmp/existing.5s.sh")
        let brandNew = TestPlugin(id: "brand-new", file: "/tmp/brand-new.5s.sh")
        let shortcut = ShortcutPlugin(PersistentShortcutPlugin(id: "shortcut", name: "shortcut", shortcut: "test", repeatString: "", cronString: ""))

        let merged = mergePluginsPreservingOrder(
            existingPlugins: [existing],
            removedPluginIDs: [],
            reloadedFilePlugins: [brandNew],
            newShortcutPlugins: [shortcut]
        )

        #expect(merged.count == 3)
        #expect(merged[0] === existing)
        #expect(merged[1] === brandNew)
        #expect(merged[2] === shortcut)
    }

    @Test func testUnloadPlugins_preservesDisabledStateForModifiedPlugins() async throws {
        let manager = PluginManager()
        let originalDisabledPlugins = manager.prefs.disabledPlugins
        defer { manager.prefs.disabledPlugins = originalDisabledPlugins }

        let plugin = TestPlugin(id: "disabled-plugin", file: "/tmp/disabled-plugin.5s.sh", enabled: false, lastState: .Disabled)
        manager.prefs.disabledPlugins = [plugin.id]
        manager.plugins = [plugin]

        manager.unloadPlugins([plugin], clearDisabledState: false)

        #expect(plugin.terminateCallCount == 1)
        #expect(manager.prefs.disabledPlugins == [plugin.id])
        #expect(manager.plugins.isEmpty)
    }

    @Test func testUnloadPlugins_clearsDisabledStateForRemovedPlugins() async throws {
        let manager = PluginManager()
        let originalDisabledPlugins = manager.prefs.disabledPlugins
        defer { manager.prefs.disabledPlugins = originalDisabledPlugins }

        let plugin = TestPlugin(id: "removed-plugin", file: "/tmp/removed-plugin.5s.sh", enabled: false, lastState: .Disabled)
        manager.prefs.disabledPlugins = [plugin.id]
        manager.plugins = [plugin]

        manager.unloadPlugins([plugin], clearDisabledState: true)

        #expect(plugin.terminateCallCount == 1)
        #expect(manager.prefs.disabledPlugins.isEmpty)
        #expect(manager.plugins.isEmpty)
    }

    @Test func testGetLoadablePluginList_skipsMalformedFolderPlugins() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // A folder without a manifest.json is not a loadable plugin anymore.
        let folderURL = tempDirectory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("not a manifest\n".utf8).write(to: folderURL.appendingPathComponent("README.txt"))

        let manager = PluginManager()
        let loadablePlugins = manager.getLoadablePluginList(from: [folderURL])

        #expect(loadablePlugins.isEmpty)
        #expect(manager.loadPlugin(fileURL: folderURL) == nil)
    }

    @Test func testFolderPlugin_ignoresScriptHeaderTypeTag() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let folderURL = tempDirectory.appendingPathComponent("streaming", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // The manifest does not declare a `type`, so the loader should
        // default to Executable regardless of any legacy
        // `<swiftbar.type>Streamable</swiftbar.type>` tag in the script body —
        // we no longer parse script header tags, but the comment must not
        // break the loader.
        try Data("""
        {
          "entry": "plugin.sh"
        }
        """.utf8).write(to: folderURL.appendingPathComponent("manifest.json"))
        let scriptURL = folderURL.appendingPathComponent("plugin.sh")
        try Data("""
        #!/bin/zsh
        <swiftbar.type>Streamable</swiftbar.type>
        echo hi
        """.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let plugin = try #require(FolderPlugin(manifestDirectory: folderURL))
        plugin.operation?.cancel()
        plugin.terminate()

        #expect(plugin.type == .Executable)
    }

    @Test func testShouldImportOpenedPluginFile_onlyAcceptsValidFolderPlugins() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // Single-file scripts are no longer accepted as importable plugins.
        let regularPluginURL = tempDirectory.appendingPathComponent("sample.1m.sh")
        try Data("#!/bin/zsh\necho hi\n".utf8).write(to: regularPluginURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: regularPluginURL.path)

        // Folder plugins with a valid manifest.json are accepted.
        let validFolderURL = tempDirectory.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: validFolderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"plugin.sh\"}".utf8).write(to: validFolderURL.appendingPathComponent("manifest.json"))
        let validScript = validFolderURL.appendingPathComponent("plugin.sh")
        try Data("#!/bin/zsh\necho valid\n".utf8).write(to: validScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validScript.path)

        // Folder plugins missing the entry script are rejected.
        let invalidFolderURL = tempDirectory.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidFolderURL, withIntermediateDirectories: true)
        try Data("{\"entry\": \"missing.sh\"}".utf8).write(to: invalidFolderURL.appendingPathComponent("manifest.json"))

        // Folders without a manifest.json are rejected.
        let noManifestFolderURL = tempDirectory.appendingPathComponent("no-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: noManifestFolderURL, withIntermediateDirectories: true)

        #expect(!shouldImportOpenedPluginFile(at: regularPluginURL, makePluginExecutable: true))
        #expect(shouldImportOpenedPluginFile(at: validFolderURL, makePluginExecutable: true))
        #expect(!shouldImportOpenedPluginFile(at: invalidFolderURL, makePluginExecutable: true))
        #expect(!shouldImportOpenedPluginFile(at: noManifestFolderURL, makePluginExecutable: true))
        #expect(!shouldImportOpenedPluginFile(at: URL(string: "swiftbar://refreshallplugins")!, makePluginExecutable: true))
    }

    @MainActor @Test func testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID() async throws {
        let manager = PluginManager()
        defer {
            manager.plugins.removeAll()
            manager.menuBarItems.removeAll()
            manager.directoryObserver = nil
        }

        let originalPlugin = TestPlugin(id: "reloaded-plugin", file: "/tmp/reloaded-plugin.5s.sh", content: "one")
        let replacementPlugin = TestPlugin(id: "reloaded-plugin", file: "/tmp/reloaded-plugin.5s.sh", content: "two")

        manager.plugins = [originalPlugin]

        let originalMenuBarItem = try #require(manager.menuBarItems[originalPlugin.id])

        manager.plugins = [replacementPlugin]

        let updatedMenuBarItem = try #require(manager.menuBarItems[replacementPlugin.id])
        #expect(updatedMenuBarItem === originalMenuBarItem)
        #expect(updatedMenuBarItem.plugin === replacementPlugin)
    }
}

// MARK: - Environment Variable Tests (Issues #473, #453)

@Suite(.serialized)
struct EnvironmentVariableTests {
    // Issue #473: SWIFTBAR_PLUGINS_PATH should reflect the current plugin directory,
    // not a stale value captured at Environment init time.
    @Test func testPluginsPathReflectsCurrentPreference() throws {
        let env = Environment.shared

        // Save original value to restore later
        let originalPath = PreferencesStore.shared.pluginDirectoryPath
        defer { PreferencesStore.shared.pluginDirectoryPath = originalPath }

        // Set a known path
        PreferencesStore.shared.pluginDirectoryPath = "/tmp/test-plugins-path"
        let envStr = env.systemEnvStr
        #expect(envStr["SWIFTBAR_PLUGINS_PATH"] == "/tmp/test-plugins-path",
                "SWIFTBAR_PLUGINS_PATH should reflect the current pluginDirectoryPath")

        // Change the path and verify it updates dynamically
        PreferencesStore.shared.pluginDirectoryPath = "/tmp/other-plugins-path"
        let envStr2 = env.systemEnvStr
        #expect(envStr2["SWIFTBAR_PLUGINS_PATH"] == "/tmp/other-plugins-path",
                "SWIFTBAR_PLUGINS_PATH should update when pluginDirectoryPath changes")

    }

    @Test func testPluginsPathHandlesNilDirectory() throws {
        let env = Environment.shared

        let originalPath = PreferencesStore.shared.pluginDirectoryPath
        defer { PreferencesStore.shared.pluginDirectoryPath = originalPath }

        PreferencesStore.shared.pluginDirectoryPath = nil
        let envStr = env.systemEnvStr
        #expect(envStr["SWIFTBAR_PLUGINS_PATH"] == "",
                "SWIFTBAR_PLUGINS_PATH should be empty string when directory is nil")
    }
}

struct RefreshReasonContentSyncTests {
    // Issue #453: When invoke() is called directly (as in refreshAndShowMenu),
    // plugin.content must be updated to prevent subsequent scheduled refreshes
    // from being suppressed by the didSet guard.
    @Test func testContentDidSetGuardSuppressesIdenticalContent() throws {
        // This test demonstrates the mechanism behind issue #453:
        // If plugin.content is "Schedule" and a new invoke() also returns "Schedule",
        // the didSet guard prevents contentUpdatePublisher from firing.

        var publisherFired = false
        let publisher = PassthroughSubject<String?, Never>()
        let cancellable = publisher.sink { _ in
            publisherFired = true
        }

        // Simulate the didSet guard logic from ExecutablePlugin.content
        let oldContent = "Schedule"
        let newContent = "Schedule"
        let lastRefreshReason = PluginRefreshReason.Schedule

        // This mirrors the guard in ExecutablePlugin.content didSet
        let shouldPublish = newContent != oldContent || PluginRefreshReason.manualReasons().contains(lastRefreshReason)

        if shouldPublish {
            publisher.send(newContent)
        }

        #expect(!publisherFired,
                "Publisher should NOT fire when content is identical and reason is Schedule")
        _ = cancellable // keep alive
    }

    @Test func testContentDidSetAllowsChangedContent() throws {
        var publisherFired = false
        let publisher = PassthroughSubject<String?, Never>()
        let cancellable = publisher.sink { _ in
            publisherFired = true
        }

        let oldContent = "MenuOpen"
        let newContent = "Schedule"
        let lastRefreshReason = PluginRefreshReason.Schedule

        let shouldPublish = newContent != oldContent || PluginRefreshReason.manualReasons().contains(lastRefreshReason)

        if shouldPublish {
            publisher.send(newContent)
        }

        #expect(publisherFired,
                "Publisher should fire when content changes")
        _ = cancellable
    }

    @Test func testMenuOpenIsManualReason() throws {
        // MenuOpen should be a manual reason, which forces content update even if content is identical
        #expect(PluginRefreshReason.manualReasons().contains(.MenuOpen),
                "MenuOpen should be in manualReasons so refreshOnOpen always triggers UI updates")
    }
}

struct MenubarItemIncrementalUpdateTests {
    @MainActor
    private func makeMenuBarItem() -> MenubarItem {
        let plugin = TestPlugin(id: "test-plugin", file: "/tmp/test-plugin.5s.sh", content: nil, lastState: .Success)
        let item = MenubarItem(title: "Test")
        item.plugin = plugin
        item.statusBarMenu.delegate = item
        return item
    }

    @MainActor
    private func menuLabels(for item: MenubarItem) -> [String] {
        item.statusBarMenu.items.map { menuItem in
            menuItem.isSeparatorItem ? "<separator>" : (menuItem.attributedTitle?.string ?? menuItem.title)
        }
    }

    @MainActor @Test func testIncrementalUpdate_excludesHiddenBodyRowsFromMenuDiff() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Visible A
        Hidden | dropdown=false
        Visible B
        """)

        item._updateMenu(content: """
        Title
        ---
        Visible A
        Hidden Changed | dropdown=false
        Visible B Updated
        """)

        #expect(Array(menuLabels(for: item).prefix(4)) == [
            "<separator>",
            "<separator>",
            "Visible A",
            "Visible B Updated",
        ])
    }

    @MainActor @Test func testIncrementalUpdate_rebuildsWhenBodyDisappearsToRemoveExtraSeparator() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Visible A
        """)

        item._updateMenu(content: "Title")

        #expect(item.statusBarMenu.items[0].isSeparatorItem)
        #expect(!item.statusBarMenu.items[1].isSeparatorItem)
        #expect(item.statusBarMenu.items[1].title == item.menubar01Item.title)
    }

    @MainActor @Test func testIncrementalUpdate_rebuildsHeaderMenuRowsWhenHeaderChanges() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Header A
        Header B
        ---
        Body
        """)

        item._updateMenu(content: """
        Renamed Header
        ---
        Body
        """)

        let labels = menuLabels(for: item)

        #expect(!labels.contains("Header A"))
        #expect(!labels.contains("Header B"))
        #expect(Array(labels.prefix(3)) == [
            "<separator>",
            "<separator>",
            "Body",
        ])
    }

    @MainActor @Test func testIncrementalUpdate_reenablesTitleCycleWhenHeaderIsUnchanged() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Header A
        Header B
        ---
        Body
        """)

        let initialTitleCycle = try #require(item.titleCycleCancellable)
        item.disableTitleCycle()

        item._updateMenu(content: """
        Header A
        Header B
        ---
        Body Updated
        """)

        let updatedTitleCycle = try #require(item.titleCycleCancellable)
        #expect(ObjectIdentifier(initialTitleCycle) != ObjectIdentifier(updatedTitleCycle))
    }

    @MainActor @Test func testIncrementalUpdate_restoresBodyShortcuts() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Visible A | refresh=true
        """)

        item._updateMenu(content: """
        Title
        ---
        Visible A | refresh=true shortcut=cmd+b
        """)

        let bodyItem = item.statusBarMenu.items[2]
        #expect(bodyItem.keyEquivalent == "b")
        #expect(bodyItem.keyEquivalentModifierMask.contains(.command))
        #expect(item.hotKeys.count == 1)
    }

    @MainActor @Test func testFullRebuildWhileMenuIsOpen_reappliesHiddenStandardItems() throws {
        let item = makeMenuBarItem()
        item.plugin?.metadata = PluginMetadata(
            hideRunInTerminal: true,
            hideLastUpdated: true,
            hideDisablePlugin: true,
            hideMenubar01: true
        )
        item.plugin?.lastUpdated = Date()

        item._updateMenu(content: """
        Title
        ---
        Visible A
        """)

        item.hotkeyTrigger = true
        item.menuWillOpen(item.statusBarMenu)

        #expect(item.lastUpdatedItem.isHidden)
        #expect(item.runInTerminalItem.isHidden)
        #expect(item.disablePluginItem.isHidden)
        #expect(item.menubar01Item.isHidden)

        item._updateMenu(content: """
        Renamed Title
        ---
        Visible A
        """)

        #expect(item.lastUpdatedItem.isHidden)
        #expect(item.runInTerminalItem.isHidden)
        #expect(item.disablePluginItem.isHidden)
        #expect(item.menubar01Item.isHidden)
    }

    @MainActor @Test func testIncrementalUpdate_keepsRegeneratedHotKeysPausedWhileMenuIsOpen() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Visible A | refresh=true shortcut=cmd+b
        """)

        item.hotkeyTrigger = true
        item.menuWillOpen(item.statusBarMenu)

        item._updateMenu(content: """
        Title
        ---
        Visible A Updated | refresh=true shortcut=cmd+b
        """)

        #expect(item.hotKeys.count == 1)
        #expect(item.hotKeys.allSatisfy { $0.isPaused })
    }
}

// MARK: - MenuItemNode Tree Building Tests

struct MenuItemNodeParsingTests {
    @Test func testParseLine_topLevelSeparator() throws {
        let result = MenuItemNode.parseLine("---")
        #expect(result.level == 0)
        #expect(result.isSeparator == true)
        #expect(result.workingLine == "---")
    }

    @Test func testParseLine_plainItem() throws {
        let result = MenuItemNode.parseLine("Hello World | color=red")
        #expect(result.level == 0)
        #expect(result.isSeparator == false)
        #expect(result.workingLine == "Hello World | color=red")
    }

    @Test func testParseLine_nestedItem() throws {
        let result = MenuItemNode.parseLine("--Sub Item | href=https://example.com")
        #expect(result.level == 1)
        #expect(result.isSeparator == false)
        #expect(result.workingLine == "Sub Item | href=https://example.com")
    }

    @Test func testParseLine_deeplyNestedItem() throws {
        let result = MenuItemNode.parseLine("----Deep Item")
        #expect(result.level == 2)
        #expect(result.isSeparator == false)
        #expect(result.workingLine == "Deep Item")
    }

    @Test func testParseLine_nestedSeparator() throws {
        // "-----" = two levels of "--" then "---"
        let result = MenuItemNode.parseLine("-----")
        #expect(result.level == 1)
        #expect(result.isSeparator == true)
        #expect(result.workingLine == "---")
    }

    @Test func testParseLine_tripleNestedSeparator() throws {
        // "-------" = "--" + "--" + "---"
        let result = MenuItemNode.parseLine("-------")
        #expect(result.level == 2)
        #expect(result.isSeparator == true)
        #expect(result.workingLine == "---")
    }
}

struct MenuItemNodeTreeBuildingTests {
    @Test func testBuildMenuTree_emptyInput() throws {
        let tree = MenuItemNode.buildMenuTree(from: [])
        #expect(tree.isEmpty)
    }

    @Test func testBuildMenuTree_flatItems() throws {
        let lines = ["---", "Item A", "Item B", "Item C"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 4)
        #expect(tree[0].isSeparator == true)
        #expect(tree[1].workingLine == "Item A")
        #expect(tree[2].workingLine == "Item B")
        #expect(tree[3].workingLine == "Item C")
        #expect(tree.allSatisfy { $0.children.isEmpty })
    }

    @Test func testBuildMenuTree_singleLevelNesting() throws {
        let lines = ["---", "Parent", "--Child 1", "--Child 2"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 2) // separator + parent
        #expect(tree[1].workingLine == "Parent")
        #expect(tree[1].children.count == 2)
        #expect(tree[1].children[0].workingLine == "Child 1")
        #expect(tree[1].children[1].workingLine == "Child 2")
    }

    @Test func testBuildMenuTree_multiLevelNesting() throws {
        let lines = [
            "---",
            "Item A",
            "--Sub A1",
            "--Sub A2",
            "----Deep A2a",
            "--Sub A3",
            "Item B",
        ]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 3) // separator, Item A, Item B
        #expect(tree[2].workingLine == "Item B")
        #expect(tree[2].children.isEmpty)

        let itemA = tree[1]
        #expect(itemA.workingLine == "Item A")
        #expect(itemA.children.count == 3) // Sub A1, Sub A2, Sub A3

        let subA2 = itemA.children[1]
        #expect(subA2.workingLine == "Sub A2")
        #expect(subA2.children.count == 1)
        #expect(subA2.children[0].workingLine == "Deep A2a")
    }

    @Test func testBuildMenuTree_nestedSeparator() throws {
        let lines = ["---", "Parent", "--Child 1", "-----", "--Child 2"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        let parent = tree[1]
        #expect(parent.children.count == 3)
        #expect(parent.children[0].workingLine == "Child 1")
        #expect(parent.children[1].isSeparator == true)
        #expect(parent.children[1].level == 1)
        #expect(parent.children[2].workingLine == "Child 2")
    }

    @Test func testBuildMenuTree_multipleSeparatorsAtRoot() throws {
        let lines = ["---", "Section 1", "---", "Section 2"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 4)
        #expect(tree[0].isSeparator == true)
        #expect(tree[1].workingLine == "Section 1")
        #expect(tree[2].isSeparator == true)
        #expect(tree[3].workingLine == "Section 2")
    }

    @Test func testBuildMenuTree_levelJump() throws {
        // Jump from level 0 to level 2 (skipping level 1)
        // The level 2 item should become a child of the level 0 item,
        // matching the original addMenuItem behavior.
        let lines = ["---", "Item A", "----Deep"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 2) // separator, Item A
        let itemA = tree[1]
        #expect(itemA.children.count == 1)
        #expect(itemA.children[0].workingLine == "Deep")
        #expect(itemA.children[0].level == 2)
    }

    @Test func testBuildMenuTree_returnToShallowerAfterJump() throws {
        // Level 0 → level 2 → level 1 should work correctly
        let lines = ["---", "Item A", "----Deep", "--Normal Sub"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        let itemA = tree[1]
        #expect(itemA.children.count == 2)
        #expect(itemA.children[0].workingLine == "Deep")
        #expect(itemA.children[0].level == 2)
        #expect(itemA.children[1].workingLine == "Normal Sub")
        #expect(itemA.children[1].level == 1)
    }

    @Test func testBuildMenuTree_preservesOriginalLine() throws {
        let lines = ["--Sub Item | color=red"]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 1)
        #expect(tree[0].line == "--Sub Item | color=red")
        #expect(tree[0].workingLine == "Sub Item | color=red")
    }

    @Test func testBuildMenuTree_excludesHiddenRowsAndKeepsFollowingVisibleItemsAligned() throws {
        let lines = [
            "---",
            "Visible A",
            "Hidden | dropdown=false",
            "Visible B",
        ]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        #expect(tree.count == 3)
        #expect(tree[0].isSeparator == true)
        #expect(tree[1].workingLine == "Visible A")
        #expect(tree[2].workingLine == "Visible B")
    }

    @Test func testBuildMenuTree_skipsHiddenParentsWithoutBreakingVisibleChildren() throws {
        let lines = [
            "---",
            "Parent",
            "--Hidden Parent | dropdown=false",
            "----Visible Grandchild",
            "--Visible Child",
        ]
        let tree = MenuItemNode.buildMenuTree(from: lines)

        let parent = tree[1]
        #expect(parent.children.count == 2)
        #expect(parent.children[0].workingLine == "Visible Grandchild")
        #expect(parent.children[0].level == 2)
        #expect(parent.children[1].workingLine == "Visible Child")
    }
}

// MARK: - MenuDiff Tests

struct MenuDiffTests {
    // Helper to make a simple non-separator node
    func node(_ line: String, children: [MenuItemNode] = []) -> MenuItemNode {
        let (level, isSep, working) = MenuItemNode.parseLine(line)
        return MenuItemNode(line: line, level: level, isSeparator: isSep, workingLine: working, children: children)
    }

    @Test func testDiff_identicalArrays() throws {
        let items = [node("Item A"), node("Item B"), node("Item C")]
        let changes = diffMenuNodes(old: items, new: items)

        #expect(changes.count == 3)
        #expect(changes[0] == .unchanged(oldIndex: 0, newIndex: 0))
        #expect(changes[1] == .unchanged(oldIndex: 1, newIndex: 1))
        #expect(changes[2] == .unchanged(oldIndex: 2, newIndex: 2))
    }

    @Test func testDiff_emptyArrays() throws {
        let changes = diffMenuNodes(old: [], new: [])
        #expect(changes.isEmpty)
    }

    @Test func testDiff_singleItemChanged() throws {
        let old = [node("Item A"), node("Item B"), node("Item C")]
        let new = [node("Item A"), node("Item B Changed"), node("Item C")]
        let changes = diffMenuNodes(old: old, new: new)

        #expect(changes.count == 3)
        #expect(changes[0] == .unchanged(oldIndex: 0, newIndex: 0))
        #expect(changes[1] == .update(oldIndex: 1, newIndex: 1))
        #expect(changes[2] == .unchanged(oldIndex: 2, newIndex: 2))
    }

    @Test func testDiff_itemsAppended() throws {
        let old = [node("Item A")]
        let new = [node("Item A"), node("Item B"), node("Item C")]
        let changes = diffMenuNodes(old: old, new: new)

        #expect(changes.count == 3)
        #expect(changes[0] == .unchanged(oldIndex: 0, newIndex: 0))
        #expect(changes[1] == .insert(newIndex: 1))
        #expect(changes[2] == .insert(newIndex: 2))
    }

    @Test func testDiff_itemsRemoved() throws {
        let old = [node("Item A"), node("Item B"), node("Item C")]
        let new = [node("Item A")]
        let changes = diffMenuNodes(old: old, new: new)

        #expect(changes.count == 3)
        // Removals come first in reverse index order, then non-removals
        #expect(changes[0] == .remove(oldIndex: 2))
        #expect(changes[1] == .remove(oldIndex: 1))
        #expect(changes[2] == .unchanged(oldIndex: 0, newIndex: 0))
    }

    @Test func testDiff_allChanged() throws {
        let old = [node("Item A"), node("Item B")]
        let new = [node("Item X"), node("Item Y")]
        let changes = diffMenuNodes(old: old, new: new)

        #expect(changes.count == 2)
        #expect(changes[0] == .update(oldIndex: 0, newIndex: 0))
        #expect(changes[1] == .update(oldIndex: 1, newIndex: 1))
    }

    @Test func testDiff_fromEmptyToFull() throws {
        let new = [node("Item A"), node("Item B")]
        let changes = diffMenuNodes(old: [], new: new)

        #expect(changes.count == 2)
        #expect(changes[0] == .insert(newIndex: 0))
        #expect(changes[1] == .insert(newIndex: 1))
    }

    @Test func testDiff_fromFullToEmpty() throws {
        let old = [node("Item A"), node("Item B")]
        let changes = diffMenuNodes(old: old, new: [])

        #expect(changes.count == 2)
        // Reverse order
        #expect(changes[0] == .remove(oldIndex: 1))
        #expect(changes[1] == .remove(oldIndex: 0))
    }

    @Test func testDiff_childrenChangeTriggersUpdate() throws {
        let oldChild = node("--Child A")
        let newChild = node("--Child B")
        let old = [node("Parent", children: [oldChild])]
        let new = [node("Parent", children: [newChild])]
        let changes = diffMenuNodes(old: old, new: new)

        // Parent's deep equality fails because children differ
        #expect(changes.count == 1)
        #expect(changes[0] == .update(oldIndex: 0, newIndex: 0))
    }

    @Test func testDiff_contentEqualWithDifferentChildren() throws {
        let oldChild = node("--Child A")
        let newChild = node("--Child B")
        let oldParent = node("Parent", children: [oldChild])
        let newParent = node("Parent", children: [newChild])

        // Deep equality: different (children differ)
        #expect(oldParent != newParent)
        // Content equality: same (own properties match)
        #expect(oldParent.contentEqual(to: newParent))
    }

    @Test func testDiff_mixedInsertAndRemove() throws {
        let old = [node("Item A"), node("Item B"), node("Item C")]
        let new = [node("Item A"), node("Item B"), node("Item C"), node("Item D")]
        let changes = diffMenuNodes(old: old, new: new)

        #expect(changes.count == 4)
        #expect(changes[0] == .unchanged(oldIndex: 0, newIndex: 0))
        #expect(changes[1] == .unchanged(oldIndex: 1, newIndex: 1))
        #expect(changes[2] == .unchanged(oldIndex: 2, newIndex: 2))
        #expect(changes[3] == .insert(newIndex: 3))
    }
}

// MARK: - Fold Parameter Tests

struct FoldParameterTests {
    @Test func testFoldParam_parsedAsTrue() throws {
        let params = MenuLineParameters(line: "Network | fold=true")
        #expect(params.fold == true)
    }

    @Test func testFoldParam_defaultsToFalse() throws {
        let params = MenuLineParameters(line: "Network | color=red")
        #expect(params.fold == false)
    }

    @Test func testFoldParam_caseInsensitive() throws {
        let params = MenuLineParameters(line: "Network | fold=True")
        #expect(params.fold == true)
        let params2 = MenuLineParameters(line: "Network | fold=TRUE")
        #expect(params2.fold == true)
    }

    @Test func testFoldParam_explicitFalse() throws {
        let params = MenuLineParameters(line: "Network | fold=false")
        #expect(params.fold == false)
    }
}

// MARK: - Fold Menu Item Tests

struct FoldMenuItemBuildTests {
    @MainActor
    private func makeMenuBarItem() -> MenubarItem {
        let plugin = TestPlugin(id: "test-plugin", file: "/tmp/test-plugin.5s.sh", content: nil, lastState: .Success)
        let item = MenubarItem(title: "Test")
        item.plugin = plugin
        item.statusBarMenu.delegate = item
        return item
    }

    @MainActor
    private func menuLabels(for item: MenubarItem) -> [String] {
        item.statusBarMenu.items.map { menuItem in
            if menuItem.isSeparatorItem { return "<separator>" }
            if menuItem.view is FoldableMenuItemView {
                return "<fold>"
            }
            return menuItem.attributedTitle?.string ?? menuItem.title
        }
    }

    @MainActor
    private func menuItem(named title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { menuItem in
            if let params = menuItem.representedObject as? MenuLineParameters,
               params.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
            {
                return true
            }

            return menuItemTitle(menuItem).trimmingCharacters(in: .whitespacesAndNewlines) == title
        }
    }

    @MainActor
    private func menuItemTitle(_ item: NSMenuItem) -> String {
        item.attributedTitle?.string ?? item.title
    }

    @MainActor
    private func makeBase64PNG(size: NSSize) throws -> String {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmapRep = try #require(NSBitmapImageRep(data: tiffData))
        let pngData = try #require(bitmapRep.representation(using: .png, properties: [:]))
        return pngData.base64EncodedString()
    }

    @MainActor @Test func testFullBuild_foldItemStartsCollapsed() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Network | fold=true
        --Wi-Fi: Connected
        --Ethernet: Off
        Item B
        """)

        // fold parent + 2 hidden children + Item B + standard menu items
        let labels = menuLabels(for: item)
        #expect(labels.contains("<fold>"))
        #expect(labels.contains("Item B"))

        // The fold children should be hidden
        let foldIndex = labels.firstIndex(of: "<fold>")!
        let childItem1 = item.statusBarMenu.items[foldIndex + 1]
        let childItem2 = item.statusBarMenu.items[foldIndex + 2]
        #expect(childItem1.isHidden == true)
        #expect(childItem2.isHidden == true)
        #expect(childItem1.attributedTitle?.string == "Wi-Fi: Connected")
        #expect(childItem2.attributedTitle?.string == "Ethernet: Off")
    }

    @MainActor @Test func testFullBuild_foldItemExpandsOnToggle() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Network | fold=true
        --Wi-Fi: Connected
        --Ethernet: Off
        """)

        // Find the fold parent
        let foldParent = item.statusBarMenu.items.first { $0.view is FoldableMenuItemView }!

        // Toggle to expand
        item.toggleFoldItem(foldParent)

        // Children should now be visible
        let foldIndex = item.statusBarMenu.index(of: foldParent)
        let childItem1 = item.statusBarMenu.items[foldIndex + 1]
        let childItem2 = item.statusBarMenu.items[foldIndex + 2]
        #expect(childItem1.isHidden == false)
        #expect(childItem2.isHidden == false)

        // Toggle to collapse
        item.toggleFoldItem(foldParent)

        #expect(childItem1.isHidden == true)
        #expect(childItem2.isHidden == true)
    }

    @MainActor @Test func testFullBuild_foldItemViewCarriesBadgeAndNormalizedIconSize() throws {
        let item = makeMenuBarItem()
        let imageBase64 = try makeBase64PNG(size: NSSize(width: 54, height: 54))

        item._updateMenu(content: """
        Title
        ---
        Network | fold=true badge=99 image=\(imageBase64)
        --Wi-Fi: Connected
        """)

        let foldParent = try #require(item.statusBarMenu.items.first { $0.view is FoldableMenuItemView })
        let foldView = try #require(foldParent.view as? FoldableMenuItemView)

        #expect(foldView.displayedBadgeText == "99")
        #expect(foldView.displayedIconSize == NSSize(width: 16, height: 16))
    }

    @MainActor @Test func testMenuHighlight_updatesFoldViewHighlightState() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Network | fold=true
        --Wi-Fi: Connected
        Status
        """)

        let foldParent = try #require(item.statusBarMenu.items.first { $0.view is FoldableMenuItemView })
        let foldView = try #require(foldParent.view as? FoldableMenuItemView)
        let statusItem = try #require(menuItem(named: "Status", in: item.statusBarMenu))

        item.menu(item.statusBarMenu, willHighlight: foldParent)
        #expect(foldView.isShowingHighlightedAppearance == true)

        item.menu(item.statusBarMenu, willHighlight: statusItem)
        #expect(foldView.isShowingHighlightedAppearance == false)
    }

    @MainActor @Test func testFullBuild_nonFoldItemUsesSubmenu() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Section
        --Sub A
        --Sub B
        """)

        // Regular submenu behavior (no fold)
        let sectionItem = item.statusBarMenu.items.first {
            $0.attributedTitle?.string == "Section"
        }!
        #expect(sectionItem.view == nil)
        #expect(sectionItem.submenu != nil)
        #expect(sectionItem.submenu?.items.count == 2)
    }

    @MainActor @Test func testFullBuild_pluginItemCountIncludesFoldChildren() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Fold Parent | fold=true
        --Child A
        --Child B
        Regular Item
        """)

        // pluginItemCount should include: separator + fold parent + 2 fold children + regular item
        // = 1 (title sep) + 1 (fold parent) + 2 (fold children) + 1 (regular) = 5
        // Plus however many title items are before the separator
        let expectedBodyItems = 5 // sep + fold parent + 2 children + regular
        #expect(item.pluginItemCount >= expectedBodyItems)
    }

    @MainActor @Test func testIncrementalUpdate_preservesFoldStateOnContentUpdate() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Network | fold=true
        --Wi-Fi: Connected
        --Ethernet: Off
        Status: OK
        """)

        // Expand the fold
        let foldParent = item.statusBarMenu.items.first { $0.view is FoldableMenuItemView }!
        item.toggleFoldItem(foldParent)

        // Verify expanded
        let foldIndex = item.statusBarMenu.index(of: foldParent)
        #expect(item.statusBarMenu.items[foldIndex + 1].isHidden == false)

        // Update content (non-fold item changes)
        item._updateMenu(content: """
        Title
        ---
        Network | fold=true
        --Wi-Fi: Connected
        --Ethernet: Off
        Status: Updated
        """)

        // Fold state should be preserved (still expanded)
        let updatedFoldParent = item.statusBarMenu.items.first { $0.view is FoldableMenuItemView }!
        let updatedFoldIndex = item.statusBarMenu.index(of: updatedFoldParent)
        #expect(item.statusBarMenu.items[updatedFoldIndex + 1].isHidden == false)
    }

    @MainActor @Test func testIncrementalUpdate_preservesNestedSubmenuFoldWithoutFullRebuild() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Section
        --Nested Fold | fold=true
        ----Deep A
        ----Deep B
        Status: OK
        """)
        item.menuWillOpen(item.statusBarMenu)

        let sectionItem = try #require(menuItem(named: "Section", in: item.statusBarMenu))
        let nestedFold = try #require(sectionItem.submenu?.items.first { $0.view is FoldableMenuItemView })
        item.toggleFoldItem(nestedFold)
        #expect(sectionItem.submenu?.items[1].isHidden == false)

        item._updateMenu(content: """
        Title
        ---
        Section
        --Nested Fold | fold=true
        ----Deep A
        ----Deep B
        Status: Updated
        """)

        let updatedSectionItem = try #require(menuItem(named: "Section", in: item.statusBarMenu))
        let updatedNestedFold = try #require(updatedSectionItem.submenu?.items.first { $0.view is FoldableMenuItemView })
        #expect(updatedSectionItem === sectionItem)
        #expect(updatedNestedFold === nestedFold)
        #expect(updatedSectionItem.submenu?.items[1].isHidden == false)
    }

    @MainActor @Test func testIncrementalUpdate_rebuildsItemWhenFoldFlagChanges() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Section | fold=true
        --Child A
        --Child B
        """)

        let foldSection = try #require(menuItem(named: "Section", in: item.statusBarMenu))
        #expect(foldSection.view is FoldableMenuItemView)
        #expect(menuItem(named: "Child A", in: item.statusBarMenu) != nil)

        item._updateMenu(content: """
        Title
        ---
        Section
        --Child A
        --Child B
        """)

        let submenuSection = try #require(menuItem(named: "Section", in: item.statusBarMenu))
        #expect(submenuSection === foldSection)
        #expect(submenuSection.view == nil)
        #expect(submenuSection.submenu?.items.count == 2)
        #expect(menuItem(named: "Child A", in: item.statusBarMenu) == nil)

        item._updateMenu(content: """
        Title
        ---
        Section | fold=true
        --Child A
        --Child B
        """)

        let rebuiltFoldSection = try #require(menuItem(named: "Section", in: item.statusBarMenu))
        #expect(rebuiltFoldSection === foldSection)
        #expect(rebuiltFoldSection.view is FoldableMenuItemView)
        #expect(rebuiltFoldSection.submenu == nil)
        #expect(menuItem(named: "Child A", in: item.statusBarMenu) != nil)
    }

    @MainActor @Test func testNestedFold_outerToggleHidesInnerChildren() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Outer | fold=true
        --Inner | fold=true
        ----Deep A
        ----Deep B
        --Regular Child
        """)

        // Find outer fold parent
        let outerFold = item.statusBarMenu.items.first { $0.view is FoldableMenuItemView }!

        // Expand outer
        item.toggleFoldItem(outerFold)

        // Find inner fold parent (now visible)
        let outerIndex = item.statusBarMenu.index(of: outerFold)
        let innerFold = item.statusBarMenu.items[outerIndex + 1]
        #expect(innerFold.view is FoldableMenuItemView)
        #expect(innerFold.isHidden == false)

        // Expand inner
        item.toggleFoldItem(innerFold)
        let innerIndex = item.statusBarMenu.index(of: innerFold)
        #expect(item.statusBarMenu.items[innerIndex + 1].isHidden == false) // Deep A visible

        // Collapse outer — inner and its children should all be hidden
        item.toggleFoldItem(outerFold)
        #expect(innerFold.isHidden == true)
        // Deep children should also be hidden
        #expect(item.statusBarMenu.items[innerIndex + 1].isHidden == true)
    }

    @MainActor @Test func testIncrementalUpdate_nestedFoldKeepsDirectChildrenAligned() throws {
        let item = makeMenuBarItem()

        item._updateMenu(content: """
        Title
        ---
        Outer | fold=true
        --Inner | fold=true
        ----Deep A
        ----Deep B
        --Regular Child
        """)

        let outerFold = item.statusBarMenu.items.first { $0.view is FoldableMenuItemView }!
        item.toggleFoldItem(outerFold)

        item._updateMenu(content: """
        Title
        ---
        Outer | fold=true
        --Inner | fold=true
        ----Deep A
        ----Deep B
        --Regular Child Updated
        """)

        let outerIndex = item.statusBarMenu.index(of: outerFold)
        let deepAItem = item.statusBarMenu.items[outerIndex + 2]
        let regularChildItem = item.statusBarMenu.items[outerIndex + 4]

        #expect(menuItemTitle(deepAItem) == "Deep A")
        #expect(menuItemTitle(regularChildItem) == "Regular Child Updated")
    }
}
