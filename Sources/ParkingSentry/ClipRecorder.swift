import AVFoundation
import CoreMedia
import UIKit

/// Saves a short video around each detection, including the seconds BEFORE the
/// trigger — by the time a subject is confirmed they have already walked into
/// frame, and the approach is the part worth seeing.
///
/// The ring holds JPEG-encoded frames, never CMSampleBuffers. Capture buffers
/// come from a small fixed pool owned by the camera; retaining six seconds of
/// them starves that pool and the system kills the app. That is exactly what
/// crashed on arming.
final class ClipRecorder {

    private let preRoll: TimeInterval = 6
    private let postRoll: TimeInterval = 8
    private let fps: Double = 12
    private let longEdge: CGFloat = 1280

    private struct Frame { let jpeg: Data; let t: TimeInterval }

    private var ring: [Frame] = []
    private let queue = DispatchQueue(label: "clip.recorder", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var recording: [Frame] = []
    private var recordingUntil: Date?
    private var currentLabel = "clip"
    private var lastAccepted: TimeInterval = -1

    var onClipFinished: ((URL) -> Void)?

    static var clipsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Called for every camera frame while armed. Encodes on a background queue
    /// and lets the capture buffer go immediately.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard t.isFinite else { return }
        // Thin to the clip frame rate before doing any work.
        guard t - lastAccepted >= (1.0 / fps) - 0.002 else { return }
        lastAccepted = t

        let ci = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, longEdge / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { return }

        let frame = Frame(jpeg: jpeg, t: t)
        queue.async { [weak self] in
            guard let self else { return }
            if self.recordingUntil != nil {
                self.recording.append(frame)
                if let until = self.recordingUntil, Date() >= until { self.write() }
                return
            }
            self.ring.append(frame)
            while let first = self.ring.first, t - first.t > self.preRoll {
                self.ring.removeFirst()
            }
        }
    }

    func trigger(label: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.recordingUntil != nil {
                // Same continuous event — extend rather than start a second file.
                self.recordingUntil = Date().addingTimeInterval(self.postRoll)
                return
            }
            self.currentLabel = label
            self.recording = self.ring
            self.ring.removeAll()
            self.recordingUntil = Date().addingTimeInterval(self.postRoll)
        }
    }

    private func write() {
        let frames = recording
        recording.removeAll()
        recordingUntil = nil
        guard frames.count > 4, let first = UIImage(data: frames[0].jpeg) else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.clipsDirectory.appendingPathComponent("\(stamp)_\(currentLabel).mp4")

        let w = Int(first.size.width / 2) * 2
        let h = Int(first.size.height / 2) * 2
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h
            ])
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)

        let base = frames[0].t
        var index = 0
        let sem = DispatchSemaphore(value: 0)
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { sem.signal(); return }
            while input.isReadyForMoreMediaData {
                guard index < frames.count else {
                    input.markAsFinished(); sem.signal(); return
                }
                let f = frames[index]; index += 1
                guard let img = UIImage(data: f.jpeg)?.cgImage,
                      let pool = adaptor.pixelBufferPool else { continue }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
                guard let dst = out else { continue }
                CVPixelBufferLockBaseAddress(dst, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(dst),
                                       width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(dst),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                CVPixelBufferUnlockBaseAddress(dst, [])
                adaptor.append(dst, withPresentationTime:
                    CMTime(seconds: max(0, f.t - base), preferredTimescale: 600))
            }
        }
        sem.wait()
        writer.finishWriting { [weak self] in
            guard writer.status == .completed else {
                print("clip write failed: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            DispatchQueue.main.async { self?.onClipFinished?(url) }
        }
    }

    static func existingClips() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: clipsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return files.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    static func prune(keeping limit: Int = 200) {
        let fm = FileManager.default
        for old in existingClips().dropFirst(limit) { try? fm.removeItem(at: old) }
    }
}
