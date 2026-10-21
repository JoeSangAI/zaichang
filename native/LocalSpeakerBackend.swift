import Foundation
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif
struct SpeakerFrame:Codable {let sourceID:String;let epoch:String;let revision:Int;let start:Double;let end:Double;let activeSlots:[Int]}
enum SpeakerBackendError:Error {case modelUnavailable,invalidPCM,nonContiguousClock,closed}
actor LocalSpeakerBackend {
    let sourceID:String;let epoch:String;let origin:Double
    var sampleCursor=0;var frameCursor=0;var revision=0
    #if canImport(FluidAudio)
    var diarizer:Nemotron3Diarizer?
    #endif
    init(sourceID:String,epoch:String,origin:Double) {self.sourceID=sourceID;self.epoch=epoch;self.origin=origin}
    func loadLocal(directory:URL,longContext:Bool=false) async throws {
        guard FileManager.default.fileExists(atPath:directory.path) else {throw SpeakerBackendError.modelUnavailable}
        #if canImport(FluidAudio)
        let config=longContext ? Nemotron3Config.fast128:Nemotron3Config.low
        let models=try await Nemotron3Models.load(config:config,directory:directory)
        diarizer=Nemotron3Diarizer(config:config,models:models);diarizer?.reset()
        #else
        throw SpeakerBackendError.modelUnavailable
        #endif
    }
    func append(_ samples:[Float],startSample:Int,threshold:Float) throws -> [SpeakerFrame] {
        guard startSample==sampleCursor else {throw SpeakerBackendError.nonContiguousClock}
        guard samples.allSatisfy({$0.isFinite}),threshold>0 && threshold<1 else {throw SpeakerBackendError.invalidPCM}
        #if canImport(FluidAudio)
        guard let diarizer=diarizer else {throw SpeakerBackendError.modelUnavailable}
        diarizer.appendAudio(samples);sampleCursor+=samples.count
        return try diarizer.processBufferedAudio().flatMap{ frames($0.probabilities,threshold:threshold) }
        #else
        throw SpeakerBackendError.modelUnavailable
        #endif
    }
    func warmSyntheticSilence() throws {
        #if canImport(FluidAudio)
        guard let diarizer=diarizer else {throw SpeakerBackendError.modelUnavailable}
        diarizer.appendAudio([Float](repeating:0,count:32000))
        _ = try diarizer.processBufferedAudio()
        diarizer.reset() // No synthetic cursor or speaker state enters the real session.
        #else
        throw SpeakerBackendError.modelUnavailable
        #endif
    }
    func finish(threshold:Float) throws->[SpeakerFrame] {
        guard threshold>0 && threshold<1 else {throw SpeakerBackendError.invalidPCM}
        #if canImport(FluidAudio)
        guard let diarizer=diarizer else {throw SpeakerBackendError.modelUnavailable}
        return try diarizer.finishStream().flatMap{frames($0.probabilities,threshold:threshold)}
        #else
        throw SpeakerBackendError.modelUnavailable
        #endif
    }
    func release() {
        #if canImport(FluidAudio)
        diarizer=nil
        #endif
    }
    private func frames(_ values:[Float],threshold:Float)->[SpeakerFrame] {
        var output:[SpeakerFrame]=[];revision+=1
        // CoreML padding may emit one extra frame; never extend beyond received PCM.
        let remaining=max(0,(sampleCursor+159)/160-frameCursor)
        for frame in 0..<min(values.count/8,remaining) {
            let slots=(0..<8).filter{values[frame*8+$0]>=threshold}
            let start=origin+Double(frameCursor)*0.01;frameCursor+=1
            output.append(SpeakerFrame(sourceID:sourceID,epoch:epoch,revision:revision,start:start,end:start+0.01,activeSlots:slots))
        }
        return output
    }
}
