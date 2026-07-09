import SwiftUI
import AppKit
import ApplicationServices

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
    var vadProcess: Process?
    var meetings: MeetingsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start Silero VAD service
        startVADService()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "OmniPilot")
            button.action = #selector(statusBarClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Initialize pipeline
        let memory = MemoryStore()
        let ollama = OllamaClient()
        let audio = AudioCapture()
        let whisper = WhisperBridge()

        pipeline = Pipeline(audioCapture: audio, whisper: whisper, memory: memory, ollama: ollama)

        // Meetings feature (Pillar M / M1): detect → record → transcribe → summarize → publish.
        let mc = MeetingsController(assistant: self.pipeline, whisper: whisper, ollama: ollama)
        mc.startAutoDetect()
        self.meetings = mc

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
        popover.contentSize = NSSize(width: 440, height: 560)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: QueryView(
                memoryStore: memory,
                ollamaClient: ollama,
                pipeline: pipeline!
            )
        )
        self.popover = popover

        // Global hotkey (Cmd+Shift+O) needs Accessibility trust, or the global monitor
        // silently never fires. Prompt for it once so the shortcut actually works.
        requestAccessibilityIfNeeded()

        let hotkeyHandler: (NSEvent) -> Void = { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 31 {
                Task { @MainActor in self?.showPopover() }
            }
        }
        // Global monitor: fires when another app is frontmost (needs Accessibility).
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: hotkeyHandler)
        // Local monitor: fallback so the shortcut still works while OmniPilot is active,
        // even before Accessibility is granted.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            hotkeyHandler(event)
            return event
        }

        // Auto-start listening
        pipeline?.start()

        // Schedule end-of-day summary at 6 PM (reschedules itself for next day after firing)
        pipeline?.scheduleDailySummary(hour: 18)

        print("[OmniPilot] Ready. Left-click = popover, Right-click = menu, Cmd+Shift+O = query.")
        print("[OmniPilot] Say 'Hey Pilot, <your question>' to query hands-free.")
    }

    /// Prompt for Accessibility trust if not already granted. Without it, the global hotkey
    /// monitor is installed but never fires — the classic "Cmd+Shift+O does nothing" symptom.
    private func requestAccessibilityIfNeeded() {
        // Use the literal key string ("AXTrustedCheckOptionPrompt") rather than the SDK constant,
        // whose Swift type (CFString vs Unmanaged<CFString>) varies across SDK versions.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted {
            print("[OmniPilot] Accessibility not yet granted — global hotkey will work after you enable OmniPilot in System Settings > Privacy & Security > Accessibility.")
        }
    }

    @objc func statusBarClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var isListening = true

    private func showMenu() {
        let menu = NSMenu()

        // Toggle listening on/off
        let toggleItem = NSMenuItem(
            title: isListening ? "Turn Off Listening" : "Turn On Listening",
            action: #selector(toggleListening),
            keyEquivalent: "l"
        )
        toggleItem.image = NSImage(systemSymbolName: isListening ? "mic.slash" : "mic", accessibilityDescription: nil)
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Meetings (Pillar M / M1)
        let mStatus = NSMenuItem(title: meetings?.statusText ?? "Meetings: Idle", action: nil, keyEquivalent: "")
        mStatus.isEnabled = false
        menu.addItem(mStatus)
        let mToggle = NSMenuItem(title: "Start/Stop Meeting", action: #selector(meetingToggle), keyEquivalent: "m")
        mToggle.target = self
        mToggle.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(mToggle)
        let mOpen = NSMenuItem(title: "Open Meetings Folder", action: #selector(meetingOpen), keyEquivalent: "")
        mOpen.target = self
        mOpen.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(mOpen)

        menu.addItem(NSMenuItem.separator())

        let queryItem = NSMenuItem(title: "Open Query (Cmd+Shift+O)", action: #selector(openPopoverFromMenu), keyEquivalent: "o")
        queryItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(queryItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OmniPilot", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem?.menu = nil }
    }

    @objc func toggleListening() {
        isListening.toggle()
        if isListening {
            pipeline?.start()
            statusItem?.button?.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "OmniPilot — Listening")
        } else {
            pipeline?.stop()
            statusItem?.button?.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "OmniPilot — Off")
        }
    }

    @objc func meetingToggle() { meetings?.manualToggle() }
    @objc func meetingOpen() { meetings?.openArchive() }

    @objc func openPopoverFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.showPopover() }
    }

    @objc func quitApp() {
        vadProcess?.terminate()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - VAD Service Management

    private func startVADService() {
        let scriptPath = Bundle.main.bundlePath
            .replacingOccurrences(of: "/build/OmniPilot.app", with: "/src/services/vad_service.py")

        // Also check project directory directly
        let projectScript = NSHomeDirectory() + "/Documents/tinker/projects/omnipilot/src/services/vad_service.py"
        let finalPath = FileManager.default.fileExists(atPath: scriptPath) ? scriptPath : projectScript

        guard FileManager.default.fileExists(atPath: finalPath) else {
            print("[OmniPilot] VAD service script not found, using energy-based VAD")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", finalPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            vadProcess = process
            print("[OmniPilot] VAD service started (PID: \(process.processIdentifier))")
            // Give it a moment to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.pipeline?.vad.reconnectSilero()
            }
        } catch {
            print("[OmniPilot] Failed to start VAD service: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        vadProcess?.terminate()
    }
}
