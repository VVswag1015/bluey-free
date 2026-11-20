import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text for free voice (no OpenAI). It only works while you hold Bluey:
/// LiveVoice feeds it the mic audio, and it hands back the words when you let go.
/// Uses Apple's on-device recognizer when the iPhone supports it for your language.
final class FreeSpeech {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finishHandler: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Words heard so far, while you're still holding (called on the main queue).
    var onPartial: ((String) -> Void)?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    static func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    /// Starts listening. Returns false if speech recognition can't run right now.
    func begin() -> Bool {
        cancel()
        guard let recognizer, recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result { self.latest = result.bestTranscription.formattedString }
            let text = self.latest
            let finished = (result?.isFinal ?? false) || error != nil
            let handler = finished ? self.finishHandler : nil
            if finished { self.finishHandler = nil }
            self.lock.unlock()
            if let handler { handler(text) }
            else if result != nil, !finished { DispatchQueue.main.async { self.onPartial?(text) } }
        }
        lock.lock()
        self.request = request
        self.task = task
        self.latest = ""
        self.finishHandler = nil
        lock.unlock()
        return true
    }

    /// Feeds mic audio (called from the audio thread; does nothing unless you're holding).
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = self.request; lock.unlock()
        request?.append(buffer)
    }

    /// You let go: calls back once, on the main queue, with the best words it has.
    func finish(_ done: @escaping (String) -> Void) {
        lock.lock()
        guard let request else { lock.unlock(); done(""); return }
        final class Once { var fired = false }
        let once = Once()
        let deliver: (String) -> Void = { text in
            DispatchQueue.main.async {
                guard !once.fired else { return }
                once.fired = true
                done(text)
            }
        }
        finishHandler = deliver
        lock.unlock()
        request.endAudio()
        // If the recognizer is slow to finish, use what it has heard so far.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let text = self.latest; self.lock.unlock()
            deliver(text)
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        request = nil; self.task = nil; finishHandler = nil; latest = ""
        lock.unlock()
        task?.cancel()
    }
}
