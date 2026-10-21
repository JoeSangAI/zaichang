import Foundation

struct OfflineSpeakerSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let speakerID: String
}

enum OfflineSpeakerBackendError: Error {
    case unavailable
    case invalidAudio
    case missingModel(String)
    case invalidPLDAParameters
}

#if canImport(CoreML) && canImport(FluidAudio)
@preconcurrency import CoreML
@preconcurrency import FluidAudio

@available(macOS 14.0, *)
actor OfflineSpeakerBackend {
    private let modelsDirectory: URL
    private let computeUnits: MLComputeUnits
    private var manager: OfflineDiarizerManager?

    init(modelsDirectory: URL, computeUnits: MLComputeUnits = .all) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.computeUnits = computeUnits
    }

    /// Diarize one completed 16 kHz mono track. The caller owns audio decoding and persistence.
    /// The returned speaker IDs are local to this track and this pass.
    func diarize(samples: [Float]) async throws -> [OfflineSpeakerSegment] {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw OfflineSpeakerBackendError.invalidAudio
        }
        let activeManager: OfflineDiarizerManager
        if let manager {
            activeManager = manager
        } else {
            activeManager = try loadManager()
            manager = activeManager
        }

        let result: DiarizationResult
        do {
            result = try await activeManager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
        return result.segments.compactMap { segment in
            let quality = segment.qualityScore
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard quality.isFinite, quality > 0,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return OfflineSpeakerSegment(
                start: start,
                end: end,
                speakerID: segment.speakerId
            )
        }
    }

    private func loadManager() throws -> OfflineDiarizerManager {
        let configuration = OfflineDiarizerConfig(exclusiveSegments: false)
        let manager = OfflineDiarizerManager(config: configuration)
        let start = Date()
        let segmentation = try loadModel("Segmentation.mlmodelc", computeUnits: computeUnits)
        let fbank = try loadModel("FBank.mlmodelc", computeUnits: .cpuOnly)
        let embedding = try loadModel("Embedding.mlmodelc", computeUnits: computeUnits)
        let pldaRho = try loadModel("PldaRho.mlmodelc", computeUnits: computeUnits)
        let psi = try loadPLDAPsi()
        let models = OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: pldaRho,
            pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(start)
        )
        manager.initialize(models: models)
        return manager
    }

    private func loadModel(_ name: String, computeUnits: MLComputeUnits) throws -> MLModel {
        let url = modelsDirectory.appendingPathComponent(name, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OfflineSpeakerBackendError.missingModel(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private func loadPLDAPsi() throws -> [Double] {
        let url = modelsDirectory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded),
              !decoded.isEmpty,
              decoded.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw OfflineSpeakerBackendError.invalidPLDAParameters
        }
        var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { destination in
            decoded.copyBytes(to: destination)
        }
        return floats.map(Double.init)
    }
}
#else
actor OfflineSpeakerBackend {
    init(modelsDirectory: URL) {}

    func diarize(samples: [Float]) async throws -> [OfflineSpeakerSegment] {
        throw OfflineSpeakerBackendError.unavailable
    }
}
#endif
