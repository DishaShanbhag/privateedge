import AVFoundation
import Speech
import SwiftUI

/// Speak instead of typing, fully on the device. Uses Apple's speech recognizer with
/// `requiresOnDeviceRecognition`, so audio never leaves the phone; if on-device recognition is not
/// available, it refuses rather than falling back to Apple's servers. The recognizer runs in a
/// system process, so it adds nothing to this app's memory footprint (which the Measure tab reports).
/// Voice is a front end only: the text it produces goes through the same pipeline as typed text, and
/// it is not part of the evaluation.
@MainActor
final class VoiceInput: ObservableObject {
    @Published var listening = false
    @Published var problem: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func toggle(onText: @escaping (String) -> Void) {
        listening ? stop() : start(onText: onText)
    }

    private func start(onText: @escaping (String) -> Void) {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.problem = "Speech recognition is not allowed (Settings › Privacy & Security › Speech Recognition)."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else { self.problem = "Microphone access is not allowed."; return }
                        self.begin(onText: onText)
                    }
                }
            }
        }
    }

    private func begin(onText: @escaping (String) -> Void) {
        guard let r = recognizer, r.isAvailable else { problem = "Speech recognition is not available right now."; return }
        guard r.supportsOnDeviceRecognition else {
            problem = "On-device speech recognition is not available here (the Simulator usually has none). PrivateEdge never sends audio to a server, so voice is off."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true   // never Apple's servers
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
            listening = true
            task = r.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let result {
                        onText(result.bestTranscription.formattedString)
                        if result.isFinal { self.stop() }
                    }
                    if error != nil { self.stop() }
                }
            }
        } catch {
            problem = "Could not start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// A mic button that fills `text` with what the user says.
struct MicButton: View {
    @Binding var text: String
    @StateObject private var voice = VoiceInput()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                voice.toggle { text = $0 }
            } label: {
                Image(systemName: voice.listening ? "stop.circle.fill" : "mic.circle")
                    .font(.title2)
                    .foregroundStyle(voice.listening ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.listening ? "Stop listening" : "Speak instead of typing")
            if let p = voice.problem {
                Text(p).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.trailing)
            }
        }
    }
}
