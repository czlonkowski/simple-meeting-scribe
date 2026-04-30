import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

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
        }

        MenuBarExtra {
            MenuBarMenu(state: state)
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
