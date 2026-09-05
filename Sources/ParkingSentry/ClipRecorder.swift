import AVFoundation
import CoreMedia
import UIKit

/// Saves a short video around each detection.
///
/// A security app that only keeps a thumbnail cannot answer the question you
/// actually have later — what happened, and what did they do. This keeps a
/// rolling buffer of recent frames in memory and, when a detection is
/// confirmed, writes out the seconds BEFORE the trigger as well as the seconds
/// after. Pre-roll is the whole point: by the time a subject is confirmed they
/// have already walked into frame, so a clip that starts at the trigger has
/// missed the approach.
final class ClipRecorder {

    /// Seconds retained before a trigger, and seconds recorded after it.
    private let preRoll: TimeInterval = 6
    private let postRoll: TimeInterval = 8

    private var ring: [(sample: CMSampleBuffer, time: CMTime)] = []
    private let queue = DispatchQueue(label: "clip.recorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingUntil: Date?
    private var sessionStarted = false
    private var currentURL: URL?

    private(set) var lastClipURL: URL?
    var onClipFinished: ((URL) -> Void)?

    static var clipsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every frame goes here whether or not anything is being recorded.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if self.recordingUntil != nil {
                self.append(sampleBuffer, at: t)
                if let until = self.recordingUntil, Date() >= until { self.finish() }
                return
            }

            // Idle: keep only the pre-roll window.
            self.ring.append((sampleBuffer, t))
            let cutoff = CMTimeSubtract(t, CMTime(seconds: self.preRoll, preferredTimescale: 600))
            while let first = self.ring.first, CMTimeCompare(first.time, cutoff) < 0 {
                self.ring.removeFirst()
            }
        }
    }

    /// A detection fired. Flush the pre-roll and keep recording for postRoll.
    func trigger(label: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.recordingUntil != nil {
                // Already recording — just extend, rather than starting a second
                // file for the same continuous event.
                self.recordingUntil = Date().addingTimeInterval(self.postRoll)
                return
            }
            guard let firstSample = self.ring.first?.sample ?? nil else { return }
            guard self.begin(like: firstSample, label: label) else { return }
            for entry in self.ring { self.append(entry.sample, at: entry.time) }
            self.ring.removeAll()
            self.recordingUntil = Date().addingTimeInterval(self.postRoll)
        }
    }

    private func begin(like sample: CMSampleBuffer, label: String) -> Bool {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.clipsDirectory
            .appendingPathComponent("\(stamp)_\(label).mp4")

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        // 720-class output: enough to identify a person or a plate at range
        // without filling the device after a busy night.
        let longEdge = max(dims.width, dims.height)
        let scale = min(1.0, 1280.0 / Double(longEdge))
        let outW = Int((Double(dims.width) * scale / 2).rounded()) * 2
        let outH = Int((Double(dims.height) * scale / 2).rounded()) * 2

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { return false }
        w.add(i)

        let a = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: i,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ])

        guard w.startWriting() else { return false }
        writer = w; input = i; adaptor = a
        currentURL = url
        sessionStarted = false
        return true
    }

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private func append(_ sample: CMSampleBuffer, at time: CMTime) {
        guard let writer, let input, let adaptor,
              let src = CMSampleBufferGetImageBuffer(sample) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let dst = out else { return }
        // Frames arrive as YUV from the capture pipeline; the writer pool is
        // BGRA, so convert rather than hand over a buffer it cannot encode.
        ciContext.render(CIImage(cvPixelBuffer: src), to: dst)
        adaptor.append(dst, withPresentationTime: time)
    }

    private func finish() {
        guard let writer, let input else { return }
        let url = currentURL
        recordingUntil = nil
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed, let url {
                self.lastClipURL = url
                DispatchQueue.main.async { self.onClipFinished?(url) }
            } else {
                print("clip write failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            self.writer = nil; self.input = nil; self.adaptor = nil
            self.currentURL = nil; self.sessionStarted = false
        }
    }

    /// Clips already on disk from previous sessions, newest first.
    static func existingClips() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: clipsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    /// Keep the folder from growing without bound: newest 200 clips survive.
    static func prune(keeping limit: Int = 200) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: clipsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(limit) { try? fm.removeItem(at: old) }
    }
}
