import Foundation

struct SpeakerReviewEntry {
    let turn:ReadingTurn
    let personKey:SessionSpeakerKey?
    let partIDs:[String]
    let possiblePeople:[SessionSpeakerKey]
    let reason:String?
    let unresolvedPartIDs:Set<String>
    let simultaneousParticipants:[SessionSpeakerKey]

    var id:String {turn.id}
    var parent:String {turn.parent}
    var start:Double {TranscriptTimeline.start(turn.parts.first?.1 ?? turn.item)}
    var end:Double {(turn.parts.last?.1 ?? turn.item)["end"] as? Double ?? start}
    var text:String {turn.parts.isEmpty ? turn.item["text"] as? String ?? "" : turn.parts.map{$0.1["text"] as? String ?? ""}.joined()}
    var source:String? {turn.item["source_id"] as? String}
}

struct SpeakerReviewPerson {
    let key:SessionSpeakerKey
    let keys:[SessionSpeakerKey]
    let title:String
    let entries:[SpeakerReviewEntry]
    var id:String {[key.session,key.source,key.epoch,key.identity].joined(separator:"\u{001F}")}
}

/// Read-only meeting-local projection for speaker review. Original transcript rows
/// remain owned by TranscriptTimeline; display entries may project only selected
/// parts while retaining the original turn and parent for navigation.
struct SpeakerReviewIndex {
    let session:String
    let people:[SpeakerReviewPerson]
    let unassigned:[SpeakerReviewEntry]
    let simultaneous:[SpeakerReviewEntry]

    static func build(session:String,turns:[ReadingTurn],names:SessionNames)->SpeakerReviewIndex {
        var grouped:[SessionSpeakerKey:[SpeakerReviewEntry]]=[:]
        var unknown:[SpeakerReviewEntry]=[]
        var simultaneous:[SpeakerReviewEntry]=[]
        for turn in turns {
            let parts=turn.parts.isEmpty ? [(turn.id,turn.item)] : turn.parts
            let keyedParts=parts.map { id,item -> (String,[String:Any],SessionSpeakerKey?) in
                guard let value=names.key(segment:id) ?? SessionSpeakerKey.from(item),value.session==session else{return (id,item,nil)}
                return (id,item,names.canonical(value))
            }
            let speaker=turn.item["speaker"] as? [String:Any] ?? [:]
            let unique=Set(keyedParts.compactMap{$0.2})
            let unknownParts=keyedParts.filter{$0.2==nil}.map{($0.0,$0.1)}
            let possible=unique.sorted{Self.less($0,$1)}
            func entry(_ selected:[(String,[String:Any],SessionSpeakerKey?)],person:SessionSpeakerKey?,unresolved:Set<String>,reason:String?)->SpeakerReviewEntry {
                let projected=selected.map{($0.0,$0.1)}
                var projectedTurn=turn
                projectedTurn.parts=projected
                return SpeakerReviewEntry(turn:projectedTurn,personKey:person,partIDs:projected.map{$0.0},
                                          possiblePeople:possible,reason:reason,unresolvedPartIDs:unresolved,
                                          simultaneousParticipants:[])
            }
            let unresolved=Set(unknownParts.map{$0.0})
            if unique.isEmpty,speaker["basis"] as? String == "multiple",speaker["reason"] as? String == "overlap" {
                let explicitSingleName = !keyedParts.isEmpty && keyedParts.allSatisfy {
                    names.displayName(segment:$0.0)?.origin == .manual
                }
                if explicitSingleName {
                    unknown.append(entry(keyedParts,person:nil,unresolved:Set(parts.map{$0.0}),reason:"overlap"))
                } else if let participants=simultaneousParticipants(item:turn.item,session:session,names:names) {
                    if confirmedSharedName(participants,names:names) != nil,let person=participants.first {
                        // Two diarizer slots may be manually confirmed as the same
                        // person. Keep the turn in that person's review group and
                        // avoid reporting a false simultaneous-speaker event.
                        grouped[person,default:[]].append(entry(keyedParts,person:person,unresolved:[],reason:nil))
                    } else {
                        var projected=entry(keyedParts,person:nil,unresolved:[],reason:"overlap")
                        projected=SpeakerReviewEntry(turn:projected.turn,personKey:nil,partIDs:projected.partIDs,
                            possiblePeople:participants,reason:"overlap",unresolvedPartIDs:[],simultaneousParticipants:participants)
                        simultaneous.append(projected)
                    }
                } else {
                    unknown.append(entry(keyedParts,person:nil,unresolved:Set(parts.map{$0.0}),reason:"overlap"))
                }
            } else if unique.count==1,let person=unique.first {
                // Keep the whole turn as context for the sole known person, but
                // make unknown parts independently reviewable and actionable.
                grouped[person,default:[]].append(entry(keyedParts,person:person,unresolved:unresolved,reason:nil))
                if !unknownParts.isEmpty {
                    let unknownKeyed=unknownParts.map{($0.0,$0.1,Optional<SessionSpeakerKey>.none)}
                    let reason=(speaker["reason"] as? String) ?? "unassigned"
                    unknown.append(entry(unknownKeyed,person:nil,unresolved:Set(unknownParts.map{$0.0}),reason:reason))
                }
            } else if unique.count>1 {
                // A mixed multi-person turn cannot be attributed wholesale.
                // Group its known source parts by identity; unknown parts remain
                // separate in the unresolved view.
                for person in possible {
                    let personParts=keyedParts.filter{$0.2==person}
                    grouped[person,default:[]].append(entry(personParts,person:person,unresolved:[],reason:nil))
                }
                if !unknownParts.isEmpty {
                    let unknownKeyed=unknownParts.map{($0.0,$0.1,Optional<SessionSpeakerKey>.none)}
                    let reason=(speaker["reason"] as? String) ?? "speaker_change"
                    unknown.append(entry(unknownKeyed,person:nil,unresolved:Set(unknownParts.map{$0.0}),reason:reason))
                }
            } else {
                let reason=(speaker["reason"] as? String) ?? "unassigned"
                unknown.append(entry(keyedParts,person:nil,unresolved:Set(parts.map{$0.0}),reason:reason))
            }
        }
        func chronological(_ a:SpeakerReviewEntry,_ b:SpeakerReviewEntry)->Bool {
            if a.start != b.start {return a.start<b.start}
            if a.end != b.end {return a.end<b.end}
            return a.id<b.id
        }
        let rawPeople=grouped.keys.map {key -> SpeakerReviewPerson in
            let entries=grouped[key]!.sorted(by:chronological)
            return SpeakerReviewPerson(key:key,keys:[key],title:names.displayName(speaker:key)?.value ?? names.displayLabel(speaker:key),entries:entries)
        }
        var peopleByDisplayName:[String:[SpeakerReviewPerson]]=[:]
        var unmergedPeople:[SpeakerReviewPerson]=[]
        for person in rawPeople {
            if names.displayName(speaker:person.key) != nil {
                peopleByDisplayName[person.title,default:[]].append(person)
            } else {unmergedPeople.append(person)}
        }
        for sameName in peopleByDisplayName.values {
            let entries=sameName.flatMap(\.entries).sorted(by:chronological)
            let primary=sameName.min {
                let a=$0.entries.first?.start ?? .greatestFiniteMagnitude
                let b=$1.entries.first?.start ?? .greatestFiniteMagnitude
                return a != b ? a<b:Self.less($0.key,$1.key)
            }!
            unmergedPeople.append(SpeakerReviewPerson(key:primary.key,
                keys:sameName.map(\.key).sorted(by:Self.less),title:primary.title,entries:entries))
        }
        let people=unmergedPeople.sorted {
            let a=$0.entries.first?.start ?? .greatestFiniteMagnitude
            let b=$1.entries.first?.start ?? .greatestFiniteMagnitude
            return a != b ? a<b:Self.less($0.key,$1.key)
        }
        return SpeakerReviewIndex(session:session,people:people,unassigned:unknown.sorted(by:chronological),
                                  simultaneous:simultaneous.sorted(by:chronological))
    }

    static func simultaneousTitle(_ entry:SpeakerReviewEntry,names:SessionNames)->String? {
        guard entry.reason=="overlap" else{return nil}
        return simultaneousTitle(item:entry.turn.item,session:entry.turn.item["session"] as? String ?? entry.simultaneousParticipants.first?.session ?? "",names:names)
    }

    static func simultaneousTitle(item:[String:Any],session:String,names:SessionNames)->String? {
        guard let participants=simultaneousParticipants(item:item,session:session,names:names) else{return nil}
        let titles=participants.compactMap{names.displayName(speaker:$0)?.value}
        guard !titles.isEmpty else{return nil}
        let uniqueTitles=Array(NSOrderedSet(array:titles)) as? [String] ?? titles
        return uniqueTitles.count==1 ? uniqueTitles[0] : uniqueTitles.joined(separator:"、")+" · 同时发言"
    }

    private static func confirmedSharedName(_ keys:[SessionSpeakerKey],names:SessionNames)->String? {
        let labels=keys.compactMap{names.displayName(speaker:$0)}
        guard labels.count==keys.count,labels.allSatisfy({$0.origin == .manual}),
              let first=labels.first?.value,labels.allSatisfy({$0.value==first}) else{return nil}
        return first
    }

    static func simultaneousParticipants(item:[String:Any],session:String,names:SessionNames)->[SessionSpeakerKey]? {
        let speaker=item["speaker"] as? [String:Any] ?? [:]
        guard speaker["basis"] as? String=="multiple",speaker["reason"] as? String=="overlap",
              let slots=speaker["cluster_ids"] as? [Int],slots.count>=2,Set(slots).count==slots.count,
              item["session"] as? String==session,
              let source=item["source_id"] as? String,isTranscriptAudioTrack(source),
              let epoch=item["epoch"] as? String,!epoch.isEmpty,!session.isEmpty else{return nil}
        let keys=names.choices(session:session).map{names.canonical($0)}
        var participants:[SessionSpeakerKey]=[]
        for slot in slots {
            guard (0..<8).contains(slot) else{return nil}
            let candidate=SessionSpeakerKey(session:session,source:source,epoch:epoch,identity:"slot:\(slot)")
            guard let key=keys.first(where:{$0==names.canonical(candidate)}),
                  let name=names.displayName(speaker:key),name.origin == .manual || name.origin == .voiceprint else{return nil}
            if !participants.contains(key) {participants.append(key)}
        }
        return participants.isEmpty ? nil:participants
    }

    private static func less(_ a:SessionSpeakerKey,_ b:SessionSpeakerKey)->Bool {
        if a.source != b.source {return a.source<b.source}
        if a.epoch != b.epoch {return a.epoch<b.epoch}
        return a.identity<b.identity
    }
}
