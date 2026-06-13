import SwiftUI

struct AdvancedPreferencesView: View {
    @EnvironmentObject var preferences: PreferencesStore

    /// Local copy of the result toast the "Wipe All Generator
    /// History" button can surface. `nil` hides the banner.
    @State private var wipeResult: WipeResult?

    /// Brief wrapper for the destructive-button confirmation flow.
    /// Lives as a `struct` (not a `Binding<Bool>`) so the same
    /// identifier can show "Wiped N entries." / "Wipe failed: …"
    /// for both success and failure.
    private struct WipeResult: Equatable, Identifiable {
        let id = UUID()
        let kind: Kind
        enum Kind: Equatable {
            case success(count: Int?)
            case failure(String)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneSection {
                SettingsPaneRow(title: Localizable.Preferences.Terminal.localized) {
                    EnumPicker(selected: $preferences.terminal, title: "")
                        .frame(width: 140)
                }

                SettingsPaneRow(title: Localizable.Preferences.Shell.localized) {
                    EnumPicker(selected: $preferences.shell, title: "")
                        .frame(width: 140)
                }
            }

            SettingsPaneSection {
                SettingsPaneRow(title: "") {
                    Toggle("", isOn: $preferences.menubar01IconIsHidden)
                        .labelsHidden()
                    Text(Localizable.Preferences.HideMenubar01Icon.localized)
                }

                SettingsPaneRow(title: "") {
                    Toggle("", isOn: $preferences.stealthMode)
                        .labelsHidden()
                    Text(Localizable.Preferences.StealthMode.localized)
                }
            }

            SettingsPaneSection {
                SettingsPaneRow(title: "AI Generator History") {
                    Button("Wipe All Generator History", role: .destructive) {
                        runWipeWithConfirmation()
                    }
                }
                if let result = wipeResult {
                    HStack(spacing: 6) {
                        switch result.kind {
                        case .success(let count):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(successMessage(count: count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        case .failure(let reason):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("Wipe failed: \(reason)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 500, alignment: .topLeading)
    }

    // MARK: - Wipe Flow

    /// Prompt the user for confirmation, then call
    /// `AIGeneratorHistoryStore.deleteAll()` and surface the
    /// outcome in a brief inline toast. The confirmation dialog
    /// is intentionally destructive-role so the user has to
    /// deliberately click the red button.
    private func runWipeWithConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Wipe all AI generator history?"
        alert.informativeText = "Removes every recorded AI plugin generator run from disk. Generated plugin folders are not touched. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Wipe")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            runWipe()
        }
    }

    /// Actually call the store. Counts the entries we removed by
    /// reading `listAll()` first so the success toast can show
    /// "Wiped 3 entries." instead of just "Wiped."
    private func runWipe() {
        let store = AIGeneratorHistoryStoreFactory.makeDefault()
        let previousCount: Int
        do {
            previousCount = try store.listAll().count
        } catch {
            wipeResult = WipeResult(kind: .failure(error.localizedDescription))
            return
        }
        do {
            try store.deleteAll()
            wipeResult = WipeResult(kind: .success(count: previousCount))
        } catch {
            wipeResult = WipeResult(kind: .failure(error.localizedDescription))
        }
    }

    private func successMessage(count: Int?) -> String {
        switch count {
        case .some(let n) where n > 0:
            return "Wiped \(n) entr\(n == 1 ? "y" : "ies")."
        case .some, .none:
            return "Wiped."
        }
    }
}
