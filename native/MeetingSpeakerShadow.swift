import Foundation
import CoreML
@preconcurrency import FluidAudio

@main struct MeetingSpeakerShadow {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw ShadowError.arguments }
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let models = URL(fileURLWithPath: CommandLine.arguments[2])
        let bytes = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.count <= 2_000_000 else { throw ShadowError.audio }
        let samples = bytes.withUnsafeBytes { raw -> [Float] in
            let values = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: values.count, by: 2).map { index in
                Float(Int16(bitPattern: UInt16(values[index]) | (UInt16(values[index + 1]) << 8))) / 32768
            }
        }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig(exclusiveSegments: false))
        let start = Date()
        let segmentation = try load("Segmentation.mlmodelc", from: models, units: .all)
        let fbank = try load("FBank.mlmodelc", from: models, units: .cpuOnly)
        let embedding = try load("Embedding.mlmodelc", from: models, units: .all)
        let pldaRho = try load("PldaRho.mlmodelc", from: models, units: .all)
        let psi = try loadPLDAPsi(from: models)
        manager.initialize(models: OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: pldaRho,
            pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(start)
        ))
        let inferenceStart = Date()
        let result = try await manager.process(audio: samples)
        let segments = result.segments.compactMap { segment -> [String: Any]? in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            let quality = segment.qualityScore
            guard start.isFinite, end.isFinite, end > start, quality.isFinite, quality > 0 else { return nil }
            return ["start": start, "end": end, "cluster": segment.speakerId, "quality": quality]
        }
        let payload: [String: Any] = [
            "segments": segments,
            "input_seconds": Double(samples.count) / 16000,
            "model_load_seconds": inferenceStart.timeIntervalSince(start),
            "wall_seconds": Date().timeIntervalSince(inferenceStart),
            "segment_count": segments.count,
            "local_only": true,
        ]
        let output = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }

    private static func load(_ name: String, from directory: URL, units: MLComputeUnits) throws -> MLModel {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ShadowError.model(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func loadPLDAPsi(from directory: URL) throws -> [Double] {
        let url = directory.appendingPathComponent("plda-parameters.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let tensors = root?["tensors"] as? [String: Any]
        let psi = tensors?["psi"] as? [String: Any]
        guard let encoded = psi?["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded), !decoded.isEmpty,
              decoded.count.isMultiple(of: MemoryLayout<Float>.size) else { throw ShadowError.plda }
        var values = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return values.map(Double.init)
    }

    private enum ShadowError: Error { case arguments, audio, model(String), plda }
}
