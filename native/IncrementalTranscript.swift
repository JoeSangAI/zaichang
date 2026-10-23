import AppKit

struct TranscriptRenderedBlock {
    let turn:ReadingTurn
    let attributed:NSAttributedString
    let partRanges:[String:NSRange]
    let identities:Set<String>
}
extension NSAttributedString.Key {
    static let zaichangTurnHeader=NSAttributedString.Key("ZaichangTurnHeader")
}
/// Marks one rendered header line. Collapsing a header only changes attributes,
/// never characters, so part ranges, selection and anchors stay valid.
final class TranscriptTurnHeader:NSObject {
    let continuationKey:String?
    let start:Double
    let end:Double
    var collapsed=false
    var original:NSAttributedString?
    init(continuationKey:String?,start:Double,end:Double) {self.continuationKey=continuationKey;self.start=start;self.end=end}
    static let continuationGap:Double=60

    /// A turn by the same speaker on the same source shortly after the previous
    /// one reads as the next paragraph of that speaker: its header is folded.
    /// With `near`, only headers around those character ranges are revisited
    /// (incremental rendering); without it the whole storage is.
    static func refresh(_ storage:NSTextStorage,near ranges:[NSRange]?=nil) {
        let all=NSRange(location:0,length:storage.length)
        func first(_ range:NSRange,reverse:Bool)->(NSRange,TranscriptTurnHeader)? {
            var found:(NSRange,TranscriptTurnHeader)?
            guard range.length>0 else{return nil}
            storage.enumerateAttribute(.zaichangTurnHeader,in:range,options:reverse ? [.reverse]:[]) {value,r,stop in
                if let header=value as? TranscriptTurnHeader {found=(r,header);stop.pointee=true}
            }
            return found
        }
        var windows:[NSRange]=[]
        if let ranges {
            for range in ranges.sorted(by:{$0.location<$1.location}) {
                let start=min(max(0,range.location),storage.length),end=min(storage.length,range.location+range.length)
                let before=first(NSRange(location:0,length:start),reverse:true)?.0.location ?? start
                let after=first(NSRange(location:end,length:storage.length-end),reverse:false).map{NSMaxRange($0.0)} ?? end
                windows.append(NSRange(location:before,length:after-before))
            }
        } else {windows=[all]}
        var changes:[(NSRange,TranscriptTurnHeader,Bool)]=[]
        for window in windows where window.length>0 {
            var previous=first(NSRange(location:0,length:window.location),reverse:true)?.1
            storage.enumerateAttribute(.zaichangTurnHeader,in:window,options:[]) {value,range,_ in
                guard let header=value as? TranscriptTurnHeader else{return}
                let fold=header.continuationKey != nil && previous?.continuationKey==header.continuationKey
                    && header.start-(previous?.end ?? -.infinity)<=continuationGap
                // Read the actual state: a rebuilt storage reuses header objects
                // with fresh, unfolded attributes.
                let shown=((storage.attribute(.font,at:range.location+min(1,range.length-1),effectiveRange:nil) as? NSFont)?.pointSize ?? 12)>=1
                if fold == shown && !changes.contains(where:{$0.0.location==range.location}) {changes.append((range,header,fold))}
                previous=header
            }
        }
        guard !changes.isEmpty else{return}
        storage.beginEditing()
        for (range,header,fold) in changes {
            if fold {
                header.original=storage.attributedSubstring(from:range)
                let style=NSMutableParagraphStyle();style.maximumLineHeight=0.01;style.minimumLineHeight=0.01
                style.paragraphSpacing=0;style.paragraphSpacingBefore=0
                storage.setAttributes([.zaichangTurnHeader:header,.font:NSFont.systemFont(ofSize:0.01),.foregroundColor:NSColor.clear,.paragraphStyle:style],range:range)
            } else if let original=header.original,original.length==range.length,original.string==storage.attributedSubstring(from:range).string {
                storage.setAttributes([:],range:range)
                original.enumerateAttributes(in:NSRange(location:0,length:original.length),options:[]) {attributes,run,_ in
                    storage.setAttributes(attributes,range:NSRange(location:range.location+run.location,length:run.length))
                }
            }
            header.collapsed=fold
        }
        storage.endEditing()
    }
}
struct TranscriptAtomicRow {
    let id:String
    let parent:String
    let item:[String:Any]
}

struct TranscriptExportSnapshot {
    let turns:[ReadingTurn]
    let names:SessionNames
    let meetingTitle:String
    let sessionSource:String
    let phase:RecordingPhase
    let incomplete:Bool
    let observedTracks:Set<String>
    let applicationNames:[String]
    let recoveredArchiveText:String?
    let absoluteTime:MeetingAbsoluteTime?
    var translations:[String:String]=[:]

    private func identity(_ id:String,_ item:[String:Any])->String? {
        if names.sentenceName(segment:id) != nil {return "manual:"+id}
        guard let key=names.key(segment:id) ?? SessionSpeakerKey.from(item) else{return nil}
        if let name=names.displayName(segment:id),name.origin == .voiceprint,names.displayName(speaker:key)==nil {
            return [key.session,key.source,key.epoch,key.identity,"voiceprint",name.value].joined(separator:"\u{001F}")
        }
        return [key.session,key.source,key.epoch,key.identity].joined(separator:"\u{001F}")
    }
    private func label(_ id:String,_ item:[String:Any])->String {
        if let name=names.displayName(segment:id) {return name.visibleValue}
        if let key=names.key(segment:id) ?? SessionSpeakerKey.from(item) {
            if let name=names.displayName(speaker:key) {return name.visibleValue}
            return names.displayLabel(speaker:key)
        }
        let speaker=item["speaker"] as? [String:Any] ?? [:]
        return speaker["basis"] as? String=="multiple" && speaker["reason"] as? String=="overlap" ? "多人重叠":"待确认"
    }
    private func turnLabel(_ turn:ReadingTurn)->String {
        if turn.parts.contains(where:{part in let speaker=part.1["speaker"] as? [String:Any] ?? [:];return speaker["basis"] as? String=="multiple" && speaker["reason"] as? String=="overlap"}) {return "多人重叠"}
        if let part=turn.parts.first(where:{identity($0.0,$0.1) != nil}) {return label(part.0,part.1)}
        return label(turn.id,turn.item)
    }
    func text()->String {
        if let archive=recoveredArchiveText {return archive}
        let status:[RecordingPhase:String]=[.idle:"待开始",.connecting:"正在连接",.recording:"记录中",.paused:"已暂停",.stopping:"正在整理",.stopped:"已停止",.failed:"已中断",.ended:"已结束"]
        let coreTracks=Set(observedTracks.compactMap(audioSourceCoreID))
        let base=(coreTracks.contains("mic") ? ["麦克风"]:[])+(coreTracks.contains(where:{$0 != "mic"}) ? ["电脑声音"]:[])
        let observed=(base+applicationNames).joined(separator:"、")
        var rows=["会议转写原文 · 本场记录","收录范围："+sessionSource,"文字来源："+(observed.isEmpty ? "未记录":observed),"状态："+(status[phase] ?? "待开始"),"按发言时间排列。",""]
        if let absoluteTime,let start=absoluteTime.iso(0) {rows.insert("会议开始："+start+" · 时区："+absoluteTime.zone.identifier,at:4)}
        else {rows.insert("绝对时间：未记录",at:4)}
        rows.reserveCapacity(turns.count*3+7)
        for turn in turns {
            let item=turn.item,speaker=turnLabel(turn)+(turn.uncertain ? " · 部分待确认":"")
            let state=item["final"] as? Bool==true ? ((item["quality_flags"] as? [String])?.isEmpty==false ? " · 待核对":""):" · 未完成"
            rows.append("["+TranscriptTimeline.timestamp(item["start"],precise:true)+" – "+(item["end_time_known"] as? Bool==false ? "时间待确认":TranscriptTimeline.timestamp(item["end"],precise:true))+"] "+speaker+" · "+audioSourceLabel(item)+state)
            if let absoluteTime,let start=absoluteTime.iso(TranscriptTimeline.start(item)) {
                let end=item["end_time_known"] as? Bool==false ? "时间待确认":absoluteTime.iso(item["end"] as? Double ?? TranscriptTimeline.start(item),endBoundary:true) ?? "时间待确认"
                rows.append("绝对时间：["+start+" – "+end+"]")
            }
            rows.append(item["text"] as? String ?? "")
            if let translation=translations[turn.id] {rows.append("中译："+translation)}
            if turn.uncertain {
                let spans=turn.parts.filter{identity($0.0,$0.1)==nil}.map{TranscriptTimeline.timestamp($0.1["start"],precise:true)+"–"+TranscriptTimeline.timestamp($0.1["end"],precise:true)}
                rows.append("句内待确认："+spans.joined(separator:"、"))
            }
            rows.append("")
        }
        var seen=Set<String>(),changes:[String]=[]
        for turn in turns {
            for (_,part) in turn.parts {
                for change in part["coarse_name_changes"] as? [[String:String]] ?? [] {
                    guard let id=change["unit_id"],let old=change["old"],let new=change["new"] else{continue}
                    let key=[id,old,new].joined(separator:"\u{001F}")
                    if seen.insert(key).inserted {changes.append("· "+old+" → "+new)}
                }
            }
        }
        if !changes.isEmpty {rows += ["专名改动："]+changes+[""]}
        return "会议："+meetingTitle+"\n\n"+(incomplete ? "【转写未完成：以下为当前已有内容】\n\n":"")+rows.joined(separator:"\n")
    }
}

/// Ordered, length-augmented treap for transcript blocks. Appends and range lookups
/// are expected O(log n), while each text-storage edit is limited to changed blocks.
final class IncrementalTranscript {
    private struct Key:Comparable {
        let start:Double
        let parent:String
        let id:String
        static func <(a:Key,b:Key)->Bool {
            if a.start != b.start {return a.start < b.start}
            if a.parent != b.parent {return a.parent < b.parent}
            return a.id < b.id
        }
    }
    private final class Node {
        let key:Key
        let priority:UInt64
        var block:TranscriptRenderedBlock
        var left:Node?
        var right:Node?
        var subtreeLength:Int
        var subtreeCount:Int
        init(_ block:TranscriptRenderedBlock) {
            self.block=block
            key=Key(start:TranscriptTimeline.start(block.turn.item),parent:block.turn.parent,id:block.turn.id)
            priority=UInt64.random(in:UInt64.min...UInt64.max)
            subtreeLength=block.attributed.length;subtreeCount=1
        }
    }
    private var root:Node?
    private var orderedAtoms:[TranscriptAtomicRow]=[]
    private var atomsByParent:[String:[TranscriptAtomicRow]]=[:]
    private var atomByID:[String:TranscriptAtomicRow]=[:]
    private var atomShifts=0
    private var byID:[String:Node]=[:]
    private var idsByParent:[String:Set<String>]=[:]
    private var parentsByIdentity:[String:Set<String>]=[:]
    private var parentIdentities:[String:Set<String>]=[:]
    private var turnByPart:[String:String]=[:]

    private func length(_ node:Node?)->Int {node?.subtreeLength ?? 0}
    private func count(_ node:Node?)->Int {node?.subtreeCount ?? 0}
    private func update(_ node:Node) {node.subtreeLength=length(node.left)+node.block.attributed.length+length(node.right);node.subtreeCount=count(node.left)+1+count(node.right)}
    private func rotateRight(_ node:Node)->Node {let pivot=node.left!;node.left=pivot.right;pivot.right=node;update(node);update(pivot);return pivot}
    private func rotateLeft(_ node:Node)->Node {let pivot=node.right!;node.right=pivot.left;pivot.left=node;update(node);update(pivot);return pivot}
    private func insert(_ node:Node?,_ value:Node)->Node {
        guard let node=node else{return value}
        if value.key < node.key {
            node.left=insert(node.left,value)
            if node.left!.priority < node.priority {return rotateRight(node)}
        } else {
            node.right=insert(node.right,value)
            if node.right!.priority < node.priority {return rotateLeft(node)}
        }
        update(node);return node
    }
    private func merge(_ left:Node?,_ right:Node?)->Node? {
        guard let left=left else{return right};guard let right=right else{return left}
        if left.priority < right.priority {left.right=merge(left.right,right);update(left);return left}
        right.left=merge(left,right.left);update(right);return right
    }
    private func remove(_ node:Node?,_ key:Key)->Node? {
        guard let node=node else{return nil}
        if key==node.key {return merge(node.left,node.right)}
        if key < node.key {node.left=remove(node.left,key)} else {node.right=remove(node.right,key)}
        update(node);return node
    }
    private func prefixLength(before key:Key)->Int {
        var node=root,total=0
        while let current=node {
            if key <= current.key {node=current.left}
            else {total += length(current.left)+current.block.attributed.length;node=current.right}
        }
        return total
    }
    private func atomKey(_ row:TranscriptAtomicRow)->Key {Key(start:TranscriptTimeline.start(row.item),parent:row.parent,id:row.id)}
    private func atomLowerBound(_ key:Key)->Int {
        var low=0,high=orderedAtoms.count
        while low<high {let mid=(low+high)/2;if atomKey(orderedAtoms[mid])<key {low=mid+1}else{high=mid}}
        return low
    }
    private func atomIndex(_ id:String)->Int? {
        guard let row=atomByID[id] else{return nil}
        let index=atomLowerBound(atomKey(row));return index<orderedAtoms.count && orderedAtoms[index].id==id ? index:nil
    }
    private func node(atCharacter offset:Int)->(node:Node,local:Int)? {
        guard offset>=0,offset<length(root) else{return nil}
        var node=root,index=offset
        while let current=node {
            let leftLength=length(current.left)
            if index < leftLength {node=current.left}
            else if index < leftLength+current.block.attributed.length {return(current,index-leftLength)}
            else {index -= leftLength+current.block.attributed.length;node=current.right}
        }
        return nil
    }
    private func attach(_ node:Node) {
        byID[node.key.id]=node;idsByParent[node.key.parent,default:[]].insert(node.key.id)
        for part in node.block.turn.parts {turnByPart[part.0]=node.key.id}
        for identity in node.block.identities {parentsByIdentity[identity,default:[]].insert(node.key.parent);parentIdentities[node.key.parent,default:[]].insert(identity)}
    }
    private func detach(_ node:Node) {
        byID.removeValue(forKey:node.key.id);idsByParent[node.key.parent]?.remove(node.key.id)
        if idsByParent[node.key.parent]?.isEmpty==true {idsByParent.removeValue(forKey:node.key.parent)}
        for part in node.block.turn.parts {turnByPart.removeValue(forKey:part.0)}
    }

    private(set) var parentReplacements=0
    private(set) var blockInsertions=0
    private(set) var blockRemovals=0
    private(set) var charactersInserted=0
    private(set) var charactersRemoved=0
    var turnCount:Int {count(root)}
    var characterCount:Int {length(root)}
    var trackedParentCount:Int {idsByParent.count}
    var lastReplacementBlockCount=0
    var orderedAtomCount:Int {orderedAtoms.count}
    var atomShiftCount:Int {atomShifts}

    /// Replace the provider-word/run rows for one sentence. The returned parents
    /// are exactly those whose same-parent adjacency changed at an insertion edge.
    @discardableResult func replaceAtoms(parent:String,rows:[TranscriptAtomicRow])->Set<String> {
        var affected:Set<String>=[parent]
        let old=atomsByParent[parent] ?? []
        let sortedRows=rows.sorted{atomKey($0)<atomKey($1)}
        if old.count==sortedRows.count,zip(old,sortedRows).allSatisfy({atomKey($0.0)==atomKey($0.1)}) {
            for (previous,next) in zip(old,sortedRows) {
                let index=atomLowerBound(atomKey(previous));if index<orderedAtoms.count {orderedAtoms[index]=next};atomByID[next.id]=next
            }
            atomsByParent[parent]=sortedRows;return affected
        }
        let removalIndices=old.compactMap{row -> (Int,TranscriptAtomicRow)? in let i=atomLowerBound(atomKey(row));return i<orderedAtoms.count && orderedAtoms[i].id==row.id ? (i,row):nil}.sorted{$0.0>$1.0}
        for (index,_) in removalIndices {
            let before=index>0 ? orderedAtoms[index-1].parent:nil,after=index+1<orderedAtoms.count ? orderedAtoms[index+1].parent:nil
            if let before=before,let after=after,before==after {affected.insert(before)}
            if index<orderedAtoms.count {atomShifts += orderedAtoms.count-index-1}
            orderedAtoms.remove(at:index)
        }
        atomsByParent.removeValue(forKey:parent);for row in old {atomByID.removeValue(forKey:row.id)}
        for row in sortedRows {
            let index=atomLowerBound(atomKey(row));let before=index>0 ? orderedAtoms[index-1].parent:nil,after=index<orderedAtoms.count ? orderedAtoms[index].parent:nil
            if let before=before,before==parent {affected.insert(before)}
            if let after=after,after==parent {affected.insert(after)}
            if let before=before,let after=after,before==after {affected.insert(before)}
            if index<orderedAtoms.count {atomShifts += orderedAtoms.count-index}
            orderedAtoms.insert(row,at:index);atomsByParent[parent,default:[]].append(row);atomByID[row.id]=row
        }
        return affected
    }
    func replaceAllAtoms(_ rows:[TranscriptAtomicRow]) {
        orderedAtoms=rows.sorted{atomKey($0)<atomKey($1)};atomsByParent=[:];atomByID=[:]
        for row in orderedAtoms {atomsByParent[row.parent,default:[]].append(row);atomByID[row.id]=row}
    }
    func turns(forParent parent:String,identity:(String,[String:Any])->String?)->[ReadingTurn] {
        let rows=atomsByParent[parent] ?? [];guard !rows.isEmpty else{return []}
        var output:[ReadingTurn]=[],batch:[(id:String,parent:String,item:[String:Any])]=[]
        for row in rows {
            if let previous=batch.last,let a=atomIndex(previous.id),let b=atomIndex(row.id),b != a+1 {
                output.append(contentsOf:TranscriptTimeline.readingTurns(batch,identity:identity));batch=[]
            }
            batch.append((id:row.id,parent:row.parent,item:row.item))
        }
        if !batch.isEmpty {output.append(contentsOf:TranscriptTimeline.readingTurns(batch,identity:identity))}
        return output
    }

    func reset(storage:NSTextStorage) {
        let oldLength=storage.length
        if oldLength>0 {storage.deleteCharacters(in:NSRange(location:0,length:oldLength));charactersRemoved += oldLength}
        root=nil;byID=[:];idsByParent=[:];parentsByIdentity=[:];parentIdentities=[:];turnByPart=[:];orderedAtoms=[];atomsByParent=[:];atomByID=[:]
    }

    static func rebuilt(_ blocks:[TranscriptRenderedBlock],atoms:[TranscriptAtomicRow])->(IncrementalTranscript,NSAttributedString) {
        let index=IncrementalTranscript(),text=NSMutableAttributedString(string:"")
        for block in blocks {text.append(block.attributed);let node=Node(block);index.root=index.insert(index.root,node);index.attach(node)}
        index.orderedAtoms=atoms.sorted{index.atomKey($0)<index.atomKey($1)}
        for row in index.orderedAtoms {index.atomByID[row.id]=row;index.atomsByParent[row.parent,default:[]].append(row)}
        index.parentReplacements=blocks.count;index.blockInsertions=blocks.count;index.charactersInserted=text.length;index.lastReplacementBlockCount=blocks.count
        return(index,text)
    }

    func replace(parent:String,with blocks:[TranscriptRenderedBlock],storage:NSTextStorage) {
        parentReplacements += 1
        let oldIDs=Array(idsByParent[parent] ?? [])
        let oldNodes=oldIDs.compactMap{byID[$0]}.map{node in (prefixLength(before:node.key),node)}.sorted{$0.0>$1.0}
        for (offset,node) in oldNodes {
            let n=node.block.attributed.length
            if n>0 {storage.deleteCharacters(in:NSRange(location:offset,length:n));charactersRemoved += n}
            root=remove(root,node.key);detach(node);blockRemovals += 1
        }
        if let identities=parentIdentities.removeValue(forKey:parent) {for identity in identities {parentsByIdentity[identity]?.remove(parent);if parentsByIdentity[identity]?.isEmpty==true {parentsByIdentity.removeValue(forKey:identity)}}}
        lastReplacementBlockCount=blocks.count
        for block in blocks {
            let node=Node(block);let offset=prefixLength(before:node.key)
            if block.attributed.length>0 {storage.insert(block.attributed,at:offset);charactersInserted += block.attributed.length}
            root=insert(root,node);attach(node);blockInsertions += 1
        }
    }

    func parents(for identity:String)->Set<String> {parentsByIdentity[identity] ?? []}
    func identities(for parent:String)->Set<String> {parentIdentities[parent] ?? []}
    func range(forParent parent:String)->NSRange? {
        let ranges=(idsByParent[parent] ?? []).compactMap{range(forTurn:$0)}
        guard let low=ranges.map(\.location).min(),let high=ranges.map({NSMaxRange($0)}).max() else{return nil}
        return NSRange(location:low,length:high-low)
    }
    func range(forTurn id:String)->NSRange? {
        guard let node=byID[id] else{return nil};return NSRange(location:prefixLength(before:node.key),length:node.block.attributed.length)
    }
    func range(forPart id:String)->NSRange? {
        guard let turnID=turnByPart[id],let node=byID[turnID],let local=node.block.partRanges[id] else{return nil}
        return NSRange(location:prefixLength(before:node.key)+local.location,length:local.length)
    }
    func allTurnRanges()->[String:NSRange] {
        var output:[String:NSRange]=[:];output.reserveCapacity(turnCount)
        func visit(_ node:Node?,_ offset:Int) {
            guard let node=node else{return};let left=length(node.left);visit(node.left,offset)
            output[node.key.id]=NSRange(location:offset+left,length:node.block.attributed.length)
            visit(node.right,offset+left+node.block.attributed.length)
        }
        visit(root,0);return output
    }
    func allPartRanges()->[String:NSRange] {
        var output:[String:NSRange]=[:];output.reserveCapacity(turnByPart.count)
        for id in byID.keys {guard let node=byID[id] else{continue};let base=prefixLength(before:node.key);for (part,range) in node.block.partRanges {output[part]=NSRange(location:base+range.location,length:range.length)}}
        return output
    }
    func turnID(atCharacter offset:Int)->String? {node(atCharacter:offset)?.node.key.id}
    func localOffset(atCharacter offset:Int)->Int? {node(atCharacter:offset)?.local}
    func block(_ id:String)->TranscriptRenderedBlock? {byID[id]?.block}
    func allTurns()->[ReadingTurn] {
        var output:[ReadingTurn]=[];output.reserveCapacity(turnCount)
        func visit(_ node:Node?) {guard let node=node else{return};visit(node.left);output.append(node.block.turn);visit(node.right)}
        visit(root);return output
    }
    func allAtoms()->[TranscriptAtomicRow] {orderedAtoms}
    func turnIDs()->[String] {
        var output:[String]=[];output.reserveCapacity(turnCount)
        func visit(_ node:Node?) {guard let node=node else{return};visit(node.left);output.append(node.key.id);visit(node.right)}
        visit(root);return output
    }
    func resetMetrics() {parentReplacements=0;blockInsertions=0;blockRemovals=0;charactersInserted=0;charactersRemoved=0;lastReplacementBlockCount=0;atomShifts=0}
    func noteFullReplacement(oldLength:Int) {charactersRemoved += oldLength}
}
