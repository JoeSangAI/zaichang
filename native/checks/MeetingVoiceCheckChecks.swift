import Foundation

/// Offline: synthetic unit vectors only; no audio, model or network.
func meetingVoiceCheckChecks() throws {
    func fail(_ code:String) -> Failure {Failure(code:code)}
    func unit(_ values:[Double])->[Double] {let n=sqrt(values.reduce(0){$0+$1*$1});return values.map{$0/n}}
    let lin=unit([1,0,0,0]),zhou=unit([0,1,0,0])
    func near(_ a:[Double],_ b:[Double],_ t:Double)->[Double] {unit(zip(a,b).map{$0*(1-t)+$1*t})}
    typealias S=MeetingVoiceCheck.Span
    let spans=[
        S(id:"a1",parent:"p1",source:"app",start:0,end:6),
        S(id:"a2",parent:"p2",source:"app",start:10,end:16),
        S(id:"b1",parent:"p3",source:"app",start:20,end:26),
        S(id:"b2",parent:"p4",source:"app",start:30,end:36),
        // A line inherited under the wrong voice: sounds like 林晓.
        S(id:"u1",parent:"p5",source:"app",start:40,end:46),
        S(id:"s1",parent:"p5",source:"app",start:46.2,end:47),
        S(id:"u2",parent:"p5",source:"app",start:47.5,end:52),
        // Halfway between the two voices: left alone.
        S(id:"u3",parent:"p6",source:"app",start:60,end:66),
        // Short line between two different people: left alone.
        S(id:"s2",parent:"p6",source:"app",start:66.5,end:67),
        S(id:"u4",parent:"p7",source:"app",start:67.5,end:72),
        // Too short to judge on its own and not between one person.
        S(id:"s3",parent:"p8",source:"app",start:80,end:81),
    ]
    let pinned=["a1":"林晓","p2":"林晓","b1":"周岚","b2":"周岚"]
    let vectors:[String:[[Double]]]=["a1":[lin,lin],"a2":[near(lin,zhou,0.05)],"b1":[zhou],"b2":[near(zhou,lin,0.05)],
                                     "u1":[near(lin,zhou,0.1),lin],"u2":[near(lin,zhou,0.15)],"u3":[near(lin,zhou,0.5)],
                                     "u4":[zhou],"s1":[zhou],"s2":[lin],"s3":[lin]]
    let verdicts=MeetingVoiceCheck.decide(spans:spans,pinned:pinned,vectors:vectors)
    guard verdicts["u1"]?.name=="林晓",verdicts["u1"]?.between==false,verdicts["u2"]?.name=="林晓",
          verdicts["s1"]==MeetingVoiceCheck.Verdict(name:"林晓",score:0,margin:0,between:true),
          verdicts["u3"]==nil,verdicts["u4"]?.name=="周岚",verdicts["s2"]==nil,verdicts["s3"]==nil,
          verdicts["a1"]==nil,verdicts["a2"]==nil,verdicts["b1"]==nil else{throw fail("voice_check_decide")}
    // One window of a person is not enough to name anyone after them.
    let thin=MeetingVoiceCheck.decide(spans:spans,pinned:["a1":"林晓","b1":"周岚"],vectors:["a1":[lin],"b1":[zhou],"u1":[lin]])
    guard thin.isEmpty else{throw fail("voice_check_needs_two_samples")}
    guard MeetingVoiceCheck.windows(0,1.4).isEmpty,MeetingVoiceCheck.windows(0,2).count==1,MeetingVoiceCheck.windows(0,9.5).count==3 else{throw fail("voice_check_windows")}
    // A long meeting must finish inside the helper's time limit: each long
    // line is judged from a few spread windows, and the limit is the same
    // 30 minutes every other meeting helper gets (0.4.23 gave it 5).
    let spread=MeetingVoiceCheck.lineWindows(0,600)
    guard spread.count==MeetingVoiceCheck.lineWindowLimit,spread.first!.0==0,spread.last!.1==600,
          MeetingVoiceCheck.lineWindows(0,9.5).count==3,
          MeetingVoiceCheck.helperTimeout>=1800 else{throw fail("voice_check_long_meeting_budget")}

    // Only names the user set for a line count; a voice's inherited name does not.
    let key:[String:Any]=["session":"s","source":"app","epoch":"e","identity":"slot:1"]
    let other:[String:Any]=["session":"s","source":"app","epoch":"e","identity":"slot:2"]
    let names:[String:Any]=["session":"s","sentences":["x1":"林晓"],
                            "speakers":[["key":key,"name":"周岚"]],
                            "assignments":[["id":"x2","key":other]],
                            "aliases":[["from":other,"to":key]]]
    guard MeetingVoiceCheck.pinnedNames(names)==["x1":"林晓","x2":"周岚"] else{throw fail("voice_check_pinned")}
    var shuffled=names;shuffled["speakers"]=[["name":"周岚","key":key]]
    shuffled["assignments"]=[["key":other,"id":"x2"]]
    guard MeetingVoiceCheck.namesDigest(names)==MeetingVoiceCheck.namesDigest(shuffled),
          MeetingVoiceCheck.namesDigest(names) != MeetingVoiceCheck.namesDigest(names.merging(["sentences":["x1":"周岚"]]){$1}) else{throw fail("voice_check_digest")}

    // Saved result: shown only for the names it was made for, and a line the
    // user names afterwards stays theirs.
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("voice-check-\(UUID().uuidString)")
    defer{try? FileManager.default.removeItem(at:root)}
    let cache=UUID().uuidString,folder=root.appendingPathComponent(cache)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let namesData=try JSONSerialization.data(withJSONObject:names)
    let result:[String:Any]=["schema":1,"method":MeetingVoiceCheck.method,"session":"s","cache_id":cache,
                             "names_sha256":MeetingVoiceCheck.namesDigest(names)!,"records":[["id":"u1","name":"林晓","score":0.9,"margin":0.4,"between":false]]]
    try MeetingVoiceCheck.write(try JSONSerialization.data(withJSONObject:result),directory:folder)
    guard MeetingVoiceCheck.load(directory:folder,session:"s",namesData:namesData)==["u1":"林晓"],
          MeetingVoiceCheck.load(directory:folder,session:"s",namesData:try JSONSerialization.data(withJSONObject:names.merging(["sentences":["x1":"周岚"]]){$1})).isEmpty,
          MeetingVoiceCheck.load(directory:folder,session:"other",namesData:namesData).isEmpty else{throw fail("voice_check_load")}
    try namesData.write(to:folder.appendingPathComponent("session-names.json"))
    guard !MeetingVoiceCheck.isStale(directory:folder,session:"s") else{throw fail("voice_check_fresh")}
    try JSONSerialization.data(withJSONObject:names.merging(["sentences":["x1":"林晓","x3":"周岚"]]){$1}).write(to:folder.appendingPathComponent("session-names.json"))
    guard MeetingVoiceCheck.isStale(directory:folder,session:"s") else{throw fail("voice_check_stale")}

    var naming=SessionNames()
    naming.applyVoiceChecks(["u1":"林晓"])
    guard naming.displayName(segment:"u1")?.value=="林晓",naming.displayName(segment:"u1")?.origin == .voiceCheck,
          naming.voiceCheckName(segment:"u1")=="林晓" else{throw fail("voice_check_display")}
    naming.set(segment:"u1",name:"周岚")
    guard naming.displayName(segment:"u1")?.value=="周岚",naming.displayName(segment:"u1")?.origin == .manual,
          naming.voiceCheckName(segment:"u1")==nil else{throw fail("voice_check_manual_wins")}
}
