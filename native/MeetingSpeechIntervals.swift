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
    private func window(source:String,start:Double,end:Double,audio:MeetingAcousticRefinement.Audio)throws->Window? {
        guard end>start,end-start<=4,let bounds=audio.bounds(audio.voiceSource(source)) else{return nil}
        let center=(start+end)/2,offset=max(0,floor((center-bounds.0)/5)*5-2.5),lo=bounds.0+offset,hi=min(bounds.1,lo+10)
        guard lo<=start,hi>=end,hi>lo else{return nil}
        let key=source+":"+String(offset),window:Window
        if let saved=cache[key] {window=saved} else {
            let pcm=try audio.window(audio.voiceSource(source),lo,hi)
            let array=try MLMultiArray(shape:[1,1,160000],dataType:.float32)
            let pointer=array.dataPointer.assumingMemoryBound(to:Float.self)
            pointer.update(repeating:0,count:160000)
            let peak=pcm.reduce(Float(0)){max($0,abs($1))}
            let gain=min(Float(16),max(Float(1),0.8/max(peak,0.000001)))
            for i in pcm.indices {pointer[i]=pcm[i]*gain}
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
        return window
    }
    func solo(source:String,start:Double,end:Double,audio:MeetingAcousticRefinement.Audio)throws->(Double,Double)? {
        guard let window=try window(source:source,start:start,end:end,audio:audio),
              let bounds=audio.bounds(audio.voiceSource(source)) else{return nil}
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

    /// Match a short fragment to independently labelled speech in the SAME
    /// model window. Window slots never escape this window or cross sources.
    /// Silence is allowed at word edges; a competing or overlapping voice is
    /// not. Recovered fragments never become references for another recovery.
    func continuation(source:String,start:Double,end:Double,references:[MeetingAcousticRefinement.Unit],audio:MeetingAcousticRefinement.Audio)throws->SessionSpeakerKey? {
        guard end-start<=4,let window=try window(source:source,start:start,end:end,audio:audio) else{return nil}
        func label(_ lo:Double,_ hi:Double)->(Int,Double)? {
            guard lo>=window.start,hi<=window.start+Double(window.labels.count)*window.step,hi>lo else{return nil}
            let first=max(0,Int(floor((lo-window.start)/window.step))),last=min(window.labels.count-1,Int(ceil((hi-window.start)/window.step))-1)
            guard first<=last else{return nil}
            var voices:[Int:Double]=[:],uncertain=0.0,overlap=0.0
            for i in first...last {
                let seconds=max(0,min(hi,window.start+Double(i+1)*window.step)-max(lo,window.start+Double(i)*window.step))
                let value=window.labels[i]
                if (1...3).contains(value) {voices[value,default:0]+=seconds}
                else if value>=4 {overlap+=seconds}
                else if value<0 {uncertain+=seconds}
            }
            guard overlap<=min(0.02,(hi-lo)*0.1),uncertain<=min(0.08,(hi-lo)*0.2),voices.count==1,
                  let voice=voices.first,voice.value>=max(0.04,(hi-lo)*0.5) else{return nil}
            return (voice.key,voice.value)
        }
        guard let target=label(start,end) else{return nil}
        var support:[SessionSpeakerKey:Double]=[:]
        for ref in references where ref.source==source && (ref.end<=start || ref.start>=end) {
            guard let key=ref.key,max(start-ref.end,ref.start-end)<=3 else{continue}
            let lo=max(ref.start,window.start),hi=min(ref.end,window.start+Double(window.labels.count)*window.step)
            guard hi-lo>=0.4,let voice=label(lo,hi),voice.0==target.0 else{continue}
            support[key,default:0]+=voice.1
        }
        guard support.count==1,let best=support.first,best.value>=0.6 else{return nil}
        return best.key
    }
}
