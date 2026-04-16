import SwiftUI
import AppKit

@main
struct OmniPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var pipeline: Pipeline?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "OmniPilot")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Initialize pipeline
        let memory = MemoryStore()
        let ollama = OllamaClient()
        let audio = AudioCapture()
        let whisper = WhisperBridge()

        pipeline = Pipeline(audioCapture: audio, whisper: whisper, memory: memory, ollama: ollama)

        // Update menu bar icon based on status
        pipeline?.onStatusUpdate = { [weak self] status in
            Task { @MainActor in
                let iconName: String
                if status.contains("Transcribing") {
                    iconName = "brain.head.profile.fill"
                } else if status.contains("Listening") {
                    iconName = "brain.head.profile"
                } else if status.contains("Stopped") {
                    iconName = "brain"
                } else {
                    iconName = "brain.head.profile"
                }
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: iconName,
                    accessibilityDescription: status
                )
            }
        }

        // Setup popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: QueryView(
                memoryStore: memory,
                ollamaClient: ollama,
                pipeline: pipeline!
            )
        )
        self.popover = popover

        // Setup menu
        setupMenu()

        // Register global hotkey (Cmd+Shift+O)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 31 {
                Task { @MainActor in
                    self?.togglePopover()
                }
            }
        }

        // Auto-start listening
        pipeline?.start()
        print("[OmniPilot] Ready. Cmd+Shift+O to query. Click icon for menu.")
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Query (Cmd+Shift+O)", action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Listening", action: #selector(startListening), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Listening", action: #selector(stopListening), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OmniPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func togglePopover() {
        statusItem?.menu = nil
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.setupMenu()
        }
    }

    @objc func startListening() {
        pipeline?.start()
    }

    @objc func stopListening() {
        pipeline?.stop()
    }
}
