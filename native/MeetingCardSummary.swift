import AppKit
import Foundation

private struct MeetingSummaryIdentity:Hashable {
    let session:String
    let source:String
    let epoch:String
    let identity:String
}

private struct MeetingSummaryPerson {
    var title:String
    var hasDisplayName=false
    var intervals:[(Double,Double)] = []
}

private struct MeetingSummaryFileStamp:Equatable {
    let path:String
    let size:Int
    let modified:TimeInterval

    init(_ url:URL) {
        path=url.standardizedFileURL.path
        let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        size=values?.fileSize ?? -1
        modified=values?.contentModificationDate?.timeIntervalSince1970 ?? -1
    }
}

private struct MeetingSummarySignature:Equatable {
    let files:[MeetingSummaryFileStamp]
    let voiceArchiveRevision:Int?
    let enabledVoicePersonIDs:[String]

    init(_ meeting:CachedMeeting,voiceArchive:VoiceprintArchive?) {
        let names=meeting.tracks.sorted().map{meeting.directory.appendingPathComponent($0+"-transcript.jsonl")}
        let fixed=["meeting.json","session-names.json","speaker-reconciliation.json",SpeakerRefinementArtifact.filename,MeetingCoarseRefinement.filename,"coarse-refinement-preference.json"].map{meeting.directory.appendingPathComponent($0)}
        files=(names+fixed).map(MeetingSummaryFileStamp.init)
        voiceArchiveRevision=voiceArchive?.revision
        enabledVoicePersonIDs=(voiceArchive?.people.filter(\.enabled).map(\.id) ?? []).sorted()
    }
}

func meetingSummaryVoiceArchive()->VoiceprintArchive? {
    let info=Bundle.main.infoDictionary ?? [:]
    // Development and offline QA builds must stay inside their synthetic
    // namespace even when the real user's archive exists on the same Mac.
    let developmentQA=info["OfflineQA"] as? Bool==true || info["DevelopmentWorkspace"] as? Bool==true
    let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    let folder=RuntimeConfiguration.dataRoot().appendingPathComponent(developmentQA ? "DevelopmentQA/Voiceprints":"Voiceprints")
    let domain=developmentQA ? "synthetic_model_output":"consented_live_audio"
    return try? VoiceprintArchiveStore(folder:folder,domain:domain).load()
}

private final class MeetingSummaryCache:@unchecked Sendable {
    static let shared=MeetingSummaryCache()
    private let lock=NSLock()
    private var values:[String:(MeetingSummarySignature,[String])]=[:]

    func value(for id:String,signature:MeetingSummarySignature)->[String]? {
        lock.lock();defer{lock.unlock()}
        guard let cached=values[id],cached.0==signature else{return nil}
        return cached.1
    }

    func store(_ summary:[String],for id:String,signature:MeetingSummarySignature) {
        lock.lock();defer{lock.unlock()}
        values[id]=(signature,summary)
        if values.count>1_000,let first=values.keys.first {values.removeValue(forKey:first)}
    }
}

/// Returns named speaker labels ordered by accumulated, overlap-deduplicated
/// speech duration. Automatic names retain their visible origin marker.
/// Unknown and unresolved overlap rows are intentionally omitted.
/// The meeting library calls this from its background read job; file signatures
/// keep card rendering from rescanning full transcripts on every table refresh.
func meetingParticipantSummary(_ item:CachedMeeting,voiceArchive:VoiceprintArchive?=meetingSummaryVoiceArchive())->[String] {
    let cacheID=item.directory.standardizedFileURL.path+"\u{001F}"+item.id
    let signature=MeetingSummarySignature(item,voiceArchive:voiceArchive)
    if let cached=MeetingSummaryCache.shared.value(for:cacheID,signature:signature) {return cached}
    guard let events=try? item.events(),let metadata=try? item.metadata(),
          let session=metadata["session"] as? String,!session.isEmpty else {return []}

    var names=SessionNames()
    for event in events {
        guard let parent=event["segment_id"] as? String else{continue}
        names.register(segment:parent,item:event)
        for run in TranscriptTimeline.speakerRuns(event) {
            names.register(segment:TranscriptTimeline.runID(parent:parent,run:run),item:run)
        }
    }
    let namesFile=item.directory.appendingPathComponent("session-names.json")
    if let data=try? Data(contentsOf:namesFile) {try? names.restore(data,session:session,events:events,directory:item.directory)}

    names.validateVoiceprintArchive(voiceArchive)
    var people:[MeetingSummaryIdentity:MeetingSummaryPerson]=[:]
    func add(identity:MeetingSummaryIdentity?,manualID:String?,manualName:String?,start:Double,end:Double,segment:String?=nil) {
        guard start.isFinite,end.isFinite,start>=0,end>start,end<1e8 else{return}
        if let key=identity {
            let speakerKey=SessionSpeakerKey(session:key.session,source:key.source,epoch:key.epoch,identity:key.identity)
            let canonical=names.canonical(speakerKey)
            let display=segment.flatMap{names.displayName(segment:$0)} ?? names.displayName(speaker:canonical)
            let spanVoice=display?.origin == .voiceprint && names.displayName(speaker:canonical)==nil
            let normalized=MeetingSummaryIdentity(session:canonical.session,source:canonical.source,epoch:canonical.epoch,identity:canonical.identity+(spanVoice ? ":recognized:"+(names.voiceSuggestion(for:canonical)?.personID ?? ""):""))
            let title:String
            if let display {title=display.visibleValue}
            else if let suggestion=names.voiceSuggestion(for:canonical),suggestion.recognizedSupport==nil,
                    let archive=voiceArchive,archive.revision==suggestion.archiveRevision,
                    let person=archive.people.first(where:{$0.id==suggestion.personID && $0.enabled && $0.name==suggestion.name}) {title="可能是"+person.name}
            else {title=names.displayLabel(speaker:canonical)}
            var person=people[normalized] ?? MeetingSummaryPerson(title:title)
            person.title=title;person.hasDisplayName = person.hasDisplayName || display != nil
            person.intervals.append((start,end));people[normalized]=person
        } else if let manualID=manualID,let manualName=manualName,!manualName.isEmpty {
            // A sentence-level manual name confirms this utterance, but does not
            // establish a reusable identity shared with any other utterance.
            let oneOff=MeetingSummaryIdentity(session:session,source:"manual",epoch:"",identity:manualID)
            var person=people[oneOff] ?? MeetingSummaryPerson(title:manualName)
            person.intervals.append((start,end));people[oneOff]=person
        }
    }
    func identity(_ id:String,_ row:[String:Any])->MeetingSummaryIdentity? {
        guard let key=names.key(segment:id) ?? SessionSpeakerKey.from(row),key.session==session else{return nil}
        let canonical=names.canonical(key)
        return MeetingSummaryIdentity(session:canonical.session,source:canonical.source,epoch:canonical.epoch,identity:canonical.identity)
    }

    for event in events {
        guard let parent=event["segment_id"] as? String else{continue}
        if let manualName=names.sentenceName(segment:parent),
           let start=event["start"] as? Double,let end=event["end"] as? Double {
            add(identity:nil,manualID:parent,manualName:manualName,start:start,end:end)
            continue
        }
        let runs=TranscriptTimeline.speakerRuns(event)
        let overrides=names.manualRunOverrides(parent:parent,item:event)
        if !overrides.isEmpty,let words=event["word_spans"] as? [[String:Any]] {
            for word in words {
                guard let lo=word["start"] as? Double,let hi=word["end"] as? Double,hi>lo else{continue}
                let override=overrides.filter{$0.start<=lo+1e-6 && $0.end>=hi-1e-6}.min{($0.end-$0.start)<($1.end-$1.start)}
                let run=runs.first{($0["start"] as? Double ?? .infinity)<=lo+1e-6 && ($0["end"] as? Double ?? -.infinity)>=hi-1e-6}
                if let owner=override?.id {
                    let overrideIdentity=names.key(segment:owner).map{key in
                        let canonical=names.canonical(key)
                        return MeetingSummaryIdentity(session:canonical.session,source:canonical.source,epoch:canonical.epoch,identity:canonical.identity)
                    }
                    add(identity:overrideIdentity,manualID:overrideIdentity==nil ? owner:nil,
                        manualName:overrideIdentity==nil ? names.sentenceName(segment:owner):nil,start:lo,end:hi)
                } else {
                    let row=run ?? event
                    let rowID=run.map{TranscriptTimeline.runID(parent:parent,run:$0)} ?? parent
                    add(identity:identity(rowID,row),manualID:nil,manualName:nil,start:lo,end:hi,segment:rowID)
                }
            }
            continue
        }
        if !runs.isEmpty {
            for run in runs {
                guard let start=run["start"] as? Double,let end=run["end"] as? Double else{continue}
                let runID=TranscriptTimeline.runID(parent:parent,run:run)
                add(identity:identity(runID,run),manualID:nil,manualName:nil,start:start,end:end,segment:runID)
            }
        } else if let start=event["start"] as? Double,let end=event["end"] as? Double {
            add(identity:identity(parent,event),manualID:nil,manualName:nil,start:start,end:end,segment:parent)
        }
    }

    // Established display names share one meeting-local presentation regardless
    // of recognition source. This never merges acoustic identities or profiles;
    // unresolved suggestions and one-off sentence labels remain distinct.
    var displayPeople:[String:MeetingSummaryPerson]=[:]
    for (key,person) in people {
        let identityKey=key.session+"\u{001F}"+key.source+"\u{001F}"+key.epoch+"\u{001F}"+key.identity
        let groupKey=person.hasDisplayName ? "name:\(person.title)":"identity:\(identityKey)"
        var grouped=displayPeople[groupKey] ?? MeetingSummaryPerson(title:person.title,hasDisplayName:person.hasDisplayName)
        grouped.intervals.append(contentsOf:person.intervals);displayPeople[groupKey]=grouped
    }
    var ranked:[(String,Double,String)]=[]
    for (key,person) in displayPeople {
        let sorted=person.intervals.sorted{$0.0 == $1.0 ? $0.1<$1.1:$0.0<$1.0}
        var duration=0.0,lower:Double?,upper:Double?
        for interval in sorted {
            if let currentUpper=upper,interval.0<=currentUpper {
                upper=max(currentUpper,interval.1)
            } else {
                if let lower=lower,let upper=upper {duration+=upper-lower}
                lower=interval.0;upper=interval.1
            }
        }
        if let lower=lower,let upper=upper {duration+=upper-lower}
        ranked.append((person.title,duration,key))
    }
    ranked.sort {
        if $0.1 != $1.1 {return $0.1>$1.1}
        if $0.0 != $1.0 {return $0.0.localizedStandardCompare($1.0) == .orderedAscending}
        return $0.2<$1.2
    }
    let participantNames=ranked.map(\.0)

    // Avoid caching a half-read result while an active recording appends rows.
    let afterRead=MeetingSummarySignature(item,voiceArchive:voiceArchive)
    if afterRead==signature {MeetingSummaryCache.shared.store(participantNames,for:cacheID,signature:signature)}
    return participantNames
}

/// Small participant line for a meeting card. Long lists scroll only while the
/// view is hovered and visible, and the system has not requested reduced motion.
final class MeetingParticipantLabel:NSView {
    private var storedNames:[String]=[]
    var names:[String] {
        get{storedNames}
        set{storedNames=Self.cleaned(newValue);text=storedNames.joined(separator:"  ·  ");setAccessibilityLabel(text.isEmpty ? "参会人" : "参会人："+text);toolTip=text;isHidden=text.isEmpty;offset=0;needsDisplay=true;updateTimer()}
    }
    var fontSize:CGFloat=11 {didSet{needsDisplay=true;updateTimer()}}
    private var text=""
    private var offset:CGFloat=0
    private var previousTick=ProcessInfo.processInfo.systemUptime
    private var hoverTracking:NSTrackingArea?
    private var hovered=false
    private var timer:Timer?
    private let gap:CGFloat=52

    override init(frame:NSRect) {super.init(frame:frame);configureAccessibility()}
    required init?(coder:NSCoder) {super.init(coder:coder);configureAccessibility()}
    convenience init(names:[String],fontSize:CGFloat=11) {self.init(frame:.zero);self.fontSize=fontSize;self.names=names}
    deinit {timer?.invalidate();NSWorkspace.shared.notificationCenter.removeObserver(self)}

    private static func cleaned(_ values:[String])->[String] {
        values.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
    }
    private func configureAccessibility() {
        setAccessibilityElement(true);setAccessibilityRole(.staticText);setAccessibilityLabel("参会人")
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(accessibilityOptionsChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    @objc private func accessibilityOptionsChanged(){updateTimer();needsDisplay=true}
    override func updateTrackingAreas() {
        if let area=hoverTracking {removeTrackingArea(area)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);hoverTracking=area;super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) {hovered=true;updateTimer()}
    override func mouseExited(with event:NSEvent) {hovered=false;offset=0;needsDisplay=true;updateTimer()}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();updateTimer()}
    override func viewDidMoveToSuperview() {super.viewDidMoveToSuperview();updateTimer()}
    override func setFrameSize(_ newSize:NSSize) {super.setFrameSize(newSize);updateTimer()}
    override func layout() {super.layout();updateTimer()}
    override func viewWillDraw() {super.viewWillDraw();updateTimer()}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:17)}

    private func lineAttributes()->[NSAttributedString.Key:Any] {
        [.font:NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor.secondaryLabelColor]
    }
    private var lineWidth:CGFloat {text.size(withAttributes:lineAttributes()).width}
    private var reduceMotion:Bool {NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    private func updateTimer() {
        let shouldRun=window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && hovered && !reduceMotion && bounds.width>0 && !text.isEmpty && lineWidth>bounds.width
        guard shouldRun else {timer?.invalidate();timer=nil;return}
        guard timer==nil else{return}
        previousTick=ProcessInfo.processInfo.systemUptime
        timer=Timer.scheduledTimer(withTimeInterval:1.0/30.0,repeats:true){[weak self] _ in self?.advance()}
        if let timer=timer {RunLoop.main.add(timer,forMode:.common)}
    }
    private func advance() {
        guard window != nil,!isHiddenOrHasHiddenAncestor,!visibleRect.isEmpty,hovered,!reduceMotion else {updateTimer();return}
        let now=ProcessInfo.processInfo.systemUptime;let elapsed=min(0.1,max(0,now-previousTick));previousTick=now
        let cycle=lineWidth+gap
        guard cycle>0 else{return}
        offset=(offset+CGFloat(elapsed)*12).truncatingRemainder(dividingBy:cycle);needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard !text.isEmpty else{return}
        let attributes=lineAttributes(),width=lineWidth
        let y=max(0,(bounds.height-fontSize-2)/2)
        if reduceMotion || width<=bounds.width {
            NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:bounds).addClip()
            (text as NSString).draw(at:NSPoint(x:0,y:y),withAttributes:attributes)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:bounds).addClip()
        let cycle=width+gap;let first = -offset
        (text as NSString).draw(at:NSPoint(x:first,y:y),withAttributes:attributes)
        (text as NSString).draw(at:NSPoint(x:first+cycle,y:y),withAttributes:attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor func meetingCardSummaryChecks(directory:URL)throws->Int {
    guard Credential.offline,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else{throw Failure(code:"meeting_card_summary_scope")}
    let folder=directory.appendingPathComponent("meeting-card-summary-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let session="meeting-card-summary-fixture"
    func event(_ id:String,_ source:String,_ cluster:Int?,_ start:Double,_ end:Double)->[String:Any] {
        var speaker:[String:Any]=["basis":"unknown","reason":"no_speaker_evidence"]
        if let cluster=cluster {speaker=["basis":"anonymous_cluster","cluster_id":cluster,"source_id":source,"epoch":"epoch"]}
        return ["type":"segment","session":session,"segment_id":id,"source_id":source,"track":source,
                "epoch":"epoch","start":start,"end":end,"text":id,"revision":1,"final":true,"speaker":speaker]
    }
    let rows=[event("a","mic",0,0,5),event("c","mic",1,12,15),event("d","mic",2,16,18),event("unknown","mic",nil,30,60),event("b","remote",0,3,9),event("a2","mic",0,8,10),
              event("suggested-0","mic",3,40,44),event("suggested-1","mic",3,50,54),event("suggested-2","mic",3,60,64)]
    try JSONSerialization.data(withJSONObject:["session":session],options:[.sortedKeys]).write(to:folder.appendingPathComponent("meeting.json"),options:.atomic)
    for track in ["mic","remote"] {
        let trackRows=rows.filter{($0["track"] as? String)==track}
        let data=try trackRows.map{try JSONSerialization.data(withJSONObject:$0)}.reduce(into:Data()){$0.append($1);$0.append(10)}
        try data.write(to:folder.appendingPathComponent(track+"-transcript.jsonl"),options:.atomic)
    }
    var names=SessionNames()
    for row in rows {names.register(segment:row["segment_id"] as! String,item:row)}
    guard let mainKey=names.key(segment:"a"),let remoteKey=names.key(segment:"b"),
          names.key(segment:"c") != nil else{throw Failure(code:"meeting_card_summary_fixture_keys")}
    names.setSpeaker(segment:"a",name:"主要人物")
    names.setSpeaker(segment:"c",name:"次要人物")
    names.setSpeaker(segment:"d",name:"主要人物")
    guard names.mergeSpeaker(from:remoteKey,to:mainKey,humanConfirmed:true) else{throw Failure(code:"meeting_card_summary_fixture_merge")}
    guard let suggestionKey=names.key(segment:"suggested-0") else{throw Failure(code:"meeting_card_summary_suggestion_key")}
    let suggestion=VoiceprintRecommendation(personID:"00000000-0000-4000-8000-000000000021",name:"测试人物甲",archiveRevision:1,evidenceCount:3,
        support:(0..<3).map{VoiceprintEvidenceRef(id:"suggested-\($0)",revision:1)},groupConsistent:false)
    guard names.reconcileAutoVoiceprint(key:suggestionKey,candidate:suggestion),names.displayName(speaker:suggestionKey)==nil,
          names.name(speaker:suggestionKey)==nil else{throw Failure(code:"meeting_card_partial_voice_suggestion_setup")}
    try names.snapshot(session:session).write(to:folder.appendingPathComponent("session-names.json"),options:.atomic)
    let item=CachedMeeting(id:folder.lastPathComponent,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,
                           occupiedBytes:0,tracks:["mic","remote"],audioCleaned:false,warning:false,retiredBytes:0)
    let voicePersonID="00000000-0000-4000-8000-000000000021"
    let enabledArchive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"consented_live_audio",revision:1,
        people:[VoiceprintPerson(id:voicePersonID,name:"测试人物甲",authorizedAt:"2026-10-14T00:00:00Z",enabled:true,samples:[])])
    let summary=meetingParticipantSummary(item,voiceArchive:enabledArchive)
    guard summary.contains("主要人物"),summary.contains("次要人物"),summary.contains("可能是测试人物甲"),!summary.contains("测试人物甲（声音识别）") else{throw Failure(code:"meeting_card_summary_ranking_or_unknown_filter")}
    guard meetingParticipantSummary(item,voiceArchive:enabledArchive)==summary else{throw Failure(code:"meeting_card_summary_memoized_repeat")}
    let disabledArchive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"consented_live_audio",revision:2,
        people:[VoiceprintPerson(id:voicePersonID,name:"测试人物甲",authorizedAt:"2026-10-14T00:00:00Z",enabled:false,samples:[])])
    guard !meetingParticipantSummary(item,voiceArchive:disabledArchive).contains("可能是测试人物甲") else{throw Failure(code:"meeting_card_disabled_voice_candidate_visible")}
    let revisedArchive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"consented_live_audio",revision:2,
        people:[VoiceprintPerson(id:voicePersonID,name:"测试人物甲",authorizedAt:"2026-10-14T00:00:00Z",enabled:true,samples:[])])
    guard !meetingParticipantSummary(item,voiceArchive:revisedArchive).contains("可能是测试人物甲") else{throw Failure(code:"meeting_card_stale_voice_archive_revision_visible")}
    let spanSupport=(0..<3).map{VoiceprintEvidenceRef(id:"suggested-\($0)",revision:1)}
    let recognized=VoiceprintRecommendation(personID:voicePersonID,name:"测试人物甲",archiveRevision:1,evidenceCount:3,support:spanSupport,groupConsistent:false,recognizedSupport:spanSupport)
    guard names.reconcileAutoVoiceprint(key:suggestionKey,candidate:recognized) else{throw Failure(code:"meeting_card_span_setup")}
    try names.snapshot(session:session).write(to:folder.appendingPathComponent("session-names.json"),options:.atomic)
    let spanSummary=meetingParticipantSummary(item,voiceArchive:enabledArchive)
    guard spanSummary.contains("测试人物甲") && !spanSummary.contains("（声音识别）"),!spanSummary.contains("可能是测试人物甲") else{throw Failure(code:"meeting_card_identified_spans_show_actual_name")}
    let empty=MeetingParticipantLabel(names:[])
    guard empty.isHidden else{throw Failure(code:"meeting_card_empty_hidden")}
    let populated=MeetingParticipantLabel(names:summary)
    guard !populated.isHidden,populated.names==summary else{throw Failure(code:"meeting_card_participant_label_values")}
    return 8
}
