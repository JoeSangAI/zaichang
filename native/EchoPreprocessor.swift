import Foundation
@preconcurrency import FluidAudio

/// LocalVQE-backed echo removal for the microphone ASR branch.
///
/// The capture owner must keep and persist the original microphone bytes
/// separately. This type only produces a derived stream for ASR/diarization.
/// Both inputs are mono signed PCM16 at 16 kHz. `at` is the host uptime of the
/// first sample, in seconds, from the same monotonic clock for both sources.
/// Call `process` on one bounded serial worker and await each call in capture
/// order; never call it from an audio render callback.
enum EchoPreprocessorStatus: String, Sendable {
    case processed
    case processedWithRawEdges
    case bufferedForModelLatency
    case modelUnavailable
    case invalidInput
    case referenceMisaligned
    case timelineDiscontinuity
    case processingFailed
}

struct EchoProcessResult: Sendable {
    /// Always contains an ASR-usable microphone frame. For every bypass status,
    /// this is exactly the input microphone `Data`, without conversion.
    let audio: Data
    let captureTime: Double
    let status: EchoPreprocessorStatus
    let detail: String?

    var wasEnhanced: Bool { status == .processed || status == .processedWithRawEdges }
}

protocol EchoInferenceStream: Sendable {
    func enhance(mic:[Float],reference:[Float]) async throws -> [Float]
    func flush() async throws -> [Float]
    func reset() async throws
}
extension LocalVqeStream: EchoInferenceStream {}

actor EchoPreprocessor {
    static let sampleRate = 16_000
    static let maximumReferenceEdgeSkew = 0.010
    private static let maximumContinuityError = 0.010
    private static let minimumReferenceCoverage = 0.80

    private let stream: (any EchoInferenceStream)?
    private let unavailableDetail: String?
    private var expectedMicTime: Double?
    private var expectedReferenceTime: Double?
    private var frameCount = 0
    private var bypassCount = 0
    private var pendingRaw: [Float] = []
    private var pendingCoverage: [Bool] = []
    private var pendingStartTime: Double?

    init(stream: (any EchoInferenceStream)?, unavailableDetail: String? = nil) {
        self.stream = stream
        self.unavailableDetail = unavailableDetail
    }

    /// Load only a model that is already installed in the supplied local
    /// directory. This intentionally has no network/model-hub fallback.
    static func load(modelDirectory: URL) async -> EchoPreprocessor {
        let modelName = "localvqe-v1.3-4.8M-16ms.mlmodelc"
        let modelURL = modelDirectory.appendingPathComponent(modelName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return EchoPreprocessor(stream: nil, unavailableDetail: "model_file_missing")
        }
        do {
            let config = LocalVqeConfig(variant: .v13, chunk: .realtime16ms, computeUnits: .cpuOnly)
            let manager = try LocalVqeManager(config: config, modelDirectory: modelDirectory)
            let stream = try await manager.makeStream()
            return EchoPreprocessor(stream: stream, unavailableDetail: nil)
        } catch {
            return EchoPreprocessor(stream: nil, unavailableDetail: "model_load_failed")
        }
    }

    /// Align the playback reference onto the mic sample timeline, run AEC,
    /// and preserve mic samples at the short edges where the reference has no
    /// coverage. A larger skew or a capture discontinuity resets the recurrent
    /// model state and returns the untouched mic frame with an explicit status.
    func process(
        microphone: Data,
        at micUptime: Double,
        reference: Data,
        at referenceUptime: Double
    ) async -> EchoProcessResult {
        frameCount += 1
        guard let stream else {
            bypassCount += 1
            return EchoProcessResult(audio: microphone, captureTime: micUptime, status: .modelUnavailable,
                                     detail: unavailableDetail ?? "model_unavailable")
        }
        guard microphone.count >= 2, reference.count >= 2,
              microphone.count.isMultiple(of: 2), reference.count.isMultiple(of: 2),
              micUptime.isFinite, referenceUptime.isFinite,
              micUptime >= 0, referenceUptime >= 0 else {
            return await bypass(microphone, at: micUptime, status: .invalidInput, detail: "invalid_pcm_or_timestamp", reset: true)
        }

        let micSamples = Self.floatSamples(microphone)
        let referenceSamples = Self.floatSamples(reference)
        let plan = Self.align(reference: referenceSamples, referenceAt: referenceUptime,
                              microphoneCount: micSamples.count, microphoneAt: micUptime)
        guard plan.skew <= Self.maximumReferenceEdgeSkew,
              plan.coveredCount > 0,
              Double(plan.coveredCount) / Double(micSamples.count) >= Self.minimumReferenceCoverage else {
            return await bypass(microphone, at: micUptime, status: .referenceMisaligned, detail: "reference_time_skew_over_10ms", reset: true)
        }

        if let expectedMicTime,
           abs(micUptime - expectedMicTime) > Self.maximumContinuityError {
            return await bypass(microphone, at: micUptime, status: .timelineDiscontinuity,
                                detail: "microphone_capture_gap_over_10ms", reset: true)
        }
        if let expectedReferenceTime,
           abs(referenceUptime - expectedReferenceTime) > Self.maximumContinuityError {
            return await bypass(microphone, at: micUptime, status: .timelineDiscontinuity,
                                detail: "playback_reference_gap_over_10ms", reset: true)
        }

        do {
            if pendingStartTime == nil { pendingStartTime = micUptime }
            pendingRaw.append(contentsOf: micSamples)
            pendingCoverage.append(contentsOf: plan.covered)
            var enhanced = try await stream.enhance(mic: micSamples, reference: plan.samples)
            guard enhanced.count <= pendingRaw.count, enhanced.allSatisfy(\.isFinite) else {
                return await bypass(microphone, at: micUptime, status: .processingFailed,
                                    detail: "invalid_model_output", reset: true, currentAlreadyBuffered:true)
            }
            expectedMicTime = micUptime + Double(micSamples.count) / Double(Self.sampleRate)
            expectedReferenceTime = referenceUptime + Double(referenceSamples.count) / Double(Self.sampleRate)
            guard !enhanced.isEmpty else {
                return EchoProcessResult(audio: Data(), captureTime: pendingStartTime ?? micUptime,
                                         status: .bufferedForModelLatency, detail: nil)
            }
            let original = Array(pendingRaw.prefix(enhanced.count))
            // Where playback was outside its captured interval, keep the exact
            // original mic samples instead of asking the model to infer a ref.
            for index in original.indices where !pendingCoverage[index] {
                enhanced[index] = original[index]
            }
            let hasRawEdges = !pendingCoverage.prefix(enhanced.count).allSatisfy { $0 }
            let outputTime = pendingStartTime ?? micUptime
            pendingRaw.removeFirst(enhanced.count)
            pendingCoverage.removeFirst(enhanced.count)
            pendingStartTime = pendingRaw.isEmpty ? nil : outputTime + Double(enhanced.count) / Double(Self.sampleRate)
            return EchoProcessResult(audio: Self.pcm16(enhanced), captureTime: outputTime,
                                     status: hasRawEdges ? .processedWithRawEdges : .processed,
                                     detail: hasRawEdges ? "uncovered_reference_edges_kept_raw" : nil)
        } catch {
            return await bypass(microphone, at: micUptime, status: .processingFailed,
                                detail: "localvqe_inference_failed", reset: true, currentAlreadyBuffered:true)
        }
    }

    /// Explicitly break the model's temporal state after route changes,
    /// pauses, missing buffers, or a caller-detected discontinuity.
    @discardableResult
    func reset(reason: String) async -> EchoProcessResult? {
        let tail = await flush()
        expectedMicTime = nil
        expectedReferenceTime = nil
        if let stream { try? await stream.reset() }
        _ = reason // The caller owns reporting the reason alongside its event.
        return tail
    }

    /// Drain LocalVQE's algorithmic delay. Any residual samples that the
    /// model cannot return are emitted as original mic audio.
    func flush() async -> EchoProcessResult? {
        guard let stream, !pendingRaw.isEmpty else { return nil }
        let start = pendingStartTime ?? 0
        do {
            var enhanced = try await stream.flush()
            guard enhanced.count <= pendingRaw.count, enhanced.allSatisfy(\.isFinite) else {
                let raw = Self.pcm16(pendingRaw)
                clearPending()
                expectedMicTime = nil
                expectedReferenceTime = nil
                return EchoProcessResult(audio: raw, captureTime: start, status: .processingFailed,
                                         detail: "invalid_flush_output_raw_preserved")
            }
            var rawEdges = false
            for index in enhanced.indices where !pendingCoverage[index] {
                enhanced[index] = pendingRaw[index]
                rawEdges = true
            }
            if enhanced.count < pendingRaw.count {
                enhanced.append(contentsOf: pendingRaw.dropFirst(enhanced.count))
                rawEdges = true
            }
            clearPending()
            expectedMicTime = nil
            expectedReferenceTime = nil
            return EchoProcessResult(audio: Self.pcm16(enhanced), captureTime: start,
                                     status: rawEdges ? .processedWithRawEdges : .processed,
                                     detail: rawEdges ? "flush_tail_kept_raw" : nil)
        } catch {
            let raw = Self.pcm16(pendingRaw)
            clearPending()
            expectedMicTime = nil
            expectedReferenceTime = nil
            return EchoProcessResult(audio: raw, captureTime: start, status: .processingFailed,
                                     detail: "flush_failed_raw_preserved")
        }
    }

    func diagnostics() -> [String: Any] {
        ["echo_model_available": stream != nil,
         "echo_processed_frames": frameCount - bypassCount,
         "echo_bypassed_frames": bypassCount]
    }

    private func bypass(
        _ microphone: Data,
        at time: Double,
        status: EchoPreprocessorStatus,
        detail: String,
        reset: Bool,
        currentAlreadyBuffered: Bool = false
    ) async -> EchoProcessResult {
        bypassCount += 1
        var result = pendingRaw
        let outputTime = pendingStartTime ?? time
        if !currentAlreadyBuffered && microphone.count.isMultiple(of: 2) {
            result.append(contentsOf: Self.floatSamples(microphone))
        } else if result.isEmpty {
            return EchoProcessResult(audio: microphone, captureTime: time, status: status, detail: detail)
        }
        if reset {
            expectedMicTime = nil
            expectedReferenceTime = nil
            if let stream { try? await stream.reset() }
        }
        clearPending()
        return EchoProcessResult(audio: Self.pcm16(result), captureTime: outputTime, status: status, detail: detail)
    }

    private func clearPending() {
        pendingRaw.removeAll(keepingCapacity: true)
        pendingCoverage.removeAll(keepingCapacity: true)
        pendingStartTime = nil
    }

    private struct Alignment {
        let samples: [Float]
        let covered: [Bool]
        let coveredCount: Int
        let skew: Double
    }

    private static func align(
        reference: [Float],
        referenceAt: Double,
        microphoneCount: Int,
        microphoneAt: Double
    ) -> Alignment {
        var aligned = [Float](repeating: 0, count: microphoneCount)
        var covered = [Bool](repeating: false, count: microphoneCount)
        let skew = abs(referenceAt - microphoneAt)
        var coveredCount = 0
        for i in 0..<microphoneCount {
            let sampleTime = microphoneAt + Double(i) / Double(sampleRate)
            let relative = (sampleTime - referenceAt) * Double(sampleRate)
            // Absolute uptime seconds can round a shared final sample a few
            // ulps beyond the buffer edge. Clamp that numerical noise instead
            // of marking one false raw-mic edge on every callback.
            let edgeEpsilon = 1e-6
            guard relative >= -edgeEpsilon,
                  relative <= Double(reference.count - 1) + edgeEpsilon else { continue }
            let clamped = min(Double(reference.count - 1), max(0, relative))
            let low = Int(clamped.rounded(.down))
            let high = min(low + 1, reference.count - 1)
            let fraction = Float(clamped - Double(low))
            aligned[i] = reference[low] + (reference[high] - reference[low]) * fraction
            covered[i] = true
            coveredCount += 1
        }
        return Alignment(samples: aligned, covered: covered, coveredCount: coveredCount, skew: skew)
    }

    private static func floatSamples(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return samples.map { Float($0) / 32768.0 }
        }
    }

    private static func pcm16(_ samples: [Float]) -> Data {
        var output = Data(count: samples.count * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: Int16.self)
            for index in samples.indices {
                let value = max(-1.0, min(0.9999695, samples[index]))
                target[index] = Int16((value * 32768.0).rounded())
            }
        }
        return output
    }
}
