import Foundation
import CryptoKit
#if canImport(SherpaC)
import SherpaC
#endif
enum EmbeddingError:Error {case unavailable,invalidModel,invalidPCM,unreliableSegment,invalidVector}
struct EmbeddingVector:Codable {
    let values:[Float];let partition:String;let inputKind:String
}
// The owning SpeakerPipeline actor serializes all calls. No enrollment/file I/O here.
final class SpeakerEmbeddingBackend {
    static let modelHash="f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"
    static let partition="campplus:"+modelHash+":192"
    #if canImport(SherpaC)
    private var extractor:OpaquePointer?
    #endif
    init(model:URL) throws {
        let data=try Data(contentsOf:model,options:.mappedIfSafe)
        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==Self.modelHash else{throw EmbeddingError.invalidModel}
        #if canImport(SherpaC)
        guard let version=SherpaOnnxGetVersionStr(),["1.13.8","v1.13.8"].contains(String(cString:version)) else{throw EmbeddingError.invalidModel}
        extractor=model.path.withCString { path in "cpu".withCString { provider in
            var config=SherpaOnnxSpeakerEmbeddingExtractorConfig(model:path,num_threads:1,debug:0,provider:provider)
            return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
        }}
        guard let value=extractor else{throw EmbeddingError.unavailable}
        guard SherpaOnnxSpeakerEmbeddingExtractorDim(value)==192 else{close();throw EmbeddingError.invalidVector}
        #else
        throw EmbeddingError.unavailable
        #endif
    }
    func extract(_ samples:[Float],qualityOK:Bool,overlap:Bool,inputKind:String) throws->EmbeddingVector {
        guard qualityOK,!overlap else{throw EmbeddingError.unreliableSegment}
        guard (32000...64000).contains(samples.count),samples.allSatisfy({$0.isFinite && abs($0)<=1}),["synthetic_model_output","consented_live_audio"].contains(inputKind) else{throw EmbeddingError.invalidPCM}
        #if canImport(SherpaC)
        guard let extractor=extractor,let stream=SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else{throw EmbeddingError.unavailable}
        defer{SherpaOnnxDestroyOnlineStream(stream)}
        samples.withUnsafeBufferPointer {buffer in SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,buffer.baseAddress,Int32(buffer.count))}
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor,stream)==1,let value=SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor,stream) else{throw EmbeddingError.invalidVector}
        defer{SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(value)}
        let raw=Array(UnsafeBufferPointer(start:value,count:192))
        guard raw.allSatisfy({$0.isFinite}) else{throw EmbeddingError.invalidVector}
        let norm=sqrt(raw.reduce(0.0){$0+Double($1)*Double($1)})
        guard norm.isFinite,norm>1e-12 else{throw EmbeddingError.invalidVector}
        return EmbeddingVector(values:raw.map{Float(Double($0)/norm)},partition:Self.partition,inputKind:inputKind)
        #else
        throw EmbeddingError.unavailable
        #endif
    }
    func close() {
        #if canImport(SherpaC)
        if let value=extractor {extractor=nil;SherpaOnnxDestroySpeakerEmbeddingExtractor(value)}
        #endif
    }
    deinit{close()}
}
