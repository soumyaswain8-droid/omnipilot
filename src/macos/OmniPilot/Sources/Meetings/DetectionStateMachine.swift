import Foundation

/// Pure, time-driven debounce logic for meeting start/end. No system deps — testable.
/// Feed it inputs plus a monotonically increasing `now` (seconds). `.tick` re-evaluates timers.
struct DetectionStateMachine {
    private let startHold: TimeInterval
    private let endDebounce: TimeInterval
    private let minMeeting: TimeInterval
    private let knownMeetingApps: Set<String>

    private var running = false
    private var micActive = false
    private var micActiveSince: TimeInterval?     // when mic last became active
    private var micReleasedSince: TimeInterval?   // when mic last became inactive (while running)
    private var startedAt: TimeInterval?

    init(startHold: TimeInterval, endDebounce: TimeInterval,
         minMeeting: TimeInterval, knownMeetingApps: Set<String>) {
        self.startHold = startHold
        self.endDebounce = endDebounce
        self.minMeeting = minMeeting
        self.knownMeetingApps = knownMeetingApps
    }

    /// Returns an event if this input causes a transition, else nil.
    mutating func update(_ input: DetectionInput, now: TimeInterval) -> MeetingEvent? {
        switch input {
        case .micActive(let active):
            micActive = active
            if active {
                if micActiveSince == nil { micActiveSince = now }
                micReleasedSince = nil
            } else {
                micActiveSince = nil
                if running { micReleasedSince = now }
            }
            return evaluate(now: now)

        case .appTerminated(let bundleID):
            if running && knownMeetingApps.contains(bundleID) { return end() }
            return nil

        case .appLaunched:
            return nil   // enrichment only; start is mic-driven

        case .manualStart:
            if !running { return start(.manual, now: now) }
            return nil

        case .manualStop:
            if running { return end() }
            return nil

        case .tick:
            return evaluate(now: now)
        }
    }

    private mutating func evaluate(now: TimeInterval) -> MeetingEvent? {
        if !running, micActive, let since = micActiveSince, now - since >= startHold {
            return start(.micActive, now: now)
        }
        if running, let since = micReleasedSince, now - since >= endDebounce {
            return end()
        }
        return nil
    }

    private mutating func start(_ source: MeetingSource, now: TimeInterval) -> MeetingEvent {
        running = true
        startedAt = now
        micReleasedSince = nil
        return .started(source)
    }

    private mutating func end() -> MeetingEvent {
        running = false
        micReleasedSince = nil
        startedAt = nil
        return .ended
    }
}
