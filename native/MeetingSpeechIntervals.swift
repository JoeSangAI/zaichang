import Foundation
import CoreML
import CryptoKit

/// Independent community-1 powerset segmentation for disputed short speech.
/// Ten-second windows, twelve cached results; no global speaker naming here.
final class MeetingSpeechIntervals {
    static let modelID="community1-seg:c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"
    struct Window {let start:Double;let step:Double;let labels:[Int]}
    private let model:MLModel
    private var cache:[String:Window]=[:],order:[String]=[]
    private(set) var predictions=0
    init(directory:URL)throws {
        let expected=["weights/weight.bin":"c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2",
                      "model.mil":"d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f",
                      "coremldata.bin":"ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"]
        for (name,hash) in expected {
            let bytes=try SpeakerRefinement.read(directory.appendingPathComponent(name),limit:16*1024*1024)
            guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==hash else{throw Failure(code:"acoustic_segmentation_model_invalid")}
        }
        let config=MLModelConfiguration();config.computeUnits = .cpuAndNeuralEngine
        model=try MLModel(contentsOf:directory,configuration:config)
    }
    func solo(source:String,start:Double,end:Double,audio:MeetingAcousticRefinement.Audio)throws->(Double,Double)? {
        guard end>start,end-start<=4,let bounds=audio.bounds(audio.voiceSource(source)) else{return nil}
        let center=(start+end)/2,offset=max(0,floor((center-bounds.0)/5)*5-2.5),lo=bounds.0+offset,hi=min(bounds.1,lo+10)
        guard lo<=start,hi>=end,hi>lo else{return nil}
        let key=source+":"+String(offset),window:Window
        if let saved=cache[key] {window=saved} else {
            let pcm=try audio.window(audio.voiceSource(source),lo,hi)
            let array=try MLMultiArray(shape:[1,1,160000],dataType:.float32)
            let pointer=array.dataPointer.assumingMemoryBound(to:Float.self)
            pointer.update(repeating:0,count:160000)
            pcm.withUnsafeBufferPointer{if let base=$0.baseAddress {pointer.update(from:base,count:pcm.count)}}
            let input=try MLDictionaryFeatureProvider(dictionary:["audio":MLFeatureValue(multiArray:array)])
            let output=try model.prediction(from:input)
            guard let values=output.featureValue(for:"log_probs")?.multiArrayValue else{throw Failure(code:"acoustic_segmentation_output_invalid")}
            let shape=values.shape.map(\.intValue)
            guard shape.count==3,shape[0]==1,(100...1000).contains(shape[1]),(7...8).contains(shape[2]) else{throw Failure(code:"acoustic_segmentation_output_invalid")}
            var labels:[Int]=[]
            for frame in 0..<shape[1] {
                let logits=(0..<shape[2]).map{values[[0,NSNumber(value:frame),NSNumber(value:$0)]].doubleValue}
                guard logits.allSatisfy(\.isFinite),let best=logits.indices.max(by:{logits[$0]<logits[$1]}) else{throw Failure(code:"acoustic_segmentation_output_invalid")}
                let confidence=1/logits.reduce(0.0){$0+exp($1-logits[best])}
                labels.append(confidence>=0.6 ? best:-1)
            }
            window=Window(start:lo,step:10/Double(shape[1]),labels:labels);predictions+=1
            if order.count>=12 {cache.removeValue(forKey:order.removeFirst())}
            cache[key]=window;order.append(key)
        }
        let first=max(0,Int(floor((start-window.start)/window.step))),last=min(window.labels.count-1,Int(ceil((end-window.start)/window.step))-1)
        guard first<=last else{return nil}
        var solo:[Int:Double]=[:],overlap=0.0,uncertain=0.0
        for i in first...last {
            let seconds=max(0,min(end,window.start+Double(i+1)*window.step)-max(start,window.start+Double(i)*window.step)),label=window.labels[i]
            if (1...3).contains(label) {solo[label,default:0]+=seconds}
            else if label>=4 {overlap+=seconds}
            else if label<0 {uncertain+=seconds}
        }
        // Model frames near a voiced boundary can be uncertain. Bound that
        // tolerance by both utterance duration and 80 ms, rather than rejecting
        // a clear 1–4 second solo turn for one extra boundary frame. The overlap
        // and competing-speaker gates remain independent.
        let uncertainLimit=max(0.04,min(0.08,(end-start)*0.05))
        guard overlap<=0.02,uncertain<=uncertainLimit,solo.count==1,let speaker=solo.first,speaker.value/(end-start)>=0.7,
              let pivot=(first...last).first(where:{window.labels[$0]==speaker.key}) else{return nil}
        var left=pivot,right=pivot
        while left>0,window.labels[left-1]==speaker.key {left-=1}
        while right+1<window.labels.count,window.labels[right+1]==speaker.key {right+=1}
        let a=window.start+Double(left)*window.step,b=min(bounds.1,window.start+Double(right+1)*window.step)
        guard max(0,min(end,b)-max(start,a))/(end-start)>=0.7,b-a>=0.4 else{return nil}
        return (a,b)
    }
}
