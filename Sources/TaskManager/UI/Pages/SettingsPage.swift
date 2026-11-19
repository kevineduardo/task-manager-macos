import AppKit
import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            CommandBar(title: "Settings") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCard(symbol: "paintbrush", title: "App theme", detail: "Pick the colors Task Manager uses") {
                        Picker("", selection: $preferences.theme) {
                            ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    SettingsCard(symbol: "house", title: "Default start page", detail: "Page shown when Task Manager opens") {
                        Picker("", selection: $preferences.startPage) {
                            ForEach(Page.navigable) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    SettingsCard(symbol: "speedometer", title: "Real time update speed", detail: preferences.updateSpeed.detail) {
                        Picker("", selection: $preferences.updateSpeed) {
                            ForEach(UpdateSpeed.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    SectionTitle("Window management")
                    SettingsCard(symbol: "macwindow.on.rectangle", title: "Always on top", detail: "Keep Task Manager above other windows") {
                        Toggle("", isOn: $preferences.alwaysOnTop).toggleStyle(.switch).labelsHidden()
                    }
                    SettingsCard(symbol: "arrow.down.right.and.arrow.up.left", title: "Minimize on use",
                                 detail: "Minimize the window after Run new task or Open file location") {
                        Toggle("", isOn: $preferences.minimizeOnUse).toggleStyle(.switch).labelsHidden()
                    }
                    SettingsCard(symbol: "menubar.rectangle", title: "Show CPU usage in the menu bar",
                                 detail: "A live CPU graph in the menu bar; click it to open Task Manager") {
                        Toggle("", isOn: $preferences.showMenuBarExtra).toggleStyle(.switch).labelsHidden()
                    }

                    SectionTitle("Other options")
                    SettingsCard(symbol: "person.text.rectangle", title: "Show full account name", detail: "Users page shows real names next to account names") {
                        Toggle("", isOn: $preferences.showFullAccountName).toggleStyle(.switch).labelsHidden()
                    }
                    SettingsCard(symbol: "clock.arrow.circlepath", title: "Show history for all processes", detail: "App history includes background processes, not only apps") {
                        Toggle("", isOn: $preferences.historyForAllProcesses).toggleStyle(.switch).labelsHidden()
                    }
                    SettingsCard(symbol: "leaf", title: "Ask me before applying Efficiency mode", detail: "Show a confirmation the first time per process") {
                        Toggle("", isOn: $preferences.confirmEfficiencyMode).toggleStyle(.switch).labelsHidden()
                    }

                    SectionTitle("About")
                    SettingsCard(symbol: "info.circle", title: "Task Manager \(AppInfo.version)",
                                 detail: "\(MachineInfo.current.osVersion) · \(MachineInfo.current.isAppleSilicon ? "Apple silicon" : "Intel") · \(MachineInfo.current.modelIdentifier)") {
                        Button("Source code") {
                            if let url = URL(string: AppInfo.repositoryURL) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { KeyboardRouter.shared.handler = nil }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static let repositoryURL = "https://github.com/kevineduardo/task-manager-macos"
}

private struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 16)
            .padding(.bottom, 2)
    }
}

private struct SettingsCard<Control: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.tmSmall).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardBorder))
    }
}
