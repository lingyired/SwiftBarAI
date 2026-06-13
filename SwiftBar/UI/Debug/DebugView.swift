import SwiftUI

struct DebugView: View {
    let plugin: Plugin
    let sharedEnv = Environment.shared
    @ObservedObject var debugInfo: PluginDebugInfo
    var debugText: String {
        String(debugInfo.events.sorted(by: { $0.key < $1.key }).map { "\n🕐 \($0.key) \($0.value.eventString)" }
            .joined(separator: "\n")
            .prefix(100_000))
    }

    var body: some View {
        VStack {
            HStack {
                Text(plugin.name)
                    .font(.headline)
                Text("(\(plugin.file))")
                    .font(.caption)
                Spacer()
                if #available(OSX 11.0, *) {
                    Button(action: {
                        AppShared.openPluginFolder(path: plugin.file)
                    }) {
                        Image(systemName: "folder")
                    }.padding()
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .foregroundColor(.black)
                ScrollView(showsIndicators: false) {
                    Text(debugText)
                        .foregroundColor(.white)
                }.padding()
                    .contextMenu(ContextMenu(menuItems: {
                        Button("Copy", action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.declareTypes([.string], owner: nil)
                            pasteboard.setString(debugText, forType: .string)
                        })
                        Button("Clear", action: {
                            debugInfo.clear()
                        })
                    }))
            }
            HStack {
                Spacer()
                Button("Refresh Plugin", action: {
                    plugin.refresh(reason: .DebugView)
                })

                Button("Print menubar01 ENV", action: {
                    let envs = plugin.env
                    let swiftbarEnv = sharedEnv.systemEnvStr.merging(envs) { current, _ in current }
                    let debugString = swiftbarEnv.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
                    debugInfo.addEvent(type: .Environment, value: "\n\(debugString)")
                })
                Button("Print Plugin Metadata", action: {
                    // `manifest.json` is the single source of truth for plugin
                    // metadata, so the most useful debug output is the raw
                    // file contents as the app sees it on disk.
                    let manifestURL = URL(fileURLWithPath: plugin.file)
                        .deletingLastPathComponent()
                        .appendingPathComponent(pluginManifestFileName)
                    let raw: String
                    if let data = try? Data(contentsOf: manifestURL),
                       let json = try? JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data),
                                                              options: [.prettyPrinted, .sortedKeys]),
                       let pretty = String(data: json, encoding: .utf8)
                    {
                        raw = pretty
                    } else {
                        raw = "(unable to read \(manifestURL.path))"
                    }
                    debugInfo.addEvent(type: .PluginMetadata, value: "\n\(raw)")
                })
            }
        }.padding()
            .frame(minWidth: 500, minHeight: 500)
    }
}
