import Foundation
import AVFoundation
import SoundAnalysis
import Speech

/// Audio and speech layers.
///
/// Three of these want the same microphone and two want the same classifier output,
/// so the expensive machinery lives in two hubs that reference-count their
/// subscribers. Four audio layers switched on means one mic tap, one sound analyzer
/// and one speech task — not four of each, which is what a naive layer-per-model
/// design produces and is why audio is usually where this kind of system falls over.

// MARK: - Sound classification hub

/// Owns the single SNAudioStreamAnalyzer. Apple's built-in classifier knows roughly
/// three hundred everyday sounds — glass breaking, a door, a car horn, a dog, a
/// raised voice — with no model to bundle and no network.
final class SoundHub: NSObject, SNResultsObserving {

    static let shared = SoundHub()

    struct Hit {
        let identifier: String
        let confidence: Double
        let at: Date
    }

    private var analyzer: SNAudioStreamAnalyzer?
    private var classifyRequest: SNClassifySoundRequest?
    private var framePosition: AVAudioFramePosition = 0
    private var lastSampleTime: AVAudioFramePosition = -1
    private var subscribers = 0
    private let lock = NSLock()

    /// Everything above a low floor, newest last, trimmed to a minute. Both the
    /// event layer and the noise-profile layer read this.
    private(set) var recent: [Hit] = []
    /// What the built-in classifier can name, read at runtime rather than hardcoded.
    private(set) var knownLabels: [String] = []
    private(set) var startupError: String?

    func retain() {
        lock.lock(); subscribers += 1; lock.unlock()
    }

    func release() {
        lock.lock()
        subscribers = max(0, subscribers - 1)
        let done = subscribers == 0
        lock.unlock()
        if done { teardown() }
    }

    private func teardown() {
        lock.lock()
        if let classifyRequest, let analyzer { analyzer.remove(classifyRequest) }
        analyzer = nil
        classifyRequest = nil
        framePosition = 0
        lastSampleTime = -1
        recent.removeAll()
        lock.unlock()
    }

    /// Built on the first buffer, because that is the first point the real input
    /// format is known — guessing it and getting it wrong makes the analyzer
    /// silently produce nothing.
    private func prepare(format: AVAudioFormat) {
        lock.lock()
        let needed = analyzer == nil
        lock.unlock()
        guard needed else { return }
        do {
            let r = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // Window duration is left at the classifier's own default. It advertises
            // a constraint that throws if violated, and the default is inside it by
            // definition — overlap is the safe knob, and halving it is what makes
            // short sounds like a door or breaking glass land in a window at all.
            r.overlapFactor = 0.5
            let a = SNAudioStreamAnalyzer(format: format)
            // The analyzer holds the observer weakly, so this singleton being the
            // observer is what keeps results flowing.
            try a.add(r, withObserver: self)
            lock.lock()
            analyzer = a
            classifyRequest = r
            lock.unlock()
            knownLabels = r.knownClassifications
            startupError = nil
            EventLog.action("sound.classifier.ready", ["labels": r.knownClassifications.count])
        } catch {
            startupError = error.localizedDescription
            EventLog.error(error, name: "sound.classifier.failed")
        }
    }

    /// Feeds one buffer to the classifier exactly once, however many layers ask.
    ///
    /// Both the event layer and the noise-profile layer call this from their own
    /// `process`, so with both switched on every buffer was submitted twice and the
    /// frame position advanced twice — the analyzer was told the same audio had
    /// happened twice in a row at two different times. Every sound was counted
    /// twice, the profile's rankings were doubled, and the timeline it reasons over
    /// was wrong by a factor of two. The buffer's own sample time is the identity
    /// that makes the second call a no-op.
    func analyze(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        let stamp = time.isSampleTimeValid ? time.sampleTime : AVAudioFramePosition(-1)
        if stamp >= 0, stamp == lastSampleTime {
            lock.unlock()
            return
        }
        lastSampleTime = stamp
        lock.unlock()

        prepare(format: buffer.format)
        lock.lock()
        let active = analyzer
        let position = framePosition
        framePosition += AVAudioFramePosition(buffer.frameLength)
        lock.unlock()

        active?.analyze(buffer, atAudioFramePosition: position)
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let now = Date()
        // SNClassification confidence is a Double, unlike every Vision confidence.
        let hits = classification.classifications
            .filter { $0.confidence > 0.25 }
            .prefix(4)
            .map { Hit(identifier: $0.identifier, confidence: $0.confidence, at: now) }
        guard !hits.isEmpty else { return }
        lock.lock()
        recent.append(contentsOf: hits)
        recent.removeAll { now.timeIntervalSince($0.at) > 60 }
        if recent.count > 400 { recent.removeFirst(recent.count - 400) }
        lock.unlock()
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        startupError = error.localizedDescription
        EventLog.error(error, name: "sound.classifier.error")
    }

    var snapshot: [Hit] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }
}

// MARK: - Sound events

final class SoundEventLayer: AudioAILayer {
    let id = "sound.events"
    let title = "Name what it hears"
    let detail = "Names sounds it picks up — breaking glass, alarms, doors, dogs, speech."
    let group = LayerGroup.audio
    let modality = LayerModality.audio
    let availability = LayerAvailability.available
    let warmAtLaunch = false

    /// Sounds worth raising rather than merely listing. Everything else still
    /// appears in the output feed.
    private static let notable: Set<String> = [
        "glass_breaking", "shatter", "siren", "car_alarm", "smoke_detector",
        "fire_alarm", "alarm_clock", "gunshot_gunfire", "shout", "yell", "scream",
        "screaming", "door_slam", "slam", "knock", "doorbell", "car_horn",
        "vehicle_horn_car_horn_honking", "glass", "breaking", "crash", "dog_bark",
        "dog", "babble", "crying_sobbing", "whistling", "police_siren"
    ]

    private var warmed = false
    private var lastReported: [String: Date] = [:]

    func warm() {
        guard !warmed else { return }
        SoundHub.shared.retain()
        warmed = true
    }

    func cool() {
        guard warmed else { return }
        SoundHub.shared.release()
        warmed = false
    }

    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput? {
        SoundHub.shared.analyze(buffer: buffer, at: time)

        let hits = SoundHub.shared.snapshot
        guard let latest = hits.last else { return nil }
        let now = Date()

        var out = LayerOutput()
        // The snapshot holds a minute of history, so the most recent entry in it
        // can be fifty seconds old. Badging it unconditionally left the name of a
        // long-finished sound sitting on the toggle in a silent room.
        out.badge = now.timeIntervalSince(latest.at) < 4
            ? latest.identifier.replacingOccurrences(of: "_", with: " ")
            : "listening"

        var lines: [String] = []
        for hit in hits where hit.confidence > 0.5 && now.timeIntervalSince(hit.at) < 1.5 {
            let cooled = now.timeIntervalSince(lastReported[hit.identifier] ?? .distantPast) > 6
            guard cooled else { continue }
            lastReported[hit.identifier] = now
            let pretty = hit.identifier.replacingOccurrences(of: "_", with: " ")
            lines.append(String(format: "%@ %.0f%%", pretty, hit.confidence * 100))
            if SoundEventLayer.notable.contains(hit.identifier), hit.confidence > 0.62 {
                out.alert = "Heard \(pretty)"
            }
        }
        out.lines = lines
        return out.isEmpty ? nil : out
    }

    func reset() { lastReported.removeAll() }
}

// MARK: - Noise profile

final class NoiseProfileLayer: AudioAILayer {
    let id = "sound.noise"
    let title = "What this place sounds like"
    let detail = "The sounds heard over the last minute, most common first."
    let group = LayerGroup.audio
    let modality = LayerModality.audio
    let availability = LayerAvailability.available
    let warmAtLaunch = false

    private var warmed = false
    private var lastSummary = Date.distantPast

    func warm() {
        guard !warmed else { return }
        SoundHub.shared.retain()
        warmed = true
    }

    func cool() {
        guard warmed else { return }
        SoundHub.shared.release()
        warmed = false
    }

    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput? {
        SoundHub.shared.analyze(buffer: buffer, at: time)
        guard Date().timeIntervalSince(lastSummary) > 15 else { return nil }
        lastSummary = Date()

        let hits = SoundHub.shared.snapshot
        guard hits.count > 4 else { return nil }

        // Rank by summed confidence rather than count: one confident siren should
        // outrank fifty frames of faint hum.
        var weight: [String: Double] = [:]
        for h in hits { weight[h.identifier, default: 0] += h.confidence }
        let ranked = weight.sorted { $0.value > $1.value }.prefix(4)

        var out = LayerOutput()
        out.badge = ranked.first?.key.replacingOccurrences(of: "_", with: " ")
        out.lines = ["last minute: " + ranked
            .map { $0.key.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")]
        return out
    }
}

// MARK: - Voice activity

/// Level-based, not model-based: speech energy against the learned ambient floor.
/// The sound classifier also reports a speech class, and that layer will say so —
/// this one exists because it costs nothing and answers "is someone talking right
/// now" with far less latency than a classification window.
final class VoiceActivityLayer: AudioAILayer {
    let id = "audio.vad"
    let title = "Is someone talking"
    let detail = "Tells you when someone is speaking by comparing the level against the background. No model involved."
    let group = LayerGroup.audio
    let modality = LayerModality.audio
    let availability = LayerAvailability.available

    private var speaking = false
    private var runStarted = Date.distantPast
    private var ambient: Float?

    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput? {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))

        // Seed the floor from the room rather than from a constant. Starting at a
        // fixed -50 dB meant that anywhere louder than that — a road, a plant room,
        // a busy office — opened above the threshold and the slow attack took
        // minutes to climb out of it, so the layer reported continuous speech in a
        // room where nobody was talking.
        guard let current = ambient else {
            ambient = db
            return nil
        }
        // Slow floor, so a conversation does not raise the bar it is measured against.
        let ambientNow = current + (db - current) * (db < current ? 0.05 : 0.002)
        ambient = ambientNow
        let wasSpeaking = speaking
        speaking = db > ambientNow + 9

        var out = LayerOutput()
        out.badge = speaking ? "speaking" : "quiet"
        if speaking, !wasSpeaking { runStarted = Date() }
        if !speaking, wasSpeaking {
            let length = Date().timeIntervalSince(runStarted)
            if length > 0.6 { out.lines = [String(format: "voice, %.1fs", length)] }
        }
        return out
    }

    func reset() { speaking = false; ambient = nil }
}

// MARK: - Speech transcription

/// Owns the one speech task. The legacy framework kills any task running longer
/// than a minute, so this rolls over to a fresh task before that happens — without
/// it, transcription dies silently after sixty seconds, which looks exactly like a
/// broken microphone.
final class SpeechHub {

    static let shared = SpeechHub()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt = Date.distantPast
    private var subscribers = 0
    private let lock = NSLock()

    private(set) var partial = ""
    /// Finalized utterances, newest last.
    private(set) var finals: [String] = []
    private(set) var problem: String?
    /// The last text committed to `finals`, so a rollover and the task's own final
    /// result do not both record the same sentence.
    private var lastCommitted = ""

    var isAvailable: Bool { recognizer?.isAvailable ?? false }
    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func retain() {
        lock.lock(); subscribers += 1; let first = subscribers == 1; lock.unlock()
        guard first else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                self?.problem = "Speech recognition permission not granted"
                return
            }
            self?.restart()
        }
    }

    func release() {
        lock.lock()
        subscribers = max(0, subscribers - 1)
        let done = subscribers == 0
        lock.unlock()
        guard done else { return }
        finish()
    }

    private func finish() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        partial = ""
    }

    private func restart() {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognizer unavailable for this locale"
            return
        }
        finish()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        // On-device keeps audio off Apple's servers. Where it is not supported the
        // layer says so rather than quietly uploading the microphone.
        if recognizer.supportsOnDeviceRecognition {
            r.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) { r.addsPunctuation = true }
        request = r
        startedAt = Date()
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.partial = text
                // A rollover commits the partial and then starts a new task; the
                // old task's own final arrives afterwards with the same words, so
                // without this the last sentence before every rollover appeared
                // twice in the transcript and was fed to the language layers twice.
                if result.isFinal, !text.isEmpty, text != self.lastCommitted {
                    self.lastCommitted = text
                    self.finals.append(text)
                    if self.finals.count > 60 { self.finals.removeFirst() }
                    TextBus.shared.add(text, source: "speech")
                }
            }
            if let error {
                let ns = error as NSError
                // 203 / 216 are the ordinary end-of-task codes; they are not faults.
                if ns.code != 203 && ns.code != 216 {
                    self.problem = error.localizedDescription
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let request else { return }
        request.append(buffer)
        // Roll over well before the framework's own one-minute ceiling.
        if Date().timeIntervalSince(startedAt) > 50 {
            if !partial.isEmpty, partial != lastCommitted {
                lastCommitted = partial
                finals.append(partial)
                TextBus.shared.add(partial, source: "speech")
            }
            restart()
        }
    }
}

final class TranscriptionLayer: AudioAILayer {
    let id = "speech.transcript"
    let title = "Write down speech"
    let detail = "Turns speech into text on this device. Every language layer reads from this one."
    let group = LayerGroup.audio
    let modality = LayerModality.audio
    var availability: LayerAvailability {
        guard SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil else {
            return .noPublicAPI("No speech recognizer for this locale")
        }
        return SpeechHub.shared.supportsOnDevice
            ? .available
            : .needsNetwork("This device cannot transcribe on-device for this locale, so audio would go to Apple's servers")
    }
    let warmAtLaunch = false

    private var warmed = false
    private var lastEmitted = ""

    func warm() {
        guard !warmed else { return }
        SpeechHub.shared.retain()
        warmed = true
    }

    func cool() {
        guard warmed else { return }
        SpeechHub.shared.release()
        warmed = false
    }

    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput? {
        SpeechHub.shared.append(buffer)

        var out = LayerOutput()
        if let problem = SpeechHub.shared.problem {
            out.badge = "error"
            out.lines = [problem]
            return out
        }
        let partial = SpeechHub.shared.partial
        guard !partial.isEmpty else { return nil }
        out.badge = "\(partial.split(separator: " ").count)w"
        // Emit only when the tail has actually changed, or the feed fills with
        // every intermediate guess of the same sentence. The length test alone was
        // not enough: after a rollover the new task's partial starts short again,
        // and nothing was emitted until it had grown past the length of the whole
        // previous minute — so transcription appeared to stop after fifty seconds.
        // A partial that is not an extension of the last one is a new utterance.
        let continued = partial.hasPrefix(lastEmitted)
        if partial != lastEmitted,
           !continued || partial.count > lastEmitted.count + 12 {
            lastEmitted = partial
            out.lines = [partial]
        }
        return out.isEmpty ? nil : out
    }

    func reset() { lastEmitted = "" }
}

// MARK: - Declared unavailable

enum AudioLayerGaps {
    static func all() -> [AILayer] {
        [
        ]
    }
}
