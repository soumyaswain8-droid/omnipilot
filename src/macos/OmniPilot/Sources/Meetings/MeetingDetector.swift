import Foundation
import CoreAudio
import AppKit

struct MeetingConfig {
    var startHold: TimeInterval = 5
    var endDebounce: TimeInterval = 15
    var minMeeting: TimeInterval = 60
    var knownMeetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp"]
}

/// Bridges CoreAudio mic-in-use + NSWorkspace app launch/quit into DetectionStateMachine events.
@MainActor
final class MeetingDetector {
    var onEvent: ((MeetingEvent) -> Void)?
    private var machine: DetectionStateMachine
    private let config: MeetingConfig
    private var timer: Timer?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var startTime = Date()

    init(config: MeetingConfig = MeetingConfig()) {
        self.config = config
        self.machine = DetectionStateMachine(
            startHold: config.startHold, endDebounce: config.endDebounce,
            minMeeting: config.minMeeting, knownMeetingApps: config.knownMeetingApps)
    }

    private func now() -> TimeInterval { Date().timeIntervalSince(startTime) }
    private func emit(_ e: MeetingEvent?) { if let e = e { onEvent?(e) } }

    func start() {
        startTime = Date()
        deviceID = Self.defaultInputDevice()
        // Poll mic-in-use + drive time-based transitions once per second.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let active = Self.isDeviceRunningSomewhere(self.deviceID)
                self.emit(self.machine.update(.micActive(active), now: self.now()))
                self.emit(self.machine.update(.tick, now: self.now()))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(self.machine.update(.appLaunched(id), now: self.now()))
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(self.machine.update(.appTerminated(id), now: self.now()))
            }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; NSWorkspace.shared.notificationCenter.removeObserver(self) }
    func manualStart() { emit(machine.update(.manualStart, now: now())) }
    func manualStop() { emit(machine.update(.manualStop, now: now())) }

    // MARK: CoreAudio helpers
    static func defaultInputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func isDeviceRunningSomewhere(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return running != 0
    }
}
