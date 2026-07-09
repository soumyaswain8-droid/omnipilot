# OmniPilot Meetings M1 (Backbone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app meeting notetaker to the OmniPilot menu-bar app: detect a meeting → record mic audio → transcribe → map-reduce summary → publish notes/transcript/audio to a shared folder.

**Architecture:** New `Sources/Meetings/` module. Pure logic units (detection debounce, transcript building, chunking/summarize, archive layout, coordinator state) are unit-tested with XCTest; thin system adapters (CoreAudio mic-in-use, AVAudioEngine recorder via existing `AudioCapture`, `WhisperBridge`, `OllamaClient`, SwiftUI menu) wrap them and are integration/manually verified. A `MeetingCoordinator` sequences the lifecycle and pauses the always-on assistant `Pipeline` while a meeting is active.

**Tech Stack:** Swift 6, SwiftPM, XCTest, AVFoundation, CoreAudio, AppKit (NSWorkspace), SwiftUI. Reuses existing `AudioCapture`, `WhisperBridge` (whisper-server :18386), `OllamaClient`.

## Global Constraints

- Platform floor: macOS 14 (`.macOS(.v14)`), Swift tools 6.0 — copied from `Package.swift`.
- Module name is `OmniPilot`; tests use `@testable import OmniPilot`.
- Local-first: no network except localhost (whisper-server :18386, Ollama :11434). No cloud.
- Audio: **mic-only** for M1 (16 kHz mono `[Float]` from `AudioCapture`); m4a for archive. System tap is M2 — out of scope.
- Transcript is stored **raw** (ground truth); only the summarizer's copy gets mishear-normalization.
- End-of-meeting = meeting app **releases the mic** held ≥ `endDebounceSeconds` (default 15), OR known meeting app quits, OR manual Stop. **Mute must not stop it** (mute keeps the device running).
- Start = mic active held ≥ `startHoldSeconds` (default 5). Discard sessions shorter than `minMeetingSeconds` (default 60) — no publish.
- Reuse `Pipeline.isHallucination(_:)` for transcript filtering. Do not reimplement.
- While a meeting records, the assistant `Pipeline` is stopped; resumed on meeting end (single mic engine).
- Frequent commits: one per task minimum. DRY, YAGNI, TDD.

---

### Task 1: Test target + domain models

**Files:**
- Modify: `src/macos/OmniPilot/Package.swift`
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingModels.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/MeetingModelsTests.swift`

**Interfaces:**
- Produces: `MeetingSource`, `MeetingEvent`, `MeetingState`, `TranscriptEntry`, `MeetingArtifacts`, `DetectionInput`.

- [ ] **Step 1: Add a test target to Package.swift**

Edit the `targets:` array to add a test target after the executable target:

```swift
        .executableTarget(
            name: "OmniPilot",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MeetingsTests",
            dependencies: ["OmniPilot"],
            path: "Tests/MeetingsTests"
        ),
```

- [ ] **Step 2: Write the models**

Create `Sources/Meetings/MeetingModels.swift`:

```swift
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
```

- [ ] **Step 3: Write a compile/sanity test**

Create `Tests/MeetingsTests/MeetingModelsTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class MeetingModelsTests: XCTestCase {
    func testEventEquality() {
        XCTAssertEqual(MeetingEvent.started(.manual), .started(.manual))
        XCTAssertNotEqual(MeetingEvent.started(.manual), .started(.micActive))
        XCTAssertEqual(MeetingEvent.ended, .ended)
    }

    func testTranscriptEntry() {
        let e = TranscriptEntry(startSeconds: 90, text: "hello")
        XCTAssertEqual(e.startSeconds, 90)
        XCTAssertEqual(e.text, "hello")
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd src/macos/OmniPilot && swift test --filter MeetingModelsTests`
Expected: builds; 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/Meetings/MeetingModels.swift Tests/MeetingsTests/MeetingModelsTests.swift
git commit -m "feat(meetings): domain models + test target"
```

---

### Task 2: DetectionStateMachine (pure debounce logic)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/DetectionStateMachine.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/DetectionStateMachineTests.swift`

**Interfaces:**
- Consumes: `DetectionInput`, `MeetingEvent`, `MeetingSource` (Task 1).
- Produces: `struct DetectionStateMachine` with `init(startHold:endDebounce:minMeeting:knownMeetingApps:)` and `mutating func update(_ input: DetectionInput, now: TimeInterval) -> MeetingEvent?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingsTests/DetectionStateMachineTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class DetectionStateMachineTests: XCTestCase {
    func make() -> DetectionStateMachine {
        DetectionStateMachine(startHold: 5, endDebounce: 15, minMeeting: 60,
                              knownMeetingApps: ["us.zoom.xos"])
    }

    func testMicActiveHeldStartsMeeting() {
        var m = make()
        XCTAssertNil(m.update(.micActive(true), now: 0))
        XCTAssertNil(m.update(.tick, now: 4))              // not held long enough
        XCTAssertEqual(m.update(.tick, now: 5), .started(.micActive))  // 5s held
        XCTAssertNil(m.update(.tick, now: 6))              // no duplicate start
    }

    func testMuteDoesNotEnd() {
        var m = make()
        _ = m.update(.micActive(true), now: 0)
        _ = m.update(.tick, now: 5)                        // started
        // mic stays active (mute keeps device running) for a long time
        XCTAssertNil(m.update(.tick, now: 600))
    }

    func testMicReleasedEndsAfterDebounce() {
        var m = make()
        _ = m.update(.micActive(true), now: 0)
        _ = m.update(.tick, now: 5)                        // started
        XCTAssertNil(m.update(.micActive(false), now: 100))
        XCTAssertNil(m.update(.tick, now: 110))            // 10s < 15s debounce
        XCTAssertEqual(m.update(.tick, now: 115), .ended)  // 15s released
    }

    func testMicBlipDoesNotEnd() {
        var m = make()
        _ = m.update(.micActive(true), now: 0); _ = m.update(.tick, now: 5)
        _ = m.update(.micActive(false), now: 100)
        _ = m.update(.micActive(true), now: 105)           // came back before debounce
        XCTAssertNil(m.update(.tick, now: 200))            // still running, no end
    }

    func testKnownAppQuitEnds() {
        var m = make()
        _ = m.update(.micActive(true), now: 0); _ = m.update(.tick, now: 5)
        XCTAssertEqual(m.update(.appTerminated("us.zoom.xos"), now: 50), .ended)
    }

    func testManualStartStop() {
        var m = make()
        XCTAssertEqual(m.update(.manualStart, now: 0), .started(.manual))
        XCTAssertEqual(m.update(.manualStop, now: 3), .ended)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DetectionStateMachineTests`
Expected: FAIL — `cannot find 'DetectionStateMachine' in scope`.

- [ ] **Step 3: Implement the state machine**

Create `Sources/Meetings/DetectionStateMachine.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DetectionStateMachineTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/DetectionStateMachine.swift Tests/MeetingsTests/DetectionStateMachineTests.swift
git commit -m "feat(meetings): detection state machine (mic-release end, mute-safe)"
```

---

### Task 3: TranscriptBuilder (pure)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/TranscriptBuilder.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/TranscriptBuilderTests.swift`

**Interfaces:**
- Consumes: `TranscriptEntry` (Task 1), `Pipeline.isHallucination(_:)` (existing).
- Produces: `struct TranscriptBuilder { mutating func append(startSeconds:Int, rawText:String); func markdown(recordingName:String)->String; func plainText()->String; var isEmpty: Bool }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingsTests/TranscriptBuilderTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class TranscriptBuilderTests: XCTestCase {
    func testAppendAndMarkdown() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 0, rawText: "  Hello everyone  ")
        b.append(startSeconds: 90, rawText: "second window")
        let md = b.markdown(recordingName: "mtg.wav")
        XCTAssertTrue(md.contains("# Meeting Transcript"))
        XCTAssertTrue(md.contains("`mtg.wav`"))
        XCTAssertTrue(md.contains("**[00:00]** Hello everyone"))
        XCTAssertTrue(md.contains("**[01:30]** second window"))
    }

    func testEmptyAndWhitespaceSkipped() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 0, rawText: "   ")
        XCTAssertTrue(b.isEmpty)
    }

    func testPlainTextHasNoTimestamps() {
        var b = TranscriptBuilder()
        b.append(startSeconds: 65, rawText: "content here")
        XCTAssertEqual(b.plainText().trimmingCharacters(in: .whitespacesAndNewlines), "content here")
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter TranscriptBuilderTests`
Expected: FAIL — `cannot find 'TranscriptBuilder'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/TranscriptBuilder.swift`:

```swift
import Foundation

/// Accumulates transcript windows and renders raw ground-truth transcript.
struct TranscriptBuilder {
    private(set) var entries: [TranscriptEntry] = []
    var isEmpty: Bool { entries.isEmpty }

    /// Append a transcription window. Trims, drops empties and hallucinations.
    mutating func append(startSeconds: Int, rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Pipeline.isHallucination(text) else { return }
        entries.append(TranscriptEntry(startSeconds: startSeconds, text: text))
    }

    private func stamp(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

    func markdown(recordingName: String) -> String {
        var out = "# Meeting Transcript\n\n_Recording: `\(recordingName)`_\n\n"
        for e in entries { out += "**[\(stamp(e.startSeconds))]** \(e.text)\n\n" }
        return out
    }

    func plainText() -> String { entries.map { $0.text }.joined(separator: " ") }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TranscriptBuilderTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/TranscriptBuilder.swift Tests/MeetingsTests/TranscriptBuilderTests.swift
git commit -m "feat(meetings): transcript builder (raw ground truth)"
```

---

### Task 4: ArchiveLayout (pure)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/ArchiveLayout.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/ArchiveLayoutTests.swift`

**Interfaces:**
- Produces: `struct ArchiveLayout { init(root:URL); func folder(date:Date, title:String?)->URL; static func slug(_:String?)->String }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingsTests/ArchiveLayoutTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class ArchiveLayoutTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(ArchiveLayout.slug("Weekly Sync!! #3"), "Weekly-Sync-3")
        XCTAssertEqual(ArchiveLayout.slug(nil), "Meeting")
        XCTAssertEqual(ArchiveLayout.slug("   "), "Meeting")
    }

    func testFolderNaming() {
        let root = URL(fileURLWithPath: "/tmp/archive")
        let layout = ArchiveLayout(root: root)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 9; comps.hour = 14; comps.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let folder = layout.folder(date: date, title: "Weekly Sync")
        XCTAssertEqual(folder.lastPathComponent, "2026-07-09_14-05_Weekly-Sync")
        XCTAssertEqual(folder.deletingLastPathComponent().path, "/tmp/archive")
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter ArchiveLayoutTests`
Expected: FAIL — `cannot find 'ArchiveLayout'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/ArchiveLayout.swift`:

```swift
import Foundation

/// Computes the per-meeting folder path. Pure (no filesystem access).
struct ArchiveLayout {
    let root: URL
    init(root: URL) { self.root = root }

    static func slug(_ title: String?) -> String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Meeting" }
        let allowed = CharacterSet.alphanumerics
        let mapped = t.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "Meeting" : collapsed
    }

    func folder(date: Date, title: String?) -> URL {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        return root.appendingPathComponent("\(fmt.string(from: date))_\(Self.slug(title))")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ArchiveLayoutTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/ArchiveLayout.swift Tests/MeetingsTests/ArchiveLayoutTests.swift
git commit -m "feat(meetings): archive folder layout"
```

---

### Task 5: MeetingSummarizer (map-reduce, injected LLM)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingSummarizer.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Consumes: none new.
- Produces: `protocol LLMGenerating { func generate(prompt:String, system:String?) async throws -> String }`; `struct MeetingSummarizer { init(llm:LLMGenerating); static func chunks(_:String, size:Int)->[String]; static func normalizeMishears(_:String)->String; func summarize(transcript:String) async throws -> String }`. Also `extension OllamaClient: LLMGenerating {}`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingsTests/MeetingSummarizerTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class MeetingSummarizerTests: XCTestCase {
    struct FakeLLM: LLMGenerating {
        let map: String; let reduce: String
        func generate(prompt: String, system: String?) async throws -> String {
            prompt.contains("FINAL notes") ? reduce : map
        }
    }

    func testChunking() {
        let text = String(repeating: "a", count: 25_000)
        let chunks = MeetingSummarizer.chunks(text, size: 12_000)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined().count, 25_000)
    }

    func testNormalizeMishears() {
        let n = MeetingSummarizer.normalizeMishears("Open Nurbukkalem and Nurbukh alum today")
        XCTAssertFalse(n.contains("Nurbukkalem"))
        XCTAssertTrue(n.contains("NotebookLM"))
    }

    func testMapReduceProducesReducedOutput() async throws {
        let s = MeetingSummarizer(llm: FakeLLM(map: "- point", reduce: "# Notes\nTL;DR ok"))
        let out = try await s.summarize(transcript: String(repeating: "word ", count: 5000))
        XCTAssertTrue(out.contains("TL;DR ok"))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MeetingSummarizerTests`
Expected: FAIL — `cannot find 'MeetingSummarizer'` / `LLMGenerating`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/MeetingSummarizer.swift`:

```swift
import Foundation

/// Abstraction over the LLM so the summarizer is testable without Ollama.
protocol LLMGenerating {
    func generate(prompt: String, system: String?) async throws -> String
}

extension OllamaClient: LLMGenerating {}

/// Map-reduce summarizer: chunk transcript → per-chunk bullets → combined structured notes.
struct MeetingSummarizer {
    let llm: LLMGenerating
    init(llm: LLMGenerating) { self.llm = llm }

    static func chunks(_ text: String, size: Int = 12_000) -> [String] {
        guard size > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<end]))
            idx = end
        }
        return out
    }

    /// Deterministic fixes for known whisper mishears (summarizer copy only).
    static func normalizeMishears(_ text: String) -> String {
        var t = text
        for pat in ["Nurbukkalem", "Nurbukh alum", "Nurbukh alum free"] {
            t = t.replacingOccurrences(of: pat, with: "NotebookLM")
        }
        return t
    }

    func summarize(transcript: String) async throws -> String {
        let clean = Self.normalizeMishears(transcript)
        let parts = Self.chunks(clean)
        var summaries: [String] = []
        for (i, c) in parts.enumerated() {
            let p = """
            This is part \(i + 1) of \(parts.count) of a live meeting/workshop transcript \
            (auto-transcribed; fix obvious mishears). Extract concisely as bullets: tools/websites \
            demoed, what was shown/done, step-by-step instructions, and any URLs. Bullets only.

            TRANSCRIPT PART \(i + 1):
            \(c)
            """
            summaries.append("### Segment \(i + 1)\n" + (try await llm.generate(prompt: p, system: nil)))
        }
        let reducePrompt = """
        You are compiling the FINAL notes for a meeting from ordered segment summaries. Produce clean \
        Markdown with: `## TL;DR` (3-4 sentences); `## Key Points`; `## Tools / Resources` (name — what \
        — link if mentioned); `## Action Items` as `- [ ]`. Merge duplicates. Do not invent.

        SEGMENT SUMMARIES:
        \(summaries.joined(separator: "\n\n"))
        """
        return try await llm.generate(prompt: reducePrompt, system: nil)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MeetingSummarizerTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/MeetingSummarizer.swift Tests/MeetingsTests/MeetingSummarizerTests.swift
git commit -m "feat(meetings): map-reduce summarizer with injectable LLM"
```

---

### Task 6: ArchivePublisher (writes artifacts)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/ArchivePublisher.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/ArchivePublisherTests.swift`

**Interfaces:**
- Consumes: `ArchiveLayout` (Task 4), `MeetingArtifacts` (Task 1).
- Produces: `struct ArchivePublisher { init(layout:ArchiveLayout); func publish(date:Date, title:String?, notes:String, transcript:String, audio:URL?) throws -> MeetingArtifacts }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingsTests/ArchivePublisherTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class ArchivePublisherTests: XCTestCase {
    func testPublishWritesArtifacts() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omnipub-\(UUID().uuidString)")
        // a fake audio file to move
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let srcAudio = tmp.appendingPathComponent("in.m4a")
        try Data("AUDIO".utf8).write(to: srcAudio)

        let pub = ArchivePublisher(layout: ArchiveLayout(root: tmp.appendingPathComponent("archive")))
        let art = try pub.publish(date: Date(), title: "Sync",
                                  notes: "# Notes", transcript: "# Transcript", audio: srcAudio)

        XCTAssertTrue(FileManager.default.fileExists(atPath: art.notesMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.transcriptMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.audioM4A.path))
        XCTAssertEqual(try String(contentsOf: art.notesMD, encoding: .utf8), "# Notes")
        XCTAssertTrue(art.folder.lastPathComponent.hasSuffix("_Sync"))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter ArchivePublisherTests`
Expected: FAIL — `cannot find 'ArchivePublisher'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/ArchivePublisher.swift`:

```swift
import Foundation

/// Writes the meeting artifact set into a per-meeting folder under the archive root.
struct ArchivePublisher {
    let layout: ArchiveLayout
    init(layout: ArchiveLayout) { self.layout = layout }

    func publish(date: Date, title: String?, notes: String,
                 transcript: String, audio: URL?) throws -> MeetingArtifacts {
        let fm = FileManager.default
        let folder = layout.folder(date: date, title: title)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let notesMD = folder.appendingPathComponent("notes.md")
        let transcriptMD = folder.appendingPathComponent("transcript.md")
        let audioDst = folder.appendingPathComponent("audio.m4a")
        try notes.write(to: notesMD, atomically: true, encoding: .utf8)
        try transcript.write(to: transcriptMD, atomically: true, encoding: .utf8)
        if let audio = audio, fm.fileExists(atPath: audio.path) {
            if fm.fileExists(atPath: audioDst.path) { try fm.removeItem(at: audioDst) }
            try fm.moveItem(at: audio, to: audioDst)
        }
        let pdf = Self.tryRenderPDF(from: notesMD, in: folder)
        return MeetingArtifacts(folder: folder, notesMD: notesMD,
                                transcriptMD: transcriptMD, audioM4A: audioDst, notesPDF: pdf)
    }

    /// Best-effort PDF via `dp content render` if on PATH; never throws.
    private static func tryRenderPDF(from md: URL, in folder: URL) -> URL? {
        let dp = ["/usr/local/bin/dp", "/opt/homebrew/bin/dp"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let dp = dp else { return nil }
        let pdf = folder.appendingPathComponent("notes.pdf")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: dp)
        proc.arguments = ["content", "render", md.path, "-o", pdf.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        return FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ArchivePublisherTests`
Expected: 1 test PASS (PDF path is nil in CI — not asserted).

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/ArchivePublisher.swift Tests/MeetingsTests/ArchivePublisherTests.swift
git commit -m "feat(meetings): archive publisher (md/transcript/audio + best-effort pdf)"
```

---

### Task 7: MeetingRecorder (mic → m4a + window)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingRecorder.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/MeetingRecorderTests.swift`

**Interfaces:**
- Consumes: `AudioCapture` (existing, `onAudioChunk: (([Float]) -> Void)?`, `startCapture()`, `stopCapture()`).
- Produces: `final class MeetingRecorder { init(capture:AudioCapture, sampleRate:Int); func start(writingTo:URL) throws; func windowSince(_ offset:Int) -> (samples:[Float], newOffset:Int); func totalSamples:Int; func stop() -> URL?; func ingest(_ samples:[Float]) }`.

Note: `ingest(_:)` is the seam we unit-test (bypasses the mic); in production `AudioCapture.onAudioChunk` calls `ingest`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingsTests/MeetingRecorderTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class MeetingRecorderTests: XCTestCase {
    func testWindowingTracksOffset() {
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        rec.ingest([Float](repeating: 0.1, count: 16_000))   // 1s
        rec.ingest([Float](repeating: 0.2, count: 16_000))   // 1s
        XCTAssertEqual(rec.totalSamples, 32_000)
        let w1 = rec.windowSince(0)
        XCTAssertEqual(w1.samples.count, 32_000)
        XCTAssertEqual(w1.newOffset, 32_000)
        rec.ingest([Float](repeating: 0.3, count: 8_000))
        let w2 = rec.windowSince(w1.newOffset)
        XCTAssertEqual(w2.samples.count, 8_000)
        XCTAssertEqual(w2.newOffset, 40_000)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MeetingRecorderTests`
Expected: FAIL — `cannot find 'MeetingRecorder'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/MeetingRecorder.swift`:

```swift
import Foundation
import AVFoundation

/// Continuous mic recorder: accumulates samples for transcription windows and writes an m4a for archive.
final class MeetingRecorder: @unchecked Sendable {
    private let capture: AudioCapture
    private let sampleRate: Int
    private let lock = NSLock()
    private var samples: [Float] = []
    private var audioFile: AVAudioFile?
    private var outputURL: URL?

    init(capture: AudioCapture, sampleRate: Int = 16_000) {
        self.capture = capture
        self.sampleRate = sampleRate
    }

    var totalSamples: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    func start(writingTo url: URL) throws {
        outputURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        capture.onAudioChunk = { [weak self] chunk in self?.ingest(chunk) }
        capture.startCapture()
    }

    /// Test/production seam: accept samples, buffer them, and append to the m4a.
    func ingest(_ chunk: [Float]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        guard let file = audioFile,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            buf.floatChannelData!.pointee.update(from: src.baseAddress!, count: chunk.count)
        }
        try? file.write(from: buf)
    }

    /// Return all samples from `offset` to now, plus the new offset.
    func windowSince(_ offset: Int) -> (samples: [Float], newOffset: Int) {
        lock.lock(); defer { lock.unlock() }
        guard offset < samples.count else { return ([], samples.count) }
        return (Array(samples[offset..<samples.count]), samples.count)
    }

    func stop() -> URL? {
        capture.stopCapture()
        capture.onAudioChunk = nil
        audioFile = nil     // finalizes the m4a
        return outputURL
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MeetingRecorderTests`
Expected: 1 test PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/MeetingRecorder.swift Tests/MeetingsTests/MeetingRecorderTests.swift
git commit -m "feat(meetings): mic recorder with windowing + m4a archive"
```

---

### Task 8: MeetingTranscriber (rolling transcription)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingTranscriber.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/MeetingTranscriberTests.swift`

**Interfaces:**
- Consumes: `MeetingRecorder` (Task 7), `TranscriptBuilder` (Task 3), a `Transcribing` protocol wrapping `WhisperBridge`.
- Produces: `protocol Transcribing { func transcribe(audioSamples:[Float]) async throws -> String }`; `extension WhisperBridge: Transcribing {}`; `actor MeetingTranscriber { init(recorder:MeetingRecorder, whisper:Transcribing, sampleRate:Int); func tick() async; func flush() async; func transcriptMarkdown(recordingName:String) -> String; func transcriptText() -> String }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingsTests/MeetingTranscriberTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class MeetingTranscriberTests: XCTestCase {
    struct FakeWhisper: Transcribing {
        func transcribe(audioSamples: [Float]) async throws -> String {
            "chunk of \(audioSamples.count) samples"
        }
    }

    func testTickTranscribesNewWindow() async {
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        let t = MeetingTranscriber(recorder: rec, whisper: FakeWhisper(), sampleRate: 16_000)
        rec.ingest([Float](repeating: 0.1, count: 32_000))   // 2s
        await t.tick()
        let md = await t.transcriptMarkdown(recordingName: "m.wav")
        XCTAssertTrue(md.contains("**[00:00]** chunk of 32000 samples"))
        // no new audio -> no new entry
        await t.tick()
        let text = await t.transcriptText()
        XCTAssertEqual(text, "chunk of 32000 samples")
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MeetingTranscriberTests`
Expected: FAIL — `cannot find 'MeetingTranscriber'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/MeetingTranscriber.swift`:

```swift
import Foundation

protocol Transcribing { func transcribe(audioSamples: [Float]) async throws -> String }
extension WhisperBridge: Transcribing {}

/// Pulls new audio windows from the recorder and appends transcribed text.
actor MeetingTranscriber {
    private let recorder: MeetingRecorder
    private let whisper: Transcribing
    private let sampleRate: Int
    private var offset = 0
    private var builder = TranscriptBuilder()

    init(recorder: MeetingRecorder, whisper: Transcribing, sampleRate: Int = 16_000) {
        self.recorder = recorder
        self.whisper = whisper
        self.sampleRate = sampleRate
    }

    /// Transcribe whatever new audio exists since the last tick.
    func tick() async {
        let startSec = offset / sampleRate
        let window = recorder.windowSince(offset)
        guard !window.samples.isEmpty else { return }
        do {
            let text = try await whisper.transcribe(audioSamples: window.samples)
            builder.append(startSeconds: startSec, rawText: text)
            offset = window.newOffset
        } catch {
            // leave offset unchanged; retried next tick
        }
    }

    func flush() async { await tick() }
    func transcriptMarkdown(recordingName: String) -> String { builder.markdown(recordingName: recordingName) }
    func transcriptText() -> String { builder.plainText() }
    var isEmpty: Bool { builder.isEmpty }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MeetingTranscriberTests`
Expected: 1 test PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/MeetingTranscriber.swift Tests/MeetingsTests/MeetingTranscriberTests.swift
git commit -m "feat(meetings): rolling transcriber over recorder windows"
```

---

### Task 9: MeetingDetector (CoreAudio + NSWorkspace adapter)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingDetector.swift`

**Interfaces:**
- Consumes: `DetectionStateMachine` (Task 2), `DetectionInput`, `MeetingEvent`.
- Produces: `final class MeetingDetector { init(config:MeetingConfig); var onEvent: ((MeetingEvent) -> Void)?; func start(); func stop(); func manualStart(); func manualStop() }` and `struct MeetingConfig { var startHold; var endDebounce; var minMeeting; var knownMeetingApps:Set<String> }`.

This is a system adapter — verified by build + manual live test (no unit test; CoreAudio device state can't be faked in CI).

- [ ] **Step 1: Implement the detector**

Create `Sources/Meetings/MeetingDetector.swift`:

```swift
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
            guard let self else { return }
            let active = Self.isDeviceRunningSomewhere(self.deviceID)
            self.emit(self.machine.update(.micActive(active), now: self.now()))
            self.emit(self.machine.update(.tick, now: self.now()))
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self.emit(self.machine.update(.appLaunched(id), now: self.now()))
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self.emit(self.machine.update(.appTerminated(id), now: self.now()))
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Manual live verification (documented, run once by a human)**

Run the app (Task 11 wires it) OR add a temporary `main`-level smoke in the app that prints events. Verify:
- Join a Zoom call on speakers → within ~5 s an `.started(.micActive)` event fires.
- Mute yourself for 60 s → NO `.ended`.
- Leave the call → within ~15 s an `.ended` fires.
Record the observation in the commit message.

- [ ] **Step 4: Commit**

```bash
git add Sources/Meetings/MeetingDetector.swift
git commit -m "feat(meetings): CoreAudio mic-in-use + NSWorkspace detector"
```

---

### Task 10: MeetingCoordinator (lifecycle orchestration)

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingCoordinator.swift`
- Test: `src/macos/OmniPilot/Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: all prior meeting types; `Pipeline` (existing, `start()`/`stop()`); `OllamaClient`, `WhisperBridge`, `AudioCapture` (existing).
- Produces: `@MainActor final class MeetingCoordinator { init(assistant:Pipeline?, whisper:WhisperBridge, ollama:OllamaClient, archiveRoot:URL, config:MeetingConfig); var onStateChange:((MeetingState)->Void)?; func handle(_ event:MeetingEvent); var state:MeetingState }`. A `MeetingClock` protocol supplies elapsed seconds for the min-duration guard (testable).

- [ ] **Step 1: Write the failing test (state transitions + min-duration guard)**

Create `Tests/MeetingsTests/MeetingCoordinatorTests.swift`:

```swift
import XCTest
@testable import OmniPilot

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    func testShortMeetingDiscarded() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coord-\(UUID().uuidString)")
        let coord = MeetingCoordinator.makeForTesting(archiveRoot: root, elapsed: 10)  // 10s < 60s
        coord.handle(.started(.manual))
        XCTAssertEqual(coord.state, .recording)
        await coord.handleAndWait(.ended)
        XCTAssertEqual(coord.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))  // nothing published
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MeetingCoordinatorTests`
Expected: FAIL — `cannot find 'MeetingCoordinator'`.

- [ ] **Step 3: Implement**

Create `Sources/Meetings/MeetingCoordinator.swift`:

```swift
import Foundation

protocol MeetingClock { func elapsedSeconds(since start: Date) -> TimeInterval }
struct RealClock: MeetingClock { func elapsedSeconds(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) } }

/// Sequences a meeting: pause assistant → record → transcribe (rolling) → summarize → publish → resume.
@MainActor
final class MeetingCoordinator {
    private(set) var state: MeetingState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((MeetingState) -> Void)?

    private let assistant: Pipeline?
    private let whisper: WhisperBridge
    private let ollama: OllamaClient
    private let archiveRoot: URL
    private let config: MeetingConfig
    private let clock: MeetingClock

    private var recorder: MeetingRecorder?
    private var transcriber: MeetingTranscriber?
    private var rollTimer: Timer?
    private var startedAt = Date()
    private var audioURL: URL?

    init(assistant: Pipeline?, whisper: WhisperBridge, ollama: OllamaClient,
         archiveRoot: URL, config: MeetingConfig, clock: MeetingClock = RealClock()) {
        self.assistant = assistant; self.whisper = whisper; self.ollama = ollama
        self.archiveRoot = archiveRoot; self.config = config; self.clock = clock
    }

    func handle(_ event: MeetingEvent) {
        switch event {
        case .started: beginRecording()
        case .ended: Task { await finalize() }
        }
    }

    private func beginRecording() {
        guard state == .idle else { return }
        assistant?.stop()
        startedAt = Date()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-\(UUID().uuidString).m4a")
        audioURL = tmp
        let rec = MeetingRecorder(capture: AudioCapture())
        try? rec.start(writingTo: tmp)
        let t = MeetingTranscriber(recorder: rec, whisper: whisper)
        recorder = rec; transcriber = t
        let timer = Timer(timeInterval: 90, repeats: true) { _ in Task { await t.tick() } }
        RunLoop.main.add(timer, forMode: .common); rollTimer = timer
        state = .recording
    }

    private func finalize() async {
        guard state == .recording, let rec = recorder, let t = transcriber else { return }
        rollTimer?.invalidate(); rollTimer = nil
        state = .finalizing
        _ = rec.stop()
        let elapsed = clock.elapsedSeconds(since: startedAt)

        if elapsed < config.minMeeting {           // discard short/false meetings
            cleanupTemp(); resetToIdle(); return
        }
        await t.flush()
        let transcriptText = t.transcriptText()
        let transcriptMD = t.transcriptMarkdown(recordingName: "audio.m4a")
        let notes: String
        if transcriptText.isEmpty {
            notes = "# Meeting Notes\n\n_Transcription unavailable._"
        } else if await ollama.isAvailable() {
            let s = MeetingSummarizer(llm: ollama)
            notes = (try? await s.summarize(transcript: transcriptText))
                ?? "# Meeting Notes\n\n_Summary failed._\n"
        } else {
            notes = "# Meeting Notes\n\n_Summary unavailable (Ollama offline)._"
        }
        state = .publishing
        let pub = ArchivePublisher(layout: ArchiveLayout(root: archiveRoot))
        _ = try? pub.publish(date: startedAt, title: nil, notes: notes,
                             transcript: transcriptMD, audio: audioURL)
        resetToIdle()
    }

    private func cleanupTemp() { if let u = audioURL { try? FileManager.default.removeItem(at: u) } }
    private func resetToIdle() {
        recorder = nil; transcriber = nil; audioURL = nil
        assistant?.start(); state = .idle
    }
}
```

- [ ] **Step 4: Add the test helper (same file, `#if DEBUG`)**

Append to `MeetingCoordinator.swift`:

```swift
#if DEBUG
extension MeetingCoordinator {
    struct FixedClock: MeetingClock { let s: TimeInterval; func elapsedSeconds(since start: Date) -> TimeInterval { s } }
    static func makeForTesting(archiveRoot: URL, elapsed: TimeInterval) -> MeetingCoordinator {
        MeetingCoordinator(assistant: nil, whisper: WhisperBridge(), ollama: OllamaClient(),
                           archiveRoot: archiveRoot, config: MeetingConfig(),
                           clock: FixedClock(s: elapsed))
    }
    func handleAndWait(_ event: MeetingEvent) async {
        handle(event)
        // finalize() runs in a Task; poll until idle (bounded).
        for _ in 0..<50 where state != .idle { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter MeetingCoordinatorTests`
Expected: PASS — short meeting discarded, folder never created, state returns to `.idle`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Meetings/MeetingCoordinator.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "feat(meetings): coordinator lifecycle + min-duration guard + graceful degradation"
```

---

### Task 11: Menu-bar UI + app wiring

**Files:**
- Create: `src/macos/OmniPilot/Sources/Meetings/MeetingsMenu.swift`
- Modify: `src/macos/OmniPilot/Sources/App/OmniPilotApp.swift` (wire detector→coordinator into `AppDelegate`; add menu items)

**Interfaces:**
- Consumes: `MeetingDetector` (Task 9), `MeetingCoordinator` (Task 10), existing `AppDelegate`, `Pipeline`.
- Produces: menu integration; a settings read for `meeting.archiveRoot`.

System/UI adapter — build + manual verification.

- [ ] **Step 1: Implement the menu helper**

Create `Sources/Meetings/MeetingsMenu.swift`:

```swift
import AppKit

/// Owns the detector+coordinator and exposes NSMenuItems + status text for the menu bar.
@MainActor
final class MeetingsController {
    let detector: MeetingDetector
    let coordinator: MeetingCoordinator
    private(set) var statusText = "Meetings: Idle"

    init(assistant: Pipeline?, whisper: WhisperBridge, ollama: OllamaClient) {
        let root = Self.archiveRoot()
        let cfg = MeetingConfig()
        self.detector = MeetingDetector(config: cfg)
        self.coordinator = MeetingCoordinator(assistant: assistant, whisper: whisper,
                                              ollama: ollama, archiveRoot: root, config: cfg)
        detector.onEvent = { [weak self] e in self?.coordinator.handle(e) }
        coordinator.onStateChange = { [weak self] s in self?.updateStatus(s) }
    }

    static func archiveRoot() -> URL {
        if let p = UserDefaults.standard.string(forKey: "meeting.archiveRoot"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OmniPilot Meetings")
    }

    func startAutoDetect() { if UserDefaults.standard.object(forKey: "meeting.autoDetect") as? Bool ?? true { detector.start() } }
    private func updateStatus(_ s: MeetingState) {
        switch s {
        case .idle: statusText = "Meetings: Idle"
        case .recording: statusText = "Meetings: Recording…"
        case .finalizing: statusText = "Meetings: Transcribing…"
        case .publishing: statusText = "Meetings: Publishing…"
        }
    }

    @objc func manualToggle() {
        if coordinator.state == .idle { detector.manualStart() } else { detector.manualStop() }
    }
    @objc func openArchive() { NSWorkspace.shared.open(Self.archiveRoot()) }
}
```

- [ ] **Step 2: Wire into AppDelegate**

In `Sources/App/OmniPilotApp.swift`, add a stored property to `AppDelegate`:

```swift
    var meetings: MeetingsController?
```

In `applicationDidFinishLaunching(_:)`, after the assistant pipeline is created (where `pipeline`, `whisper`, `ollama` exist), add:

```swift
        // Meetings feature (Pillar M / M1)
        let mc = MeetingsController(assistant: self.pipeline, whisper: self.whisper, ollama: self.ollama)
        mc.startAutoDetect()
        self.meetings = mc
```

In `showMenu()` (where the NSMenu is built), add items:

```swift
        let mItem = NSMenuItem(title: meetings?.statusText ?? "Meetings: Idle", action: nil, keyEquivalent: "")
        menu.addItem(mItem)
        let toggle = NSMenuItem(title: "Start/Stop Meeting", action: #selector(meetingToggle), keyEquivalent: "m")
        toggle.target = self; menu.addItem(toggle)
        let open = NSMenuItem(title: "Open Meetings Folder", action: #selector(meetingOpen), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        menu.addItem(.separator())
```

Add matching `@objc` methods to `AppDelegate`:

```swift
    @objc func meetingToggle() { meetings?.manualToggle() }
    @objc func meetingOpen() { meetings?.openArchive() }
```

(Adjust property names `self.pipeline` / `self.whisper` / `self.ollama` to the actual ones in `AppDelegate`; if they are locals inside `applicationDidFinishLaunching`, promote them to stored properties.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual verification**

Run the app. Confirm:
- Menu shows "Meetings: Idle".
- "Start/Stop Meeting" → status flips to "Recording…"; speak 90 s; Stop → "Transcribing…" → "Publishing…" → "Idle".
- "Open Meetings Folder" opens `~/OmniPilot Meetings`; a `YYYY-MM-DD_HH-mm_Meeting/` folder holds `notes.md`, `transcript.md`, `audio.m4a`.
- Set `meeting.archiveRoot` (via `defaults write` or Settings) to a synced Drive folder; verify a subsequent meeting lands there.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meetings/MeetingsMenu.swift Sources/App/OmniPilotApp.swift
git commit -m "feat(meetings): menu-bar status/controls + app wiring"
```

---

### Task 12: End-to-end integration test + register suite

**Files:**
- Create: `src/macos/OmniPilot/Tests/MeetingsTests/EndToEndTests.swift`
- Create: `src/macos/OmniPilot/Tests/MeetingsTests/Fixtures/` note (see step 1)

**Interfaces:**
- Consumes: `MeetingRecorder`, `MeetingTranscriber`, `MeetingSummarizer`, `ArchivePublisher` (all prior).

- [ ] **Step 1: Write the end-to-end test (stubbed whisper + LLM, no external services)**

Create `Tests/MeetingsTests/EndToEndTests.swift`:

```swift
import XCTest
@testable import OmniPilot

final class EndToEndTests: XCTestCase {
    struct StubWhisper: Transcribing {
        func transcribe(audioSamples: [Float]) async throws -> String { "we discussed the roadmap and next steps" }
    }
    struct StubLLM: LLMGenerating {
        func generate(prompt: String, system: String?) async throws -> String {
            prompt.contains("FINAL notes") ? "## TL;DR\nRoadmap discussed.\n## Action Items\n- [ ] follow up" : "- roadmap"
        }
    }

    func testFullPipelineProducesArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e-\(UUID().uuidString)")

        // 1. record: feed 3 windows of 90s of silence-sized buffers via ingest
        let rec = MeetingRecorder(capture: AudioCapture(), sampleRate: 16_000)
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e.m4a")
        try rec.start(writingTo: audioURL)
        for _ in 0..<3 { rec.ingest([Float](repeating: 0.05, count: 16_000 * 90)) }
        // 2. transcribe
        let t = MeetingTranscriber(recorder: rec, whisper: StubWhisper(), sampleRate: 16_000)
        await t.tick(); await t.flush()
        _ = rec.stop()
        // 3. summarize
        let notes = try await MeetingSummarizer(llm: StubLLM()).summarize(transcript: t.transcriptText())
        // 4. publish
        let art = try ArchivePublisher(layout: ArchiveLayout(root: root))
            .publish(date: Date(), title: "Roadmap", notes: notes,
                     transcript: t.transcriptMarkdown(recordingName: "audio.m4a"), audio: audioURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: art.notesMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.transcriptMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.audioM4A.path))
        let notesText = try String(contentsOf: art.notesMD, encoding: .utf8)
        XCTAssertTrue(notesText.contains("TL;DR"))
        XCTAssertTrue(notesText.contains("Action Items"))
    }
}
```

- [ ] **Step 2: Run the full suite**

Run: `swift test`
Expected: ALL MeetingsTests PASS (models, detection, transcript, layout, summarizer, publisher, recorder, transcriber, coordinator, e2e).

- [ ] **Step 3: Register the integration suite (per test-pipeline rule)**

Run (records the suite in DevPilot so `task_done` triggers re-run):

```bash
PGPASSWORD=devpilot psql -h localhost -p 5499 -U devpilot -d devpilot -c "
INSERT INTO project_test_config (project_id, suite_name, suite_type, runner_type, test_command, working_dir, trigger_on, trigger_phases, active)
VALUES ('omnipilot','meetings-m1','integration','swift',
 'swift test','/Users/soumyaswain/Documents/tinker/projects/omnipilot/src/macos/OmniPilot',
 ARRAY['task_done','manual','backfill'], ARRAY['test','verify'], true)
ON CONFLICT DO NOTHING;"
```

- [ ] **Step 4: Commit**

```bash
git add Tests/MeetingsTests/EndToEndTests.swift
git commit -m "test(meetings): end-to-end pipeline integration test"
```

---

## Self-Review

**Spec coverage:**
- Detect (mic + app) → Tasks 2, 9. End-on-disconnect/mute-safe → Task 2 (tests) + Task 9 (adapter). ✓
- Record mic → Task 7. Transcribe rolling → Task 8. Summarize map-reduce → Task 5. Publish md/transcript/audio(+pdf) → Task 6. ✓
- Menu-bar status/start-stop/recent(open folder)/archive setting → Task 11. ✓
- Pause/resume assistant Pipeline → Task 10 (`assistant?.stop()`/`start()`). ✓
- `minMeetingSeconds` discard → Task 10 (tested). `endDebounceSeconds`, `startHold` → Task 2 (tested). ✓
- Graceful degradation (whisper/Ollama down) → Task 10 (notes stubs). ✓
- Testing (unit + integration + live) → Tasks 2-8, 10, 12 unit/integration; Tasks 9, 11 manual live. ✓
- Out-of-scope (system tap, calendar, OCR, web, video) → not implemented; deferred. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. Task 11 flags real-property-name adjustment explicitly (not a placeholder — an integration instruction against existing code).

**Type consistency:** `windowSince(_:) -> (samples:[Float], newOffset:Int)` used consistently (Tasks 7, 8). `generate(prompt:system:)` matches existing `OllamaClient`. `transcribe(audioSamples:)` matches existing `WhisperBridge`. `MeetingEvent`/`MeetingState`/`DetectionInput` consistent across Tasks 1, 2, 9, 10. `ArchivePublisher.publish(date:title:notes:transcript:audio:)` consistent (Tasks 6, 10, 12).

## Notes for the implementer
- `AppDelegate` in `OmniPilotApp.swift` may hold `pipeline`/`whisper`/`ollama` as locals — promote to stored properties before Task 11 wiring (mentioned in Task 11 Step 2).
- whisper-server must be running for live tests (Task 9/11): `scripts/run.sh` or the vendored `whisper-server -m models/ggml-small.en.bin --port 18386`.
- Ollama must have a small model (`llama3.2:3b`) for live summary; unit/integration tests stub it.
