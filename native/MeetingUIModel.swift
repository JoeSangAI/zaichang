import Foundation
import CryptoKit
struct CredentialInput {
    let raw:String
    var normalized:String {raw.trimmingCharacters(in:.whitespacesAndNewlines)}
    var issue:String? {
        if normalized.isEmpty {return "请粘贴API密钥"}
        if normalized.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)}) {return "密钥中有空格或换行，请重新复制"}
        return nil
    }
    var count:Int {normalized.count}
    var trimmed:Bool {normalized != raw}
}
final class MockVault {
    var bytes:Data?
    var failNext=false
    func save(_ value:String)throws {if failNext {failNext=false;throw NSError(domain:"fixture",code:1)};bytes=Data(value.utf8)}
    func load()->String? {bytes.flatMap{String(data:$0,encoding:.utf8)}}
}
enum RecordingPhase:String {case idle,connecting,recording,paused,stopping,stopped,failed,ended}
struct UIState {
    var phase:RecordingPhase = .idle
    var error:String?
    var elapsed=0.0
    var estimated=0.0
    var transcript:[String:String]=[:]
    var order:[String]=[]
    mutating func start()->Bool {
        guard [.idle,.stopped,.failed].contains(phase) else {return false}
        phase = .connecting;error=nil;elapsed=0;estimated=0;transcript=[:];order=[];return true
    }
    mutating func stop()->Bool {
        guard [.connecting,.recording,.paused].contains(phase) else {return false}
        phase = .stopping;return true
    }
    mutating func text(id:String,value:String) {if transcript[id]==nil {order.append(id)};transcript[id]=value}
    var time:String {String(format:"%02d:%02d",Int(elapsed)/60,Int(elapsed)%60)}
    var price:String {estimated>0 && estimated<0.01 ? "<¥0.01" : "¥"+groupedDecimal(String(format:"%.2f",estimated))}
}
struct ManualRunOverride {
    let id:String
    let start:Double
    let end:Double
    let text:String
}
enum SessionNameOrigin:String {case manual,voiceprint,semantic}
struct SessionDisplayName {
    let value:String;let origin:SessionNameOrigin
    var visibleValue:String {value}
}
struct SessionAutoName:Codable,Equatable {
    let key:SessionSpeakerKey;let personID:String;let name:String;let archiveRevision:Int
    let support:[VoiceprintEvidenceRef]
    var recognizedSupport:[VoiceprintEvidenceRef]?=nil
}
struct SessionVoiceConfirmation:Codable,Equatable {
    let id:String;let session:String;let name:String;let person:SharedPersonReference?
    let segmentIDs:[String];let createdAt:String
}
struct SessionNames {
    private struct RunAnchor:Codable {
        let id:String;let parent:String;let session:String;let source:String;let epoch:String
        let start:Double;let end:Double;let textSHA256:String
    }
    private var speakerOrder:[SessionSpeakerKey]=[]
    var registeredSpeakerCount:Int {speakerOrder.count}
    private var sentenceNames:[String:String]=[:];private var speakerNames:[SessionSpeakerKey:String]=[:]
    private var semanticNames:[SessionSpeakerKey:SessionSemanticName]=[:];private var semanticMatcher=LocalSemanticNames()
    private var autoNames:[SessionSpeakerKey:SessionAutoName]=[:];private var voiceSuggestions:[SessionSpeakerKey:SessionAutoName]=[:];private var autoSuppressed:Set<SessionSpeakerKey>=[]
    private var correctedBindings:Set<String>=[];private var bindings:[String:SessionSpeakerKey]=[:];private var aliases:[SessionSpeakerKey:SessionSpeakerKey]=[:];private var sessions:[String:String]=[:]
    private var validatedVoiceRevisions:[String:Int]=[:]
    private var segmentRevisions:[String:Int]=[:]
    private var runAnchors:[String:RunAnchor]=[:]
    private var anchorsByParent:[String:Set<String>]=[:]
    private(set) var correctionRevision=0
    private(set) var restoredAutoNameInvalidated=false
    private(set) var lastUndoSegmentIDs:[String]=[]
    private indirect enum Change:Codable {
        case sentence(String,String?)
        case speaker(String,SessionSpeakerKey,String?,String?,[String:Bool])
        case speakerGroup(SessionSpeakerKey,String?,[String:String?],[String:Bool])
        case assignment(String,SessionSpeakerKey?,String?,SessionSpeakerKey,String?,Bool)
        case merge(SessionSpeakerKey,SessionSpeakerKey?,String?,String?,SessionSpeakerKey)
        case batch([Change])
        case identityMetadata([String:SharedPersonReference],[SessionVoiceConfirmation])
    }
    private var personReferences:[String:SharedPersonReference]=[:]
    private(set) var voiceConfirmations:[SessionVoiceConfirmation]=[]
    private var undoStack:[Change]=[]
    func personReference(segment:String)->SharedPersonReference? {
        guard let ref=personReferences[segment],name(segment:segment)==ref.name else{return nil};return ref
    }
    func segmentIDs(for key:SessionSpeakerKey)->[String] {bindings.keys.filter{self.key(segment:$0)==canonical(key)}.sorted()}
    mutating func attachConfirmation(segmentIDs:[String],name:String,person:SharedPersonReference?=nil,learn:Bool=true) {
        let ids=Array(Set(segmentIDs)).sorted()
        guard !ids.isEmpty,ids.count<=4096,let session=ids.first.flatMap({sessions[$0]}),
              ids.allSatisfy({sessions[$0]==session && self.name(segment:$0)==name}) else{return}
        if let person,person.name==name,(try? person.validated()) != nil {for id in ids {personReferences[id]=person}}
        guard learn,voiceConfirmations.count<128 else{return}
        voiceConfirmations.append(SessionVoiceConfirmation(id:UUID().uuidString,session:session,name:name,person:person,segmentIDs:ids,createdAt:ISO8601DateFormatter().string(from:Date())))
    }
    @discardableResult mutating func confirmSegments(_ ids:[String],name:String,person:SharedPersonReference?=nil,learn:Bool)->Bool {
        let ids=Array(Set(ids)).sorted(),name=normalized(name)
        guard let name,!ids.isEmpty,ids.count<=4096,let session=ids.first.flatMap({sessions[$0]}),ids.allSatisfy({sessions[$0]==session}) else{return false}
        let changes=ids.map{Change.sentence($0,sentenceNames[$0])}
        remember(.batch(changes))
        for id in ids {if let key=key(segment:id){suppressAuto(key,bumpRevision:false)};sentenceNames[id]=name}
        attachConfirmation(segmentIDs:ids,name:name,person:person,learn:learn)
        return true
    }
    var canUndo:Bool {!undoStack.isEmpty}
    var values:[String:String] {var result:[String:String]=[:];for id in Set(bindings.keys).union(sentenceNames.keys) {result[id]=name(segment:id)};return result}
    func canonical(_ key:SessionSpeakerKey)->SessionSpeakerKey {var current=key;for _ in 0..<128 {guard let next=aliases[current],next != current else{break};current=next};return current}
    func key(segment:String)->SessionSpeakerKey? {bindings[segment].map{canonical($0)}}
    func name(segment:String)->String? {sentenceNames[segment] ?? key(segment:segment).flatMap{speakerNames[$0]}}
    func sentenceName(segment:String)->String? {sentenceNames[segment]}
    func name(speaker:SessionSpeakerKey)->String? {speakerNames[canonical(speaker)]}
    func displayName(segment:String)->SessionDisplayName? {
        if let manual=name(segment:segment) {return SessionDisplayName(value:manual,origin:.manual)}
        guard let key=key(segment:segment) else{return nil}
        if let value=voiceSuggestion(for:key),validatedVoiceRevisions[value.personID]==value.archiveRevision,
           value.recognizedSupport?.contains(where:{$0.id==segment && segmentRevisions[segment]==$0.revision && bindings[segment]==key})==true {
            return SessionDisplayName(value:value.name,origin:.voiceprint)
        }
        return displayName(speaker:key)
    }
    // Restored per-span decisions become visible only against the current bank.
    // This gate is transient: a cache file cannot authorize its own identity.
    mutating func validateVoiceprintArchive(_ archive:VoiceprintArchive?) {
        validatedVoiceRevisions=Dictionary(uniqueKeysWithValues:(archive?.people.filter(\.enabled) ?? []).map{($0.id,archive!.revision)})
    }
    func displayName(speaker:SessionSpeakerKey)->SessionDisplayName? {
        let key=canonical(speaker)
        if let manual=speakerNames[key] {return SessionDisplayName(value:manual,origin:.manual)}
        return autoNames[key].map{SessionDisplayName(value:$0.name,origin:.voiceprint)} ?? semanticNames[key].map{SessionDisplayName(value:$0.name,origin:.semantic)}
    }
    func autoName(for key:SessionSpeakerKey)->SessionAutoName? {autoNames[canonical(key)]}
    // Group labels stay neutral; exact qualified spans can carry automatic names.
    func voiceSuggestion(for speaker:SessionSpeakerKey)->SessionAutoName? {
        let key=canonical(speaker)
        guard let value=voiceSuggestions[key],
              key==speaker,autoNames[key]==nil,!autoSuppressed.contains(key),speakerNames[key]==nil,
              !aliases.keys.contains(key),!aliases.values.contains(key),
              !hasManualBinding(for:key),supportIsCurrent(value,key:key) else{return nil}
        return value
    }
    func autoNameIsSuppressed(_ key:SessionSpeakerKey)->Bool {autoSuppressed.contains(canonical(key))}
    func autoNamedKeys(personID:String)->[SessionSpeakerKey] {Array(Set((Array(autoNames.values)+Array(voiceSuggestions.values)).filter{$0.personID==personID}.map(\.key)))}
    func choices(session:String)->[SessionSpeakerKey] {Array(Set(bindings.values.map{canonical($0)})).filter{$0.session==session}.sorted{($0.source+$0.identity)<($1.source+$1.identity)}}
    private static func textHash(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    private func confirmed(_ id:String)->Bool {sentenceNames[id] != nil || correctedBindings.contains(id)}
    private static func anchor(_ id:String,_ item:[String:Any])->RunAnchor? {
        guard let parent=item["parent_segment_id"] as? String,!parent.isEmpty,
              let session=item["session"] as? String,!session.isEmpty,
              let source=item["source_id"] as? String,isTranscriptAudioTrack(source),
              let epoch=item["epoch"] as? String,!epoch.isEmpty,
              let start=item["start"] as? Double,let end=item["end"] as? Double,
              start.isFinite,end.isFinite,start>=0,end>start,end<1e8,
              let text=item["text"] as? String,!text.isEmpty else{return nil}
        return RunAnchor(id:id,parent:parent,session:session,source:source,epoch:epoch,start:start,end:end,textSHA256:textHash(sourceText(item,start:start,end:end) ?? text))
    }
    // Cleaned text retains the source time range. A name binds to that original
    // evidence, not to the number or spelling of characters in the clean view.
    private static func sourceText(_ item:[String:Any],start:Double,end:Double)->String? {
        guard let words=item["coarse_source_word_spans"] as? [[String:Any]],!words.isEmpty else{return nil}
        let rows=words.filter{($0["start"] as? Double ?? -.infinity)>=start-1e-6 && ($0["end"] as? Double ?? .infinity)<=end+1e-6}
        guard let first=rows.first,let last=rows.last,
              abs((first["start"] as? Double ?? -.infinity)-start)<1e-6,
              abs((last["end"] as? Double ?? .infinity)-end)<1e-6,
              rows.allSatisfy({$0["text"] is String}) else{return nil}
        return rows.compactMap{$0["text"] as? String}.joined()
    }
    private mutating func saveAnchor(_ anchor:RunAnchor) {
        if let old=runAnchors[anchor.id],old.parent != anchor.parent {
            anchorsByParent[old.parent]?.remove(anchor.id)
            if anchorsByParent[old.parent]?.isEmpty==true {anchorsByParent.removeValue(forKey:old.parent)}
        }
        runAnchors[anchor.id]=anchor;anchorsByParent[anchor.parent,default:[]].insert(anchor.id)
    }
    mutating func register(segment:String,item:[String:Any]) {
        let session=item["session"] as? String
        if !correctedBindings.contains(segment) || sessions[segment] != session {bindings[segment]=SessionSpeakerKey.from(item);correctedBindings.remove(segment)};sessions[segment]=session
        segmentRevisions[segment]=item["revision"] as? Int
        if !confirmed(segment),let anchor=Self.anchor(segment,item) {saveAnchor(anchor)}
        if let key=key(segment:segment),!speakerOrder.contains(key),speakerOrder.count<128 {speakerOrder.append(key)}
    }
    // A saved correction applies only to the same provider words, never to text
    // that a later model revision happened to merge into the display run.
    func manualRunOverrides(parent:String,item:[String:Any])->[ManualRunOverride] {
        // Most turns have no human correction. Never scan other turns or parse
        // provider words for that common case during live UI rendering.
        let candidates=(anchorsByParent[parent] ?? []).compactMap { id -> RunAnchor? in
            guard confirmed(id) else{return nil};return runAnchors[id]
        }
        guard !candidates.isEmpty else{return []}
        guard item["end_time_known"] as? Bool==true,
              let session=item["session"] as? String,let source=item["source_id"] as? String,
              let epoch=item["epoch"] as? String,
              let begin=item["start"] as? Double,let finish=item["end"] as? Double,
              begin.isFinite,finish.isFinite,finish>begin,
              let original=item["text"] as? String,
              let raw=item["word_spans"] as? [[String:Any]],!raw.isEmpty,raw.count<=1000 else{return []}
        var words:[(start:Double,end:Double,text:String)]=[];var cursor=begin;var joined=""
        for word in raw {
            guard let lo=word["start"] as? Double,let hi=word["end"] as? Double,
                  lo.isFinite,hi.isFinite,lo>=cursor,hi>lo,hi<=finish,
                  let text=word["text"] as? String,!text.isEmpty else{return []}
            words.append((lo,hi,text));joined+=text;cursor=hi
        }
        guard joined==original else{return []}
        var result:[ManualRunOverride]=[]
        for anchor in candidates where anchor.session==session && anchor.source==source && anchor.epoch==epoch {
            guard let first=words.firstIndex(where:{abs($0.start-anchor.start)<1e-6}) else{continue}
            var text=""
            for word in words[first...] {
                if word.end>anchor.end+1e-6 {break}
                text+=word.text
                if abs(word.end-anchor.end)<1e-6 {
                    if Self.textHash(text)==anchor.textSHA256 || Self.sourceText(item,start:anchor.start,end:anchor.end).map({Self.textHash($0)==anchor.textSHA256})==true {
                        result.append(ManualRunOverride(id:anchor.id,start:anchor.start,end:anchor.end,text:text))
                    }
                    break
                }
            }
        }
        return result.sorted{$0.start == $1.start ? $0.end < $1.end : $0.start < $1.start}
    }
    func displayLabel(speaker:SessionSpeakerKey)->String {
        let key=canonical(speaker);var seen=Set<SessionSpeakerKey>();let order=speakerOrder.map{canonical($0)}.filter{$0.session==key.session && seen.insert($0).inserted}
        return order.firstIndex(of:key).map{"发言人 "+String($0+1)} ?? "发言人"
    }
    private func normalized(_ text:String)->String? {let value=text.trimmingCharacters(in:.whitespacesAndNewlines);return value.isEmpty ? nil:String(value.prefix(80))}
    private mutating func suppressAuto(_ original:SessionSpeakerKey,bumpRevision:Bool=true) {
        let key=canonical(original)
        let removedVoice=autoNames.removeValue(forKey:key) != nil
        let removedSemantic=semanticNames.removeValue(forKey:key) != nil
        let removedSuggestion=voiceSuggestions.removeValue(forKey:key) != nil
        let removed=removedVoice || removedSuggestion || removedSemantic
        let inserted=autoSuppressed.insert(key).inserted
        if bumpRevision && (removed || inserted) {correctionRevision &+= 1}
    }
    @discardableResult mutating func dismissAutoName(_ key:SessionSpeakerKey)->Bool {
        let previous=correctionRevision;suppressAuto(key);return correctionRevision != previous
    }
    // An automatic label never pins model bindings or enters the human undo stack.
    @discardableResult mutating func reconcileAutoVoiceprint(key:SessionSpeakerKey,candidate:VoiceprintRecommendation?,conflictingEvidence:Bool=false)->Bool {
        guard canonical(key)==key else{return false}
        if conflictingEvidence {let previous=correctionRevision;suppressAuto(key);return correctionRevision != previous}
        let validCandidate=candidate.map{validVoiceRecommendation($0,key:key)} ?? false
        let eligible = !autoSuppressed.contains(key) && speakerNames[key]==nil &&
            !aliases.keys.contains(key) && !aliases.values.contains(key) &&
            bindings.contains(where:{$0.value==key}) && !hasManualBinding(for:key)
        let suggestion:SessionAutoName? = candidate.flatMap { value in
            guard !value.groupConsistent,validCandidate,eligible else{return nil}
            var recognized=value.recognizedSupport
            if let current=recognized,let previous=voiceSuggestions[key],previous.personID==value.personID,
               previous.archiveRevision==value.archiveRevision,let old=previous.recognizedSupport {
                recognized=Array((old.filter{ref in segmentRevisions[ref.id]==ref.revision && bindings[ref.id]==key && !current.contains(where:{$0.id==ref.id})}+current).suffix(256))
            }
            return SessionAutoName(key:key,personID:value.personID,name:value.name,archiveRevision:value.archiveRevision,support:value.support,recognizedSupport:recognized)
        }
        if let candidate,validCandidate {validatedVoiceRevisions[candidate.personID]=candidate.archiveRevision}
        if let old=autoNames[key] {
            if let candidate,validCandidate,candidate.personID != old.personID {suppressAuto(key);return true}
            guard let candidate,validCandidate,candidate.groupConsistent,eligible else{
                autoNames.removeValue(forKey:key);voiceSuggestions[key]=suggestion;correctionRevision &+= 1;return true
            }
            guard candidate.personID==old.personID else{suppressAuto(key);return true}
            // Keep the original three supporting events while they are still
            // current; later turns need not rewrite every heading and cache.
            if old.name==candidate.name && old.archiveRevision==candidate.archiveRevision && old.support.allSatisfy({segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==key}) {return false}
            let next=SessionAutoName(key:key,personID:candidate.personID,name:candidate.name,archiveRevision:candidate.archiveRevision,support:candidate.support)
            guard old != next else{return false}
            autoNames[key]=next;voiceSuggestions.removeValue(forKey:key);correctionRevision &+= 1;return true
        }
        if let suggestion {
            guard voiceSuggestions[key] != suggestion else{return false}
            voiceSuggestions[key]=suggestion;correctionRevision &+= 1;return true
        }
        let removedSuggestion=voiceSuggestions.removeValue(forKey:key) != nil
        guard let candidate,validCandidate,candidate.groupConsistent,eligible else{
            if removedSuggestion {correctionRevision &+= 1;return true}
            return false
        }
        autoNames[key]=SessionAutoName(key:key,personID:candidate.personID,name:candidate.name,archiveRevision:candidate.archiveRevision,support:candidate.support)
        correctionRevision &+= 1;return true
    }
    private func validVoiceRecommendation(_ value:VoiceprintRecommendation,key:SessionSpeakerKey)->Bool {
        UUID(uuidString:value.personID) != nil && value.archiveRevision>=1 &&
        normalized(value.name)==value.name && value.evidenceCount>=3 && value.evidenceCount<=256 &&
        (3...8).contains(value.support.count) && value.support.count<=value.evidenceCount &&
        Set(value.support.map(\.id)).count==value.support.count &&
        value.support.allSatisfy{$0.id.count<=256 && $0.revision>=0 && segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==key} &&
        (value.recognizedSupport.map{refs in (3...24).contains(refs.count) && Set(refs.map(\.id)).count==refs.count && refs.allSatisfy{segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==key}} ?? true)
    }
    private func supportIsCurrent(_ value:SessionAutoName,key:SessionSpeakerKey)->Bool {
        value.key==key && UUID(uuidString:value.personID) != nil && value.archiveRevision>=1 &&
        normalized(value.name)==value.name && (3...8).contains(value.support.count) &&
        Set(value.support.map(\.id)).count==value.support.count &&
        value.support.allSatisfy{$0.id.count<=256 && $0.revision>=0 && segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==key}
    }
    private func hasManualBinding(for key:SessionSpeakerKey)->Bool {
        // Inspect only manual edits, rather than scanning every utterance for
        // every displayed name. Binding and alias semantics remain identical.
        sentenceNames.keys.contains{bindings[$0].map{canonical($0)==key} ?? false} ||
            correctedBindings.contains{bindings[$0].map{canonical($0)==key} ?? false}
    }
    @discardableResult mutating func observeSemanticName(_ event:[String:Any])->Bool {
        let changed=semanticMatcher.observe(event);var updated=false
        for key in changed {
            let candidate=semanticMatcher.recommendation(key)
            let eligible=canonical(key)==key && !autoSuppressed.contains(key) && speakerNames[key]==nil &&
                !bindings.contains(where:{$0.value==key && (sentenceNames[$0.key] != nil || correctedBindings.contains($0.key))})
            let next=eligible ? candidate:nil
            if semanticNames[key] != next {semanticNames[key]=next;updated=true}
        }
        if updated {correctionRevision &+= 1};return updated
    }
    private func affectedIDs(_ change:Change)->Set<String> {
        switch change {
        case .sentence(let id,_):return [id]
        case .speaker(let id,_,_,_,let pins):return Set(pins.keys).union([id])
        case .speakerGroup(_,_,let sentences,_):return Set(sentences.keys)
        case .assignment(let id,_,_,let target,_,_):return Set(segmentIDs(for:target)).union([id])
        case .merge(let source,_,_,_,let destination):return Set(segmentIDs(for:source)+segmentIDs(for:destination))
        case .batch(let changes):return changes.reduce(into:Set<String>()){$0.formUnion(affectedIDs($1))}
        case .identityMetadata:return []
        }
    }
    private mutating func remember(_ change:Change) {
        correctionRevision &+= 1
        undoStack.append(.batch([.identityMetadata(personReferences,voiceConfirmations),change]))
        if undoStack.count>32 {undoStack.removeFirst()}
        let ids=affectedIDs(change)
        for id in ids {personReferences.removeValue(forKey:id)}
        voiceConfirmations.removeAll{!Set($0.segmentIDs).isDisjoint(with:ids)}
    }
    mutating func set(segment:String,name:String) {if let key=key(segment:segment){suppressAuto(key,bumpRevision:false)};remember(.sentence(segment,sentenceNames[segment]));sentenceNames[segment]=normalized(name)}
    mutating func setSpeaker(segment:String,name:String) {
        guard let key=key(segment:segment) else {set(segment:segment,name:name);return}
        let affected=bindings.filter{canonical($0.value)==key}.map(\.key)
        let pins=Dictionary(uniqueKeysWithValues:affected.map{($0,correctedBindings.contains($0))})
        suppressAuto(key,bumpRevision:false)
        remember(.speaker(segment,key,speakerNames[key],sentenceNames[segment],pins));speakerNames[key]=normalized(name);sentenceNames.removeValue(forKey:segment)
        // Naming all this person's existing turns confirms their current bindings.
        // Future unconfirmed turns still follow model evidence; equal names do not merge identities.
        if normalized(name) != nil {correctedBindings.formUnion(affected)}
    }
    @discardableResult mutating func renameSpeaker(key:SessionSpeakerKey,name:String)->Bool {
        renameSpeaker(keys:[key],name:name)
    }
    @discardableResult mutating func renameSpeaker(keys:[SessionSpeakerKey],name:String)->Bool {
        var keys=Array(Set(keys.map{canonical($0)}))
        keys.sort {
            if $0.source != $1.source {return $0.source<$1.source}
            if $0.epoch != $1.epoch {return $0.epoch<$1.epoch}
            return $0.identity<$1.identity
        }
        guard let name=normalized(name),!keys.isEmpty,keys.count<=128,
              keys.allSatisfy({$0.session==keys[0].session && choices(session:$0.session).contains($0)}) else{return false}
        var changes:[Change]=[],affectedByKey:[SessionSpeakerKey:[String]]=[:]
        for key in keys {
            let affected=bindings.filter{canonical($0.value)==key}.map(\.key).sorted()
            guard !affected.isEmpty else{return false}
            affectedByKey[key]=affected
            var previousSentences:[String:String?]=[:],previousPins:[String:Bool]=[:]
            for id in affected {previousSentences[id] = .some(sentenceNames[id]);previousPins[id]=correctedBindings.contains(id)}
            changes.append(.speakerGroup(key,speakerNames[key],previousSentences,previousPins))
        }
        for key in keys {suppressAuto(key,bumpRevision:false)}
        remember(.batch(changes))
        for key in keys {
            speakerNames[key]=name
            for id in affectedByKey[key] ?? [] {sentenceNames.removeValue(forKey:id);correctedBindings.insert(id)}
        }
        return true
    }
    func assignmentWouldChange(segment:String,to target:SessionSpeakerKey)->Bool {
        key(segment:segment) != canonical(target) || sentenceNames[segment] != nil
    }
    @discardableResult mutating func assignBatch(segmentIDs:[String],to target:SessionSpeakerKey,humanConfirmed:Bool)->Bool {
        let target=canonical(target),ids=Array(Set(segmentIDs)).sorted()
        guard humanConfirmed,!ids.isEmpty,speakerNames.count<=128,
              choices(session:target.session).contains(target),
              ids.allSatisfy({sessions[$0]==target.session}) else{return false}
        let changed=ids.filter{assignmentWouldChange(segment:$0,to:target)}
        guard !changed.isEmpty else{return false}
        suppressAuto(target,bumpRevision:false);for id in changed {if let prior=key(segment:id){suppressAuto(prior,bumpRevision:false)}}
        let changes=changed.map{id in Change.assignment(id,bindings[id],sentenceNames[id],target,speakerNames[target],correctedBindings.contains(id))}
        remember(.batch(changes))
        for id in changed {bindings[id]=target;correctedBindings.insert(id);sentenceNames.removeValue(forKey:id)}
        return true
    }
    @discardableResult mutating func mergeSpeaker(from source:SessionSpeakerKey,to destination:SessionSpeakerKey,humanConfirmed:Bool)->Bool {
        mergeSpeakers(from:[source],to:destination,humanConfirmed:humanConfirmed)
    }
    @discardableResult mutating func mergeSpeakers(from sourceKeys:[SessionSpeakerKey],to destination:SessionSpeakerKey,humanConfirmed:Bool)->Bool {
        let destination=canonical(destination)
        var sources=Array(Set(sourceKeys.map{canonical($0)})).filter{$0 != destination}
        sources.sort {
            if $0.source != $1.source {return $0.source<$1.source}
            if $0.epoch != $1.epoch {return $0.epoch<$1.epoch}
            return $0.identity<$1.identity
        }
        guard humanConfirmed,!sources.isEmpty,sources.count<=128,destination.session==sources[0].session,
              sources.allSatisfy({$0.session==destination.session && choices(session:$0.session).contains($0)}),
              choices(session:destination.session).contains(destination),aliases.count+sources.count<=128 else{return false}
        var destinationName=speakerNames[destination],changes:[Change]=[]
        for source in sources {
            changes.append(.merge(source,aliases[source],speakerNames[source],destinationName,destination))
            if destinationName==nil {destinationName=speakerNames[source]}
        }
        for key in sources+[destination] {suppressAuto(key,bumpRevision:false)}
        remember(.batch(changes))
        for source in sources {
            if speakerNames[destination]==nil {speakerNames[destination]=speakerNames[source]}
            speakerNames.removeValue(forKey:source);aliases[source]=destination
        }
        return true
    }
    @discardableResult mutating func assign(segment:String,to target:SessionSpeakerKey,humanConfirmed:Bool,name:String?=nil)->Bool {
        let target=canonical(target)
        guard humanConfirmed,sessions[segment]==target.session,choices(session:target.session).contains(target),speakerNames.count<=128 else{return false}
        guard assignmentWouldChange(segment:segment,to:target) || name.map({normalized($0) != speakerNames[target]}) == true else{return false}
        suppressAuto(target,bumpRevision:false);if let prior=key(segment:segment){suppressAuto(prior,bumpRevision:false)}
        remember(.assignment(segment,bindings[segment],sentenceNames[segment],target,speakerNames[target],correctedBindings.contains(segment)));bindings[segment]=target;correctedBindings.insert(segment);sentenceNames.removeValue(forKey:segment)
        if let name=name {speakerNames[target]=normalized(name)};return true
    }
    // A changed model slot is not evidence of identity continuity. Migration needs
    // explicit confirmed continuity and never uses matching human names as evidence.
    @discardableResult mutating func migrate(from old:SessionSpeakerKey,to new:SessionSpeakerKey,continuityConfirmed:Bool)->Bool {
        let a=canonical(old),b=canonical(new)
        guard continuityConfirmed,a.sameScope(b),a != b,aliases.count<128 else{return false}
        if let x=speakerNames[a],let y=speakerNames[b],x != y {return false}
        suppressAuto(a,bumpRevision:false);suppressAuto(b,bumpRevision:false)
        if speakerNames[b]==nil {speakerNames[b]=speakerNames[a]};speakerNames.removeValue(forKey:a);aliases[a]=b;correctionRevision &+= 1;return true
    }
    @discardableResult mutating func undo()->String? {
        lastUndoSegmentIDs=[]
        guard let change=undoStack.popLast() else{return nil}
        correctionRevision &+= 1
        lastUndoSegmentIDs=undo(change).sorted()
        return lastUndoSegmentIDs.first
    }
    private mutating func undo(_ change:Change)->Set<String> {
        switch change {
        case .sentence(let id,let old):sentenceNames[id]=old;return [id]
        case .speaker(let id,let key,let old,let manual,let pins):speakerNames[canonical(key)]=old;sentenceNames[id]=manual;for (sid,pinned) in pins {if pinned {correctedBindings.insert(sid)}else{correctedBindings.remove(sid)}};return Set(pins.keys).union([id])
        case .assignment(let id,let old,let manual,let target,let prior,let corrected):if corrected {correctedBindings.insert(id)}else{correctedBindings.remove(id)};bindings[id]=old;sentenceNames[id]=manual;speakerNames[canonical(target)]=prior;return [id]
        case .speakerGroup(let key,let old,let sentences,let pins):
            speakerNames[canonical(key)]=old
            for (id,value) in sentences {sentenceNames[id]=value}
            for (id,pinned) in pins {if pinned {correctedBindings.insert(id)}else{correctedBindings.remove(id)}}
            return Set(sentences.keys)
        case .merge(let source,let oldAlias,let sourceName,let destinationName,let destination):
            let affected=Set(bindings.compactMap {id,key in canonical(key)==canonical(destination) ? id:nil})
            if let alias=oldAlias {aliases[source]=alias}else{aliases.removeValue(forKey:source)}
            speakerNames[source]=sourceName;speakerNames[destination]=destinationName
            return affected
        case .batch(let changes):
            return changes.reversed().reduce(into:Set<String>()){$0.formUnion(undo($1))}
        case .identityMetadata(let refs,let confirmations):personReferences=refs;voiceConfirmations=confirmations;return []
        }
    }
    mutating func discard(segment:String) {
        correctionRevision &+= 1
        let ids=[segment]+Array(anchorsByParent[segment] ?? [])
        for id in ids {personReferences.removeValue(forKey:id)}
        voiceConfirmations.removeAll{!Set($0.segmentIDs).isDisjoint(with:ids)}
        for key in Array(autoNames.keys) where autoNames[key]?.support.contains(where:{ids.contains($0.id)})==true {autoNames.removeValue(forKey:key)}
        for key in Array(voiceSuggestions.keys) where voiceSuggestions[key]?.support.contains(where:{ids.contains($0.id)})==true {voiceSuggestions.removeValue(forKey:key)}
        for key in Array(semanticNames.keys) where semanticNames[key]?.support.contains(where:{ids.contains($0.id)})==true {semanticNames.removeValue(forKey:key)}
        semanticMatcher.discard(Set(ids))
        for id in ids {
            correctedBindings.remove(id);sentenceNames.removeValue(forKey:id);bindings.removeValue(forKey:id);sessions.removeValue(forKey:id);segmentRevisions.removeValue(forKey:id)
            if let anchor=runAnchors.removeValue(forKey:id) {anchorsByParent[anchor.parent]?.remove(id);if anchorsByParent[anchor.parent]?.isEmpty==true {anchorsByParent.removeValue(forKey:anchor.parent)}}
        }
    }
    private struct Named:Codable {let key:SessionSpeakerKey;let name:String}
    private struct Assignment:Codable {let id:String;let key:SessionSpeakerKey}
    private struct Alias:Codable {let from:SessionSpeakerKey;let to:SessionSpeakerKey}
    private struct Snapshot:Codable {let schema:Int;let session:String;let sentences:[String:String];let speakers:[Named];let assignments:[Assignment];let aliases:[Alias];let order:[SessionSpeakerKey]?;let runAnchors:[RunAnchor]?;let autoNames:[SessionAutoName]?;let voiceSuggestions:[SessionAutoName]?;let autoSuppressed:[SessionSpeakerKey]?;let semanticNames:[SessionSemanticName]?;let personReferences:[String:SharedPersonReference]?;let voiceConfirmations:[SessionVoiceConfirmation]?;let undo:[Change]?}
    func snapshot(session:String)throws->Data {
        let confirmedAnchors=runAnchors.values.filter{$0.session==session && confirmed($0.id)}
        let currentSuggestions=voiceSuggestions.values.filter{$0.key.session==session && autoNames[$0.key]==nil && supportIsCurrent($0,key:$0.key) && !autoSuppressed.contains($0.key) && speakerNames[$0.key]==nil && !aliases.keys.contains($0.key) && !aliases.values.contains($0.key) && !hasManualBinding(for:$0.key)}
        let value=Snapshot(schema:2,session:session,sentences:sentenceNames.filter{sessions[$0.key]==session},speakers:speakerNames.filter{$0.key.session==session}.map{Named(key:$0.key,name:$0.value)},assignments:correctedBindings.compactMap{id in guard let key=bindings[id],key.session==session else{return nil};return Assignment(id:id,key:key)},aliases:aliases.filter{$0.key.session==session}.map{Alias(from:$0.key,to:$0.value)},order:speakerOrder.filter{$0.session==session},runAnchors:confirmedAnchors.isEmpty ? nil:confirmedAnchors,autoNames:autoNames.values.filter{$0.key.session==session},voiceSuggestions:currentSuggestions.isEmpty ? nil:currentSuggestions,autoSuppressed:Array(autoSuppressed.filter{$0.session==session}),semanticNames:semanticNames.values.filter{$0.key.session==session},personReferences:personReferences.filter{sessions[$0.key]==session},voiceConfirmations:voiceConfirmations.filter{$0.session==session},undo:undoStack)
        return try JSONEncoder().encode(value)
    }
    mutating func restore(_ originalData:Data,session:String,events:[[String:Any]] = [],directory:URL?=nil)throws {
        let data=try directory.map{try SpeakerRefinementArtifact.normalizedNameSnapshot(originalData,events:events,directory:$0,session:session)} ?? originalData
        guard data.count<=4*1024*1024 else{throw Failure(code:"cache_names_capacity")};let value=try JSONDecoder().decode(Snapshot.self,from:data)
        func valid(_ key:SessionSpeakerKey)->Bool {key.session==session && isTranscriptAudioTrack(key.source) && !key.epoch.isEmpty && key.epoch.count<=160 && !key.identity.isEmpty && key.identity.count<=160}
        let anchors=value.runAnchors ?? [],savedAuto=value.autoNames ?? [],savedSuggestions=value.voiceSuggestions ?? [],savedSuppressed=value.autoSuppressed ?? [],savedSemantic=value.semanticNames ?? []
        guard [1,2].contains(value.schema),value.session==session,value.sentences.count<=4096,value.speakers.count<=128,value.assignments.count<=4096,value.aliases.count<=128,anchors.count<=4096,savedAuto.count<=128,savedSuggestions.count<=128,savedSuppressed.count<=128,savedSemantic.count<=128,
              (value.schema==1 || (value.autoNames != nil && value.autoSuppressed != nil)),
              Set(savedAuto.map(\.key)).count==savedAuto.count,Set(savedSuggestions.map(\.key)).count==savedSuggestions.count,
              Set(savedAuto.map(\.key)).isDisjoint(with:Set(savedSuggestions.map(\.key))),
              value.sentences.values.allSatisfy({$0.count<=80}),value.speakers.allSatisfy({valid($0.key) && $0.name.count<=80}),value.assignments.allSatisfy({valid($0.key)}),value.aliases.allSatisfy({valid($0.from) && valid($0.to) && $0.from.session==$0.to.session}),
              savedSuppressed.allSatisfy(valid),
              savedSemantic.allSatisfy({valid($0.key) && !$0.name.isEmpty && $0.name.count<=80 && (2...8).contains($0.support.count) && Set($0.support.map(\.id)).count==$0.support.count && $0.support.allSatisfy{$0.id.count<=256 && $0.revision>=0 && $0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end>$0.start}}),
              (savedAuto+savedSuggestions).allSatisfy({valid($0.key) && UUID(uuidString:$0.personID) != nil && !$0.name.isEmpty && $0.name.count<=80 && $0.archiveRevision>=1 && (3...8).contains($0.support.count) && Set($0.support.map(\.id)).count==$0.support.count && $0.support.allSatisfy{$0.id.count<=256 && $0.revision>=0} && ($0.recognizedSupport.map{refs in (3...256).contains(refs.count) && Set(refs.map(\.id)).count==refs.count && refs.allSatisfy{$0.id.count<=256 && $0.revision>=0}} ?? true)}),
              anchors.allSatisfy({anchor in
                  guard anchor.session==session,!anchor.parent.isEmpty,anchor.parent.count<=256,
                        isTranscriptAudioTrack(anchor.source),!anchor.epoch.isEmpty,anchor.epoch.count<=160,
                        anchor.start.isFinite,anchor.end.isFinite,anchor.start>=0,anchor.end>anchor.start,anchor.end<1e8,
                        anchor.id.count<=256,anchor.textSHA256.count==64,
                        anchor.textSHA256.allSatisfy({"0123456789abcdef".contains($0)}) else{return false}
                  let stamp=String(Int((anchor.start*1000).rounded()))
                  return anchor.id==anchor.parent+":word:"+stamp || anchor.id==anchor.parent+":turn:"+stamp
              }) else{throw Failure(code:"cache_names_invalid")}
        let refs=value.personReferences ?? [:],confirmations=value.voiceConfirmations ?? []
        guard refs.count<=4096,refs.allSatisfy({$0.key.count<=256 && (try? $0.value.validated()) != nil}),
              confirmations.count<=128,Set(confirmations.map(\.id)).count==confirmations.count,
              confirmations.allSatisfy({UUID(uuidString:$0.id) != nil && $0.session==session && !$0.name.isEmpty && $0.name.count<=80 && !$0.segmentIDs.isEmpty && $0.segmentIDs.count<=4096 && $0.segmentIDs.allSatisfy{$0.count<=256} && ISO8601DateFormatter().date(from:$0.createdAt) != nil && ($0.person==nil || ((try? $0.person!.validated()) != nil && $0.person!.name==$0.name))}),
              (value.undo?.count ?? 0)<=32 else{throw Failure(code:"cache_identity_invalid")}
        if let order=value.order {guard order.count<=128,Set(order).count==order.count,order.allSatisfy(valid) else{throw Failure(code:"cache_names_invalid")};speakerOrder=order+speakerOrder.filter{!order.contains($0)}}
        for anchor in anchors {saveAnchor(anchor);sessions[anchor.id]=session}
        for (id,name) in value.sentences where sessions[id]==session {sentenceNames[id]=name}
        for row in value.speakers {speakerNames[row.key]=row.name}
        for row in value.assignments where sessions[row.id]==session {bindings[row.id]=row.key;correctedBindings.insert(row.id)}
        for row in value.aliases {aliases[row.from]=row.to}
        autoSuppressed.formUnion(savedSuppressed)
        restoredAutoNameInvalidated=false;validatedVoiceRevisions=[:]
        for row in savedAuto {
            let supported=row.support.allSatisfy{segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==row.key}
            if supported && speakerNames[row.key]==nil && !autoSuppressed.contains(row.key) && canonical(row.key)==row.key {
                autoNames[row.key]=row
            } else {restoredAutoNameInvalidated=true}
        }
        for row in savedSuggestions {
            let supported=row.support.allSatisfy{segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==row.key}
            if supported && speakerNames[row.key]==nil && !autoSuppressed.contains(row.key) && canonical(row.key)==row.key && !aliases.keys.contains(row.key) && !aliases.values.contains(row.key) && !hasManualBinding(for:row.key) {
                voiceSuggestions[row.key]=row
            } else {restoredAutoNameInvalidated=true}
        }
        for row in savedSemantic {
            if row.support.allSatisfy({segmentRevisions[$0.id]==$0.revision && bindings[$0.id]==row.key}) && speakerNames[row.key]==nil && !autoSuppressed.contains(row.key) && canonical(row.key)==row.key {semanticNames[row.key]=row;semanticMatcher.restore(row)}
            else {restoredAutoNameInvalidated=true}
        }
        personReferences=refs.filter{sessions[$0.key]==session && name(segment:$0.key)==$0.value.name}
        voiceConfirmations=confirmations.filter{record in record.segmentIDs.allSatisfy{sessions[$0]==session && name(segment:$0)==record.name}}
        undoStack=value.undo ?? [];correctionRevision &+= 1
    }
    mutating func reset() {correctionRevision &+= 1;speakerOrder=[];correctedBindings=[];sentenceNames=[:];speakerNames=[:];semanticNames=[:];semanticMatcher=LocalSemanticNames();autoNames=[:];voiceSuggestions=[:];autoSuppressed=[];bindings=[:];aliases=[:];sessions=[:];segmentRevisions=[:];runAnchors=[:];anchorsByParent=[:];personReferences=[:];voiceConfirmations=[];undoStack=[];lastUndoSegmentIDs=[];restoredAutoNameInvalidated=false;validatedVoiceRevisions=[:]}
}
func sessionSpeakerMappingChecks()->Int {
    var n=SessionNames();var checks=0
    func item(_ slot:Int,_ source:String="remote",_ epoch:String="e",_ session:String="s")->[String:Any] {["session":session,"source_id":source,"epoch":epoch,"speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch]]}
    n.register(segment:"a",item:item(0));n.register(segment:"b",item:item(0));n.register(segment:"other",item:item(1));n.register(segment:"mic",item:item(0,"mic"))
    n.setSpeaker(segment:"a",name:"说话人甲");precondition(n.name(segment:"a")=="说话人甲" && n.name(segment:"b")=="说话人甲" && n.name(segment:"other")==nil && n.name(segment:"mic")==nil);checks+=1
    n.register(segment:"future",item:item(0));precondition(n.name(segment:"future")=="说话人甲");checks+=1
    n.setSpeaker(segment:"other",name:"说话人甲");n.setSpeaker(segment:"a",name:"Corrected");precondition(n.name(segment:"b")=="Corrected" && n.name(segment:"future")=="Corrected" && n.name(segment:"other")=="说话人甲");checks+=1
    n.undo();precondition(n.name(segment:"a")=="说话人甲" && n.name(segment:"b")=="说话人甲");checks+=1
    n.set(segment:"b",name:"One sentence only");precondition(n.name(segment:"b")=="One sentence only" && n.name(segment:"a")=="说话人甲");checks+=1
    n.undo();precondition(n.name(segment:"b")=="说话人甲");checks+=1
    let target=n.key(segment:"other")!;precondition(!n.assign(segment:"b",to:target,humanConfirmed:false));checks+=1
    precondition(n.assign(segment:"b",to:target,humanConfirmed:true,name:"Second person"));precondition(n.name(segment:"b")=="Second person" && n.name(segment:"other")=="Second person" && n.name(segment:"a")=="说话人甲");checks+=1
    n.register(segment:"b",item:item(0));precondition(n.name(segment:"b")=="Second person");checks+=1
    n.undo();precondition(n.name(segment:"b")=="说话人甲" && n.key(segment:"b") != target && n.name(segment:"other")=="说话人甲");checks+=1
    n.register(segment:"foreign",item:item(0,"remote","e","different-session"));precondition(!n.assign(segment:"b",to:n.key(segment:"foreign")!,humanConfirmed:true));checks+=1
    n.register(segment:"unknown",item:["session":"s","source_id":"remote","epoch":"e","speaker":["basis":"unknown"]]);n.setSpeaker(segment:"unknown",name:"Only unknown sentence");n.register(segment:"next-unknown",item:["session":"s","speaker":["basis":"unknown"]]);precondition(n.name(segment:"next-unknown")==nil && n.key(segment:"unknown")==nil);checks+=1
    let old=n.key(segment:"a")!;let stable=SessionSpeakerKey(session:"s",source:"remote",epoch:"e",identity:"stable:test")
    precondition(!n.migrate(from:old,to:stable,continuityConfirmed:false));checks+=1
    precondition(n.migrate(from:old,to:stable,continuityConfirmed:true));precondition(n.name(segment:"a")=="说话人甲" && n.name(segment:"future")=="说话人甲" && n.key(segment:"b")==stable);checks+=1
    n.setSpeaker(segment:"other",name:"Conflicting person");precondition(!n.migrate(from:stable,to:target,continuityConfirmed:true));checks+=1
    let changedEpoch=SessionSpeakerKey(session:"s",source:"remote",epoch:"new-epoch",identity:"stable:test");precondition(!n.migrate(from:stable,to:changedEpoch,continuityConfirmed:true));checks+=1
    n.setSpeaker(segment:"a",name:"");precondition(n.name(segment:"b")==nil && n.name(segment:"future")==nil && n.name(segment:"other")=="Conflicting person");n.undo();precondition(n.name(segment:"b")=="说话人甲");checks+=1
    n.discard(segment:"a");precondition(n.name(segment:"future")=="说话人甲");checks+=1
    func namedParent(_ runs:[[String:Any]])->[String:Any] {
        ["type":"segment","segment_id":"turn","session":"s","source_id":"remote","epoch":"e",
         "start":0.0,"end":0.3,"end_time_known":true,"text":"甲乙丙","word_spans":[["start":0.0,"end":0.1,"text":"甲"],["start":0.1,"end":0.2,"text":"乙"],["start":0.2,"end":0.3,"text":"丙"]],"speaker_runs":runs]
    }
    let aSpeaker=item(0)["speaker"]!,bSpeaker=item(1)["speaker"]!
    let before=namedParent([["start":0.0,"end":0.1,"text":"甲","speaker":aSpeaker],["start":0.1,"end":0.3,"text":"乙丙","speaker":bSpeaker]])
    let after=namedParent([["start":0.0,"end":0.2,"text":"甲乙","speaker":aSpeaker],["start":0.2,"end":0.3,"text":"丙","speaker":bSpeaker]])
    var anchored=SessionNames()
    for run in TranscriptTimeline.speakerRuns(before) {anchored.register(segment:TranscriptTimeline.runID(parent:"turn",run:run),item:run)}
    let correctedID=TranscriptTimeline.runID(parent:"turn",run:TranscriptTimeline.speakerRuns(before)[1])
    anchored.set(segment:correctedID,name:"乙丙说话人")
    for run in TranscriptTimeline.speakerRuns(after) {anchored.register(segment:TranscriptTimeline.runID(parent:"turn",run:run),item:run)}
    let overrides=anchored.manualRunOverrides(parent:"turn",item:after)
    precondition(overrides.count==1 && overrides[0].id==correctedID && overrides[0].text=="乙丙" &&
                 overrides[0].start==0.1 && overrides[0].end==0.3 && anchored.name(segment:correctedID)=="乙丙说话人");checks+=1
    let anchoredSnapshot=try! anchored.snapshot(session:"s")
    var reloaded=SessionNames()
    for run in TranscriptTimeline.speakerRuns(after) {reloaded.register(segment:TranscriptTimeline.runID(parent:"turn",run:run),item:run)}
    try! reloaded.restore(anchoredSnapshot,session:"s")
    precondition(reloaded.manualRunOverrides(parent:"turn",item:after).map(\.id)==[correctedID] &&
                 reloaded.name(segment:correctedID)=="乙丙说话人");checks+=1
    var changedWords=after;changedWords["text"]="甲丙丙"
    changedWords["word_spans"]=[["start":0.0,"end":0.1,"text":"甲"],["start":0.1,"end":0.2,"text":"丙"],["start":0.2,"end":0.3,"text":"丙"]]
    precondition(reloaded.manualRunOverrides(parent:"turn",item:changedWords).isEmpty);checks+=1
    anchored.undo();precondition(anchored.manualRunOverrides(parent:"turn",item:after).isEmpty);checks+=1
    var turnItem=after;turnItem["segment_id"]="turn:turn:0";turnItem["parent_segment_id"]="turn";turnItem["speaker"]=aSpeaker
    var namedTurn=SessionNames();namedTurn.register(segment:"turn:turn:0",item:turnItem);namedTurn.set(segment:"turn:turn:0",name:"整段人工确认")
    var restoredTurn=SessionNames();try! restoredTurn.restore(try! namedTurn.snapshot(session:"s"),session:"s")
    precondition(restoredTurn.manualRunOverrides(parent:"turn",item:after).map(\.id)==["turn:turn:0"] &&
                 restoredTurn.name(segment:"turn:turn:0")=="整段人工确认");checks+=1
    var longNames=SessionNames()
    for i in 0..<10000 {
        var item=turnItem;item["parent_segment_id"]="long-\(i)"
        longNames.register(segment:"long-\(i):turn:0",item:item)
    }
    longNames.set(segment:"long-5000:turn:0",name:"人工确认")
    let began=ProcessInfo.processInfo.systemUptime
    for i in 0..<10000 where i != 5000 {precondition(longNames.manualRunOverrides(parent:"long-\(i)",item:after).isEmpty)}
    precondition(ProcessInfo.processInfo.systemUptime-began<2);checks+=1
    precondition(longNames.manualRunOverrides(parent:"long-5000",item:after).map(\.id)==["long-5000:turn:0"]);checks+=1
    longNames.discard(segment:"long-5000")
    precondition(longNames.manualRunOverrides(parent:"long-5000",item:after).isEmpty && longNames.name(segment:"long-5000:turn:0")==nil);checks+=1
    longNames.reset();precondition(longNames.manualRunOverrides(parent:"long-4999",item:after).isEmpty);checks+=1
    n.reset();precondition(n.values.isEmpty && n.choices(session:"s").isEmpty && n.undo()==nil);checks+=1
    var budget=TranscriptCapacity(maxSegments:2,maxTextBytes:10,maxEventBytes:20)
    precondition(budget.reserve("a",textBytes:6,eventBytes:10) && budget.reserve("b",textBytes:4,eventBytes:10));checks+=1
    precondition(!budget.reserve("c",textBytes:1,eventBytes:1) && budget.count==2 && budget.textBytes==10);checks+=1
    precondition(budget.reserve("a",textBytes:2,eventBytes:3) && budget.textBytes==6 && budget.eventBytes==13);checks+=1
    precondition(!budget.reserve("a",textBytes:7,eventBytes:21) && budget.textBytes==6);checks+=1
    budget.remove("b");precondition(budget.count==1 && budget.textBytes==2);budget.reset();precondition(budget.count==0 && budget.eventBytes==0);checks+=1
    let snapshot=try! n.snapshot(session:"s");var restored=SessionNames();restored.register(segment:"restored",item:item(0));try! restored.restore(snapshot,session:"s");checks+=1
    do {try restored.restore(snapshot,session:"other");preconditionFailure()}catch{checks+=1}
    precondition(!String(data:snapshot,encoding:.utf8)!.contains("identity_features"));checks+=1
    return checks
}
func modelSelfTest() {
    var checks=identityArchiveChecks()+balanceNativeChecks()+sessionSpeakerMappingChecks()+readingTurnChecks()+speakerReviewChecks()
    let folder=URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String ?? NSTemporaryDirectory()).appendingPathComponent((Bundle.main.object(forInfoDictionaryKey:"DevelopmentWorkspace") as? Bool==true ? ".runtime/model-checks/":"native/validation-workflow/")+"archive-check-"+UUID().uuidString)
    checks+=(try! profileFileChecks(folder:folder))
    let cases=["fake",String(repeating:"x",count:16),String(repeating:"x",count:32),String(repeating:"x",count:64),String(repeating:"x",count:128),"  fake_key  \n","fake-_/+.=:()", "模拟特殊🔐"]
    let vault=MockVault()
    for value in cases {
        let input=CredentialInput(raw:value)
        precondition(input.issue==nil)
        try! vault.save(input.normalized)
        precondition(vault.bytes==Data(input.normalized.utf8) && vault.load()==input.normalized);checks+=1
    }
    for bad in [""," \n ","fake\ninside","fake\rinside","fake inside","fake\tinside"] {precondition(CredentialInput(raw:bad).issue != nil);checks+=1}
    try! vault.save("old_fake");vault.failNext=true
    do {try vault.save("new_fake");preconditionFailure()} catch {precondition(vault.load()=="old_fake");checks+=1}
    var state=UIState();precondition(state.start());precondition(!state.start());checks+=1
    state.phase = .recording;state.elapsed=12;state.estimated=0.001
    state.text(id:"sentence",value:"partial one");state.text(id:"sentence",value:"partial two");state.text(id:"sentence",value:"final")
    precondition(state.order.count==1 && state.transcript["sentence"]=="final");checks+=1
    precondition(state.stop() && !state.stop());state.phase = .stopped
    precondition(state.time=="00:12" && state.price=="<¥0.01");checks+=1
    state.phase = .ended;precondition(!state.start());checks+=1
    var names=SessionNames();names.set(segment:"a",name:"说话人甲");names.set(segment:"b",name:"龚灵");precondition(names.values["a"]=="说话人甲" && names.values["b"]=="龚灵");checks+=1
    names.set(segment:"a",name:"顾问甲");names.undo();precondition(names.values["a"]=="说话人甲");checks+=1
    names.set(segment:"a",name:"");precondition(names.values["a"]==nil);names.undo();precondition(names.values["a"]=="说话人甲");checks+=1
    names.reset();names.undo();precondition(names.values.isEmpty);checks+=1
    print("{\"type\":\"ui_model_validation\",\"passed\":\(checks),\"keychain\":false,\"clipboard\":false,\"capture\":false,\"network\":false}")
}
