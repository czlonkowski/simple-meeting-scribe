import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState
    @State private var updates: UpdateController

    init() {
        let state = AppState()
        _state = State(initialValue: state)
        _updates = State(initialValue: UpdateController(appState: state))
    }

    var body: some Scene {
        WindowGroup("Meeting Transcriber", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: 960, minHeight: 620)
                .task { await state.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
                Button("Setup Assistant…") {
                    state.isSetupPresented = true
                }
                .disabled(state.recordingState.isBusy)
                Button("Import Audio or Video…") {
                    state.importPanelRequested.toggle()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(state.isMicMuted ? "Unmute Microphone" : "Mute Microphone") {
                    state.setMicMuted(!state.isMicMuted)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!state.recordingState.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .environment(updates)
        }

        MenuBarExtra {
            MenuBarMenu(state: state, updates: updates)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps the app alive for the menu-bar extra after the main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.stop()
    }
}
