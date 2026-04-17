import Foundation
import AVFoundation

/// Text-to-speech output for OmniPilot reminders and responses
class VoiceOutput: @unchecked Sendable {
    static let shared = VoiceOutput()

    private let synthesizer = AVSpeechSynthesizer()
    private var currentVoice: AVSpeechSynthesisVoice?
    private var isEnabled = true

    /// TRUE while OmniPilot is speaking — Pipeline checks this to mute mic input
    private(set) var isSpeaking = false

    /// Available voice presets
    enum VoicePreset: String, CaseIterable {
        case system = "Default"
        case indian = "Aman (Indian English)"
        case british = "Daniel (British)"
        case american = "Samantha (American)"

        var identifier: String? {
            switch self {
            case .system: return nil
            case .indian: return "com.apple.voice.compact.en-IN.Aman"
            case .british: return "com.apple.speech.synthesis.voice.daniel.premium"
            case .american: return "com.apple.voice.compact.en-US.Samantha"
            }
        }
    }

    private init() {
        // Default to Indian English voice
        setVoice(.indian)
    }

    /// Set the voice preset
    func setVoice(_ preset: VoicePreset) {
        if let id = preset.identifier {
            currentVoice = AVSpeechSynthesisVoice(identifier: id)
        }
        // Fallback: try by language
        if currentVoice == nil {
            currentVoice = AVSpeechSynthesisVoice(language: "en-IN")
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        print("[Voice] Set to: \(currentVoice?.name ?? "System Default")")
    }

    /// Speak text aloud (mutes mic listening while speaking to prevent feedback loop)
    func speak(_ text: String, rate: Float = 0.5, pitch: Float = 1.0) {
        guard isEnabled else { return }

        // Stop any current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }

        // Mark as speaking — Pipeline will ignore transcriptions while this is true
        isSpeaking = true

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = 0.8
        utterance.preUtteranceDelay = 0.2
        utterance.postUtteranceDelay = 0.5  // Extra silence after speaking

        synthesizer.speak(utterance)

        // Reset isSpeaking after utterance finishes
        // Estimate duration: ~3 chars per second at rate 0.5
        let estimatedDuration = Double(text.count) / 6.0 + 1.5
        DispatchQueue.global().asyncAfter(deadline: .now() + estimatedDuration) { [weak self] in
            self?.isSpeaking = false
        }
    }

    /// Speak a reminder — short and direct, just the task
    func speakReminder(_ text: String) {
        speak(text, rate: 0.48)
    }

    /// Speak daily summary (slower for comprehension)
    func speakSummary(_ text: String) {
        speak(text, rate: 0.45)
    }

    /// Stop speaking
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Toggle voice on/off
    func toggle() -> Bool {
        isEnabled.toggle()
        if !isEnabled { stop() }
        return isEnabled
    }

    var enabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue; if !newValue { stop() } }
    }

    /// List all available voices on this Mac
    static func availableVoices() -> [(name: String, language: String, id: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.starts(with: "en") }
            .map { ($0.name, $0.language, $0.identifier) }
    }
}
