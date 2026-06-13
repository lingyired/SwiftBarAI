import Preferences
import SwiftUI

struct PluginDetailsView: View {
    @ObservedObject var md: PluginMetadata
    let plugin: Plugin
    /// The capability gate that decides whether the user has
    /// granted each declared capability. Defaults to the shared
    /// `PluginManager.shared.pluginCapabilityGate`; tests can
    /// pass a gate backed by an isolated `UserDefaults` suite to
    /// assert the Permissions section's behavior without touching
    /// the real store. See
    /// `menubar01/Plugin/PluginCapabilityGate.swift` for the
    /// authoritative `grant` / `revoke` / `verify` surface.
    let pluginCapabilityGate: PluginCapabilityGate = PluginManager.shared.pluginCapabilityGate
    @State var isEditing: Bool = false
    @State var dependencies: String = ""
    @State var userVariableValues: [String: String] = [:]
    /// Bumped after every revoke so the section re-renders. The
    /// gate is a value type and `UserDefaults` writes are not
    /// observed automatically, so we need a manual trigger.
    @State private var capabilitiesRevision: Int = 0
    /// Capability the user has clicked "Revoke" on and is
    /// currently confirming in the alert. `nil` means no
    /// confirmation is in flight.
    @State private var pendingRevoke: PluginCapability?
    let screenProportion: CGFloat = 0.3
    let width: CGFloat = 400
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Preferences.Container(contentWidth: 500) {
                    Preferences.Section(label: {
                        HStack {
                            Text("About Plugin")
                            if #available(OSX 11.0, *) {
                                Button(action: {
                                    AppShared.openPluginFolder(path: plugin.file)
                                }) {
                                    Image(systemName: "folder")
                                }.padding(.trailing)
                            }
                            Spacer()
                        }
                    }, content: {})
                    Preferences.Section(label: {
                        PluginDetailsTextView(label: "Name",
                                              text: $md.name,
                                              width: width * screenProportion)
                    }, content: {})
                    Preferences.Section(label: {
                        PluginDetailsTextView(label: "Description",
                                              text: $md.desc,
                                              width: width * screenProportion)
                    }, content: {})
                    Preferences.Section(label: {
                        PluginDetailsTextView(label: "Dependencies",
                                              text: $dependencies,
                                              width: width * screenProportion)
                            .onAppear(perform: {
                                dependencies = md.dependencies.joined(separator: ",")
                            })
                    }, content: {})
                    Preferences.Section(label: {
                        HStack {
                            PluginDetailsTextView(label: "GitHub",
                                                  text: $md.github,
                                                  width: width * screenProportion)
                            PluginDetailsTextView(label: "Author",
                                                  text: $md.author,
                                                  width: width * 0.2)
                        }
                    }, content: {})
                    Preferences.Section(bottomDivider: true, label: {
                        HStack {
                            PluginDetailsTextView(label: "Version",
                                                  text: $md.version,
                                                  width: width * screenProportion)
                            PluginDetailsTextView(label: "Schedule",
                                                  text: $md.schedule,
                                                  width: width * 0.2)
                        }
                    }, content: {})
                    permissionsSection
                    Preferences.Section(label: {
                        HStack {
                            Text("Hide Menu Items:")
                            Spacer()
                        }
                    }, content: {})
                    Preferences.Section(label: {
                        HStack {
                            PluginDetailsToggleView(label: "About",
                                                    state: $md.hideAbout,
                                                    width: width * screenProportion)
                            PluginDetailsToggleView(label: "Run in Terminal",
                                                    state: $md.hideRunInTerminal,
                                                    width: width * screenProportion)
                            PluginDetailsToggleView(label: "Last Updated",
                                                    state: $md.hideLastUpdated,
                                                    width: width * screenProportion)
                        }
                    }, content: {})

                    Preferences.Section(bottomDivider: !md.variables.isEmpty, label: {
                        HStack {
                            PluginDetailsToggleView(label: "menubar01",
                                                    state: $md.hideMenubar01,
                                                    width: width * screenProportion)

                            PluginDetailsToggleView(label: "Disable Plugin",
                                                    state: $md.hideDisablePlugin,
                                                    width: width * screenProportion)
                        }
                    }, content: {})
                }

                // Plugin Variables Section
                if !md.variables.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plugin Variables")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        ForEach(md.variables) { variable in
                            PluginVariableEditorView(
                                variable: variable,
                                value: bindingForVariable(variable)
                            )
                            .padding(.horizontal)
                        }

                        Divider()
                            .padding(.top, 4)
                    }
                }

                // Buttons section
                HStack {
                    if #available(macOS 11.0, *) {
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://github.com/lingyi/menubar01#plugin-format")!)
                        }, label: {
                            Image(systemName: "questionmark.circle")
                        }).buttonStyle(LinkButtonStyle())
                    }
                    Spacer()
                    // `manifest.json` is the single source of truth for plugin
                    // metadata — there is nothing to "save" or "reset" in the
                    // plugin file. The folder icon at the top of this view
                    // already reveals the plugin folder so the user can edit
                    // `manifest.json` directly.
                }
                .padding()
            }
        }
        .onAppear {
            loadUserVariableValues()
        }
        .onChange(of: plugin.id) { _ in
            loadUserVariableValues()
        }
        .id(plugin.id)
        .alert(
            "Revoke \(pendingRevoke?.displayName ?? "") for \(pluginID)?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            )
        ) {
            Button("Revoke", role: .destructive) {
                if let capability = pendingRevoke {
                    pluginCapabilityGate.revoke(capability, for: pluginID)
                    capabilitiesRevision += 1
                }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevoke = nil
            }
        } message: {
            Text("Revoking this capability will cause the plugin to fail on the next refresh. You can re-grant it from the install prompt.")
        }
    }

    /// The pluginID the capability gate stores grants under. Matches
    /// the convention in `PluginCapabilityGate.verify(manifest:)` —
    /// `manifest.name ?? "<unnamed>"`. `Plugin.metadata?.name` is
    /// derived from the manifest by `FolderPlugin.buildMetadata`,
    /// so the metadata accessor is the closest public-equivalent
    /// surface. `plugin.name` (the `Plugin` protocol property) is
    /// the directory-name fallback used by `FolderPlugin.init`.
    private var pluginID: String {
        let name = plugin.metadata?.name ?? ""
        return name.isEmpty ? plugin.name : name
    }

    private func loadUserVariableValues() {
        userVariableValues = PluginVariableStorage.loadUserValues(pluginFile: plugin.file)
        // Fill in defaults for any missing values
        for variable in md.variables where userVariableValues[variable.name] == nil {
            userVariableValues[variable.name] = variable.defaultValue
        }
    }

    /// The "Permissions" `Preferences.Section` rendered inside
    /// the `Preferences.Container`. Lists every capability the
    /// plugin declares in its `manifest.json`
    /// (`plugin.resolvedCapabilities`), shows a Granted / Not
    /// granted badge for each (driven by
    /// `gate.isGranted(_:for:)`), and offers a per-row Revoke
    /// button for the granted rows. Reading
    /// `capabilitiesRevision` inside the body invalidates the
    /// gate lookups on the next render — the gate is a value
    /// type stored in `UserDefaults`, so SwiftUI cannot observe
    /// its underlying mutations on its own.
    private var permissionsSection: Preferences.Section {
        // Touch `capabilitiesRevision` once at the top of the
        // body so a revoke invalidates the gate lookups on the
        // next render. The gate is a value type stored in
        // `UserDefaults`, so SwiftUI cannot observe its
        // underlying mutations on its own.
        let _ = capabilitiesRevision
        let capabilities = declaredCapabilities
        return Preferences.Section(label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Permissions")
                        .font(.headline)
                    Spacer()
                }
                if capabilities.isEmpty {
                    Text("This plugin does not request any special capabilities.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(capabilities, id: \.self) { capability in
                            PluginCapabilityRowView(
                                capability: capability,
                                isGranted: pluginCapabilityGate.isGranted(
                                    capability, for: pluginID
                                ),
                                onRequestRevoke: { pendingRevoke = capability }
                            )
                        }
                    }
                }
            }
        }, content: {})
    }

    /// Capabilities declared by the plugin's `manifest.json`.
    /// Touching `capabilitiesRevision` here forces a fresh
    /// `plugin.resolvedCapabilities` lookup after every revoke.
    private var declaredCapabilities: [PluginCapability] {
        _ = capabilitiesRevision
        return plugin.resolvedCapabilities
    }

    private func bindingForVariable(_ variable: PluginVariable) -> Binding<String> {
        Binding(
            get: { userVariableValues[variable.name] ?? variable.defaultValue },
            set: { newValue in
                userVariableValues[variable.name] = newValue
                PluginVariableStorage.saveUserValues(userVariableValues, pluginFile: plugin.file)
                // Refresh the plugin to apply changes
                plugin.refresh(reason: .PluginSettings)
            }
        )
    }
}

struct PluginVariableEditorView: View {
    let variable: PluginVariable
    @Binding var value: String

    // Local state for text editing to avoid refreshing on every keystroke
    @State private var editingText: String = ""
    @State private var debounceWorkItem: DispatchWorkItem?

    /// Display label: use description if available, otherwise humanize the variable name
    private var displayLabel: String {
        if !variable.description.isEmpty {
            return variable.description
        }
        return Self.humanizeVariableName(variable.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayLabel)
                .font(.system(.body))
            Text(variable.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            controlView
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controlView: some View {
        switch variable.type {
        case .boolean:
            Toggle(isOn: Binding(
                get: { value.lowercased() == "true" },
                set: { value = $0 ? "true" : "false" }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
        case .select:
            Picker("", selection: $value) {
                ForEach(variable.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        case .string, .number:
            TextField(variable.defaultValue, text: $editingText)
                .textFieldStyle(.roundedBorder)
                .onAppear { editingText = value }
                .onChange(of: editingText) { newText in
                    scheduleCommit(newText: newText)
                }
                .onChange(of: value) { newValue in
                    // External value change - update local text if different
                    if editingText != newValue {
                        debounceWorkItem?.cancel()
                        editingText = newValue
                    }
                }
        }
    }

    private func scheduleCommit(newText: String) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            if editingText == newText && newText != value {
                value = newText
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Converts "VAR_REFRESH_INTERVAL" → "Refresh Interval"
    static func humanizeVariableName(_ name: String) -> String {
        var cleaned = name
        if cleaned.hasPrefix("VAR_") {
            cleaned = String(cleaned.dropFirst(4))
        }
        return cleaned
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

struct PluginDetailsTextView: View {
    @EnvironmentObject var preferences: PreferencesStore
    let label: String
    @Binding var text: String
    let width: CGFloat
    var body: some View {
        HStack {
            HStack {
                Spacer()
                Text("\(label):")
            }.frame(width: width)
            TextField("", text: $text)
                .disabled(!PreferencesStore.shared.pluginDeveloperMode)
            Spacer()
        }
    }
}

struct PluginDetailsToggleView: View {
    let label: String
    @Binding var state: Bool
    let width: CGFloat
    var body: some View {
        HStack {
            HStack {
                Spacer()
                Text("\(label):")
            }.frame(width: width)
            Toggle("", isOn: $state)
        }
    }
}

/// Single row in the Permissions section: capability name,
/// one-line description, Granted / Not granted badge, and an
/// inline Revoke button for granted rows. Extracted from
/// `PluginDetailsView` so the row is a reusable building block
/// — the existing marketplace install-prompt sheet uses a
/// similar row layout (`MarketplaceInstallPromptSheet`).
struct PluginCapabilityRowView: View {
    let capability: PluginCapability
    let isGranted: Bool
    let onRequestRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.displayName)
                    .font(.system(.body, design: .default).weight(.semibold))
                Text(capability.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(isGranted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundColor(isGranted ? .green : .red)
                if isGranted {
                    Button(action: onRequestRevoke) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Revoke this capability. The plugin will fail to load on its next refresh.")
                }
            }
        }
    }
}
