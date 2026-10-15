import Foundation
import AVFoundation
import Accelerate
import CoreVideo
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

struct GemxFrame {
    let index: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: UnsafeMutablePointer<UInt8>

    func makePixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            nil, width, height, kCVPixelFormatType_32BGRA, data, bytesPerRow, nil, nil, nil, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }
}

final class GemxVideoReader {
    struct Info {
        let width: Int
        let height: Int
        let fps: Double
        let estimatedFrames: Int
    }

    enum ReaderError: Error, CustomStringConvertible {
        case noVideoTrack
        case cannotRead(String)
        var description: String {
            switch self {
            case .noVideoTrack: return "video has no video track"
            case .cannotRead(let s): return "cannot read video: \(s)"
            }
        }
    }

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    let info: Info
    private let rotation: Int
    private let storedWidth: Int
    private let storedHeight: Int

    init(url: URL, maxSide: Int) async throws {
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReaderError.noVideoTrack
        }
        track = t
        let (natural, transform, fps, duration, formats) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .formatDescriptions)

        if let fd = formats.first {
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            storedWidth = Int(dims.width); storedHeight = Int(dims.height)
        } else {
            storedWidth = Int(natural.width.rounded()); storedHeight = Int(natural.height.rounded())
        }
        rotation = Self.quarterTurns(transform)
        let (rw, rh) = rotation % 2 == 0 ? (storedWidth, storedHeight) : (storedHeight, storedWidth)
        let s = min(1.0, Double(maxSide) / Double(max(rw, rh)))
        let w = s < 1 ? Int((Double(rw) * s).rounded()) : rw
        let h = s < 1 ? Int((Double(rh) * s).rounded()) : rh
        let f = Double(fps) > 0 ? Double(fps) : 30
        info = Info(width: w, height: h, fps: f, estimatedFrames: Int((duration.duration.seconds * f).rounded()))
    }

    static func quarterTurns(_ t: CGAffineTransform) -> Int {
        if t.b == 1 && t.c == -1 { return 1 }
        if t.a == -1 && t.d == -1 { return 2 }
        if t.b == -1 && t.c == 1 { return 3 }
        return 0
    }

    @discardableResult
    func forEachFrame(wanted: ((Int) -> Bool)? = nil, _ body: (GemxFrame) throws -> Bool) throws -> Int {
        let (rw, rh) = rotation % 2 == 0 ? (storedWidth, storedHeight) : (storedHeight, storedWidth)
        let needsRotate = rotation != 0
        let needsScale = info.width != rw || info.height != rh

        let rotatedBuf = needsRotate ? UnsafeMutablePointer<UInt8>.allocate(capacity: rw * rh * 4) : nil
        let outRowBytes = info.width * 4
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outRowBytes * info.height)
        defer { rotatedBuf?.deallocate(); outBuf.deallocate() }

        var count = 0
        var stop = false
        var lastPTS: CMTime? = nil
        var restarts = 0
        while true {
            let (reader, output) = try startReader(from: lastPTS)
            while !stop, let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let l = lastPTS, pts <= l { continue }
                lastPTS = pts
                let index = count
                count += 1
                if let wanted, !wanted(index) { continue }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
                var src = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                        width: vImagePixelCount(CVPixelBufferGetWidth(pb)),
                                        rowBytes: CVPixelBufferGetBytesPerRow(pb))
                var rotated = vImage_Buffer(data: rotatedBuf, height: vImagePixelCount(rh), width: vImagePixelCount(rw), rowBytes: rw * 4)
                var cur = src
                if needsRotate, rotatedBuf != nil {
                    var bg: [UInt8] = [0, 0, 0, 255]
                    let k: UInt8 = rotation == 1 ? UInt8(kRotate90DegreesClockwise)
                                 : rotation == 2 ? UInt8(kRotate180DegreesClockwise) : UInt8(kRotate270DegreesClockwise)
                    vImageRotate90_ARGB8888(&src, &rotated, k, &bg, vImage_Flags(kvImageNoFlags))
                    cur = rotated
                }
                var dst = vImage_Buffer(data: outBuf, height: vImagePixelCount(info.height), width: vImagePixelCount(info.width), rowBytes: outRowBytes)
                if needsScale {
                    vImageScale_ARGB8888(&cur, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
                } else {
                    vImageCopyBuffer(&cur, &dst, 4, vImage_Flags(kvImageNoFlags))
                }
                let frame = GemxFrame(index: index, width: info.width, height: info.height, bytesPerRow: outRowBytes, data: outBuf)
                stop = try !body(frame)
            }
            if stop || reader.status != .failed {
                reader.cancelReading()
                return count
            }
            let err = reader.error
            guard Self.isInterruption(err), restarts < 5 else {
                throw ReaderError.cannotRead(err?.localizedDescription ?? "decode failed")
            }
            restarts += 1
            NSLog("[GemxVideo] decode interrupted after frame %d (%@); waiting for the app to resume (restart %d)",
                  count, err?.localizedDescription ?? "?", restarts)
            Self.waitUntilActive()
        }
    }

    private static func isInterruption(_ error: Error?) -> Bool {

        if let e = error as NSError?, e.domain == AVFoundationErrorDomain, [-11847, -11819].contains(e.code) {
            return true
        }
        #if canImport(UIKit)
        return !appIsActive()
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    private static func appIsActive() -> Bool {
        let check: () -> Bool = { MainActor.assumeIsolated { UIApplication.shared.applicationState == .active } }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }
    #endif

    private static func waitUntilActive() {
        #if canImport(UIKit)
        let deadline = Date().addingTimeInterval(15 * 60)
        while !appIsActive(), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 0.5)
        #else
        Thread.sleep(forTimeInterval: 1)
        #endif
    }

    private func startReader(from start: CMTime? = nil) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ReaderError.cannotRead(error.localizedDescription) }
        if let start, start.isValid, start > .zero {
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReaderError.cannotRead("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ReaderError.cannotRead(reader.error?.localizedDescription ?? "startReading failed")
        }
        return (reader, output)
    }
}

enum GemxDetector {
    enum Mode { case bodyPose, humanRectangle, union }
    nonisolated(unsafe) static var mode: Mode = .humanRectangle

    nonisolated(unsafe) static var margins: (top: Float, bottom: Float, side: Float) = (0.12, 0.06, 0.04)
    static let minConfidence: Float = 0.25

    static func largestPerson(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, width: Int, height: Int) -> SIMD4<Float>? {
        switch mode {
        case .bodyPose:       return fromBodyPose(pixelBuffer, orientation, width, height) ?? fromHumanRectangle(pixelBuffer, orientation, width, height)
        case .humanRectangle: return fromHumanRectangle(pixelBuffer, orientation, width, height) ?? fromBodyPose(pixelBuffer, orientation, width, height)
        case .union:

            let a = fromBodyPose(pixelBuffer, orientation, width, height), b = fromHumanRectangle(pixelBuffer, orientation, width, height)
            guard let a else { return b }
            guard let b else { return a }
            return SIMD4<Float>(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w))
        }
    }

    static func largestPerson(_ frame: GemxFrame) -> SIMD4<Float>? {
        guard let pb = frame.makePixelBuffer() else { return nil }
        return largestPerson(pb, orientation: .up, width: frame.width, height: frame.height)
    }

    static func fromBodyPose(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ width: Int, _ height: Int) -> SIMD4<Float>? {
        let req = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let results = req.results, !results.isEmpty else { return nil }
        let W = Float(width), H = Float(height)
        var best: SIMD4<Float>? = nil
        var bestArea: Float = -1
        for obs in results {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
            var n = 0
            for (_, p) in pts where p.confidence >= minConfidence {
                let x = Float(p.location.x) * W, y = (1 - Float(p.location.y)) * H
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); n += 1
            }
            guard n >= 6, maxY > minY else { continue }
            let h = maxY - minY
            let box = SIMD4<Float>(minX - margins.side * h, minY - margins.top * h, maxX + margins.side * h, maxY + margins.bottom * h)
            let area = (box.z - box.x) * (box.w - box.y)
            if area > bestArea { bestArea = area; best = box }
        }
        return best
    }

    static func fromHumanRectangle(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ width: Int, _ height: Int) -> SIMD4<Float>? {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let results = req.results, !results.isEmpty else { return nil }
        let W = Float(width), H = Float(height)
        var best: SIMD4<Float>? = nil
        var bestArea: Float = -1
        for r in results {
            let bb = r.boundingBox
            let x1 = Float(bb.minX) * W, x2 = Float(bb.maxX) * W
            let y1 = (1 - Float(bb.maxY)) * H, y2 = (1 - Float(bb.minY)) * H
            let area = (x2 - x1) * (y2 - y1)
            if area > bestArea { bestArea = area; best = SIMD4<Float>(x1, y1, x2, y2) }
        }
        return best
    }
}
