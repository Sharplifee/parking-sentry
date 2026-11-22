import Foundation
import AVFoundation
import Accelerate

/// How something was said, rather than what was said.
///
/// There is no trained speech-emotion model here, and the layer says so rather than
/// implying one. What it measures instead is prosody — the physical properties of
/// the voice that emotion actually moves: loudness, how fast the loudness is
/// changing, pitch, and how much the pitch is jumping around. Those four are
/// measurable with no model at all, and together they separate calm speech from
/// agitated speech reliably, which is the distinction a sentry camera needs.
///
/// It also folds in Apple's sound classifier, which already has shout, scream,
/// crying and laughter among its three hundred classes. Those are the honest
/// labelled part; the prosody is the continuous part. What it deliberately does
/// not do is name an emotion — "agitated" is a claim about the signal, "angry" is
/// a claim about a person's inner state, and nothing here can support the second.
final class ProsodyLayer: AudioAILayer {
    let id = "audio.emotion"
    let title = "Vocal tone & agitation"
    let detail = "Measures loudness, pitch and how unsteady the voice is. No emotion model — it reports the signal, not a feeling."
    let group = LayerGroup.audio
    let modality = LayerModality.audio
    let availability = LayerAvailability.available
    let warmAtLaunch = false

    private var warmed = false
    /// Rolling windows, a few seconds each at the tap's buffer rate.
    private var loudness: [Double] = []
    private var pitches: [Double] = []
    private var lastReport = Date.distantPast
    private var lastVerdict = ""

    func warm() {
        guard !warmed else { return }
        // Shares the one classifier with the sound-event layer.
        SoundHub.shared.retain()
        warmed = true
    }

    func cool() {
        guard warmed else { return }
        SoundHub.shared.release()
        warmed = false
        loudness.removeAll()
        pitches.removeAll()
    }

    func reset() { loudness.removeAll(); pitches.removeAll() }

    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput? {
        SoundHub.shared.analyze(buffer: buffer, at: time)

        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 512 else { return nil }

        // Loudness in dB, which is what the ear tracks rather than amplitude.
        var meanSquare: Float = 0
        vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(n))
        let rms = Double(meanSquare).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))

        loudness.append(db)
        if loudness.count > 120 { loudness.removeFirst() }

        // Only measure pitch when there is something voiced to measure; an
        // autocorrelation on silence returns confident nonsense.
        if db > -42, let f0 = pitch(channel, count: n,
                                   sampleRate: buffer.format.sampleRate) {
            pitches.append(f0)
            if pitches.count > 120 { pitches.removeFirst() }
        }

        guard loudness.count > 30 else { return nil }

        let loudMean = loudness.reduce(0, +) / Double(loudness.count)
        let loudPeak = loudness.max() ?? loudMean
        // How jumpy the loudness is — shouting is not just loud, it is uneven.
        let loudSwing = standardDeviation(loudness)

        var out = LayerOutput()
        var parts: [String] = []

        if pitches.count > 8 {
            let pitchMean = pitches.reduce(0, +) / Double(pitches.count)
            let pitchSwing = standardDeviation(pitches)
            parts.append(String(format: "pitch %.0f Hz ±%.0f", pitchMean, pitchSwing))

            // Agitation as a composite of the three things that actually move
            // together in a raised voice: it gets loud, it gets uneven, and the
            // pitch climbs and wobbles.
            var score = 0.0
            if loudPeak > loudMean + 8 { score += 0.3 }
            if loudSwing > 6 { score += 0.25 }
            if pitchMean > 200 { score += 0.2 }
            if pitchSwing > 45 { score += 0.25 }

            // Apple's classifier is the labelled half.
            let recent = SoundHub.shared.snapshot.filter {
                Date().timeIntervalSince($0.at) < 6 && $0.confidence > 0.4
            }
            let flagged = recent.filter {
                ["shout", "yell", "screaming", "scream", "crying_sobbing", "whispering"]
                    .contains($0.identifier)
            }
            if !flagged.isEmpty { score = min(1, score + 0.3) }

            let verdict: String
            switch score {
            case ..<0.3:  verdict = "calm"
            case ..<0.55: verdict = "animated"
            case ..<0.8:  verdict = "agitated"
            default:      verdict = "highly agitated"
            }
            out.badge = verdict

            if verdict != lastVerdict, score >= 0.55,
               Date().timeIntervalSince(lastReport) > 12 {
                lastVerdict = verdict
                lastReport = Date()
                var line = "voice sounds \(verdict) — " + parts.joined(separator: ", ")
                if let first = flagged.first {
                    line += ", classifier heard \(first.identifier.replacingOccurrences(of: "_", with: " "))"
                }
                out.lines = [line]
                TextBus.shared.add(line, source: "tone")
                if score >= 0.8 { out.alert = "Raised voice" }
            } else if verdict != lastVerdict {
                lastVerdict = verdict
            }
        } else {
            out.badge = db > -42 ? "listening" : "quiet"
        }
        return out.isEmpty ? nil : out
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Fundamental frequency by autocorrelation over the speech range.
    ///
    /// Searching 70–400 Hz covers adult speech; anything outside it is noise for
    /// this purpose. The peak has to beat a fraction of the zero-lag energy or the
    /// frame is treated as unvoiced, which is what keeps breath and room noise
    /// from being reported as a 300 Hz voice.
    private func pitch(_ samples: UnsafePointer<Float>, count: Int,
                       sampleRate: Double) -> Double? {
        let minLag = Int(sampleRate / 400)
        let maxLag = min(count - 1, Int(sampleRate / 70))
        guard maxLag > minLag, minLag > 1 else { return nil }

        var zeroLag: Float = 0
        vDSP_dotpr(samples, 1, samples, 1, &zeroLag, vDSP_Length(count))
        guard zeroLag > 1e-5 else { return nil }
        // Energy per sample, so lags of different overlap lengths compare fairly.
        let zeroLagMean = zeroLag / Float(count)

        var bestLag = -1
        var bestValue: Float = 0
        for lag in minLag...maxLag {
            let overlap = count - lag
            guard overlap > 0 else { continue }
            var value: Float = 0
            vDSP_dotpr(samples, 1, samples + lag, 1, &value, vDSP_Length(overlap))
            // Divided by the overlap length. A raw autocorrelation sums over
            // `count - lag` samples, so a short lag has more terms and a larger sum
            // for the same correlation — the comparison was systematically biased
            // toward short lags, which is toward high frequencies. That pushed
            // reported pitch upward, and the agitation score keys off whether pitch
            // is above 200 Hz, so calm speech drifted toward "animated".
            let normalized = value / Float(overlap)
            if normalized > bestValue { bestValue = normalized; bestLag = lag }
        }
        guard bestLag > 0, bestValue > zeroLagMean * 0.3 else { return nil }
        let f0 = sampleRate / Double(bestLag)
        return (f0 > 70 && f0 < 400) ? f0 : nil
    }
}

// MARK: - Text classification

/// Sorting text into categories the operator defines, through the on-device model.
///
/// NaturalLanguage can only classify with a Create ML model trained in advance, so
/// this was listed as needing one. A language model does the same job zero-shot
/// from a list of category names typed into Settings, which is both more flexible
/// and available right now.
final class TextClassificationLayer: VideoAILayer {
    let id = "text.classify"
    let title = "Text classification"
    let detail = "Sorts what it hears and reads into categories you name, zero-shot."
    let group = LayerGroup.language
    let modality = LayerModality.text
    var availability: LayerAvailability {
        let llm = OnDeviceLLM.shared.status
        guard llm.isUsable else { return llm }
        if Settings.shared.live.textCategories.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsSetup("List your categories in Settings, comma separated")
        }
        return TextBus.shared.isEmpty
            ? .needsSetup("Needs text — switch on Live transcription or Scene text")
            : .available
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    /// The model answers on its own thread; `process` reads from the capture queue.
    private let lock = NSLock()
    private var inFlight = false
    private var answered = ""
    private var pending: String?

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        lock.lock()
        let ready = pending
        if ready != nil { pending = nil }
        let busy = inFlight
        lock.unlock()
        if let ready { out.lines = [ready]; out.badge = "sorted"; return out }

        let categories = Settings.shared.live.textCategories.trimmingCharacters(in: .whitespaces)
        guard !categories.isEmpty, !busy, let latest = TextBus.shared.latest,
              latest.text.count > 8, latest.text != answered else { return nil }
        answered = latest.text
        lock.lock(); inFlight = true; lock.unlock()

        OnDeviceLLM.shared.ask(
            instructions: "You assign a single category to a line of text. Reply with the category name alone and nothing else. If none of the categories fit, reply exactly: none.",
            prompt: "Categories: \(categories)\n\nText: \(latest.text)") { [weak self] result in
                guard let self else { return }
                self.lock.lock()
                self.inFlight = false
                if case .success(let label) = result {
                    let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.lowercased() != "none" {
                        self.pending = "\(clean): \(latest.text)"
                    }
                }
                self.lock.unlock()
            }
        return nil
    }
}
