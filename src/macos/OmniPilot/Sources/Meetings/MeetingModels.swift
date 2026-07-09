import Foundation

/// What triggered a meeting start.
enum MeetingSource: Equatable {
    case micActive
    case appLaunch(String)   // bundle id
    case manual
}

/// Lifecycle events emitted by the detector.
enum MeetingEvent: Equatable {
    case started(MeetingSource)
    case ended
}

/// Coordinator processing state.
enum MeetingState: Equatable {
    case idle
    case recording
    case finalizing   // transcribing tail + summarizing
    case publishing
}

/// One transcript line: seconds-from-start + text.
struct TranscriptEntry: Equatable {
    let startSeconds: Int
    let text: String
}

/// Inputs fed to the detection state machine.
enum DetectionInput: Equatable {
    case micActive(Bool)
    case appLaunched(String)
    case appTerminated(String)
    case manualStart
    case manualStop
    case tick            // time advanced; re-evaluate hold/debounce
}

/// Paths produced by publishing a meeting.
struct MeetingArtifacts: Equatable {
    let folder: URL
    let notesMD: URL
    let transcriptMD: URL
    let audioM4A: URL
    let notesPDF: URL?
}
