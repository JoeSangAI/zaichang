import AppKit
import AVFoundation

private enum SpeakerReviewChoice {
    case person(SessionSpeakerKey)
    case unassigned
    case simultaneous
}

private struct SpeakerReviewTextPart {
    let range:NSRange
    let id:String
    let turnID:String
    let item:[String:Any]
}

private struct SpeakerReviewSelectionAnchor {
    let partID:String
    let offset:Int
    let length:Int
}

private final class SpeakerReviewWindow:NSWindow {
    var reviewController:MinimalSpeakerReviewController?
}

private final class MinimalSpeakerReviewController:NSObject,NSWindowDelegate,NSTextViewDelegate,NSTextFieldDelegate,AVAudioPlayerDelegate {
    weak var owner:Delegate?
    weak var window:NSWindow?
    private let filter=NSPopUpButton(frame:.zero,pullsDown:false)
    private let coarseStatus=CoarseProcessingStatusView()
    private let target=NSPopUpButton(frame:.zero,pullsDown:false)
    private let nameField=NSTextField(string:"")
    private let renameButton=NSButton(title:"确认",target:nil,action:nil)
    private let reuseGroupButton=NSPopUpButton(frame:.zero,pullsDown:true)
    private let assignButton=NSButton(title:"重新归属",target:nil,action:nil)
    private let mergeButton=NSButton(title:"合并人物",target:nil,action:nil)
    private let undoButton=NSButton(title:"撤销",target:nil,action:nil)
    private let recommendationLabel=NSTextField(labelWithString:"")
    private let rejectVoiceButton=NSButton(title:"不是此人",target:nil,action:nil)
    private let voiceMemoryButton=NSButton(title:"声音记忆…",target:nil,action:nil)
    private var recommendationRow:NSStackView?
    private let modifyButton=NSButton(title:"更多更正…",target:nil,action:nil)
    private let scopeLabel=NSTextField(wrappingLabelWithString:"")
    private var nameDraftChanged=false
    private let originalButton=NSButton(title:"查看原文",target:nil,action:nil)
    private let refineButton=NSButton(title:"重新整理",target:nil,action:nil)
    private let coarseOriginalButton=NSButton(title:"查看原稿",target:nil,action:nil)
    private let listenButton=NSButton(title:"试听所选发言",target:nil,action:nil)
    private let previewJob=CacheReadJob()
    private var previewPlayer:AVAudioPlayer?
    private var previewRevision=0
    private let selectionLabel=NSTextField(wrappingLabelWithString:"选择文字后，可把所选发言重新归属。")
    private let textView=NSTextView(frame:.zero)
    private var editDetails:NSStackView?
    private var transcriptScroll:NSScrollView?
    private var editingExpanded=false
    private var choices:[SpeakerReviewChoice]=[]
    private var targets:[SessionSpeakerKey]=[]
    private var reuseTargets:[SessionSpeakerKey]=[]
    private var index:SpeakerReviewIndex?
    private var visibleEntries:[SpeakerReviewEntry]=[]
    private var mappedParts:[SpeakerReviewTextPart]=[]
    private var renderedParagraphCount=0
    private var selectedPartIDs:[String]=[]
    private var selectedTurnIDs:[String]=[]
    private var partItems:[String:[String:Any]]=[:]
    private var selectedPartForReturn:String?
    private var otherEntries:[SpeakerReviewEntry]=[]
    private var lastDataEpoch:String?
    private var persistenceInFlight=false
    private var persistenceToken=0
    private var persistenceSession:String?
    private var persistenceCacheID:String?
    private var persistenceDocumentGeneration:Int?
    private var openingReadingPosition:Delegate.TranscriptReadingPosition?
    private var shouldNavigateToOriginal=false
    var fixtureConfirmation:((String,String,String)->Bool)?

    init(owner:Delegate) {self.owner=owner}

    func present(in window:SpeakerReviewWindow,for key:SessionSpeakerKey?) {
        self.window=window
        window.reviewController=self;window.delegate=self;window.isReleasedWhenClosed=false
        window.title="发言人"
        window.minSize=NSSize(width:640,height:520)
        openingReadingPosition=owner?.captureTranscriptReadingPosition()
        window.contentView=buildContent()
        refresh(preferred:key)
        window.center();window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded();updateTextGeometry()
    }

    private func buildContent()->NSView {
        let root=MeetingDocumentView()
        let filterRow=NSStackView(views:[filter,refineButton,coarseOriginalButton]);filterRow.orientation = .horizontal;filterRow.spacing=10;filterRow.alignment = .centerY
        filter.translatesAutoresizingMaskIntoConstraints=false
        filter.widthAnchor.constraint(equalToConstant:330).isActive=true
        filter.setAccessibilityLabel("发言人筛选")
        filter.target=self;filter.action=#selector(changeFilter)
        refineButton.target=owner;refineButton.action=#selector(Delegate.toggleCoarseRefinement)
        refineButton.toolTip="录音暂停后自动整理；未完成的内容可在这里重试。"
        coarseOriginalButton.target=owner;coarseOriginalButton.action=#selector(Delegate.toggleCoarseProjection)
        coarseOriginalButton.toolTip="切换原始转写与AI整理稿；原始录音始终保留。"
        modifyButton.target=self;modifyButton.action=#selector(toggleEditing)
        for button in [modifyButton,originalButton,listenButton,renameButton,assignButton,mergeButton,undoButton,reuseGroupButton] {button.controlSize = .small}

        let targetTitle=NSTextField(labelWithString:"目标人物")
        let assignmentRow=NSStackView(views:[targetTitle,target,assignButton,mergeButton])
        assignmentRow.orientation = .horizontal;assignmentRow.spacing=8;assignmentRow.alignment = .centerY
        target.translatesAutoresizingMaskIntoConstraints=false;target.widthAnchor.constraint(equalToConstant:200).isActive=true
        target.target=self;target.action=#selector(changeTarget)
        for button in [assignButton,mergeButton,undoButton] {button.target=self}
        assignButton.action=#selector(reassignSelection)
        mergeButton.action=#selector(mergeSelectedPerson)
        undoButton.action=#selector(undoCorrection)

        let nameTitle=NSTextField(labelWithString:"姓名")
        let renameRow=NSStackView(views:[nameTitle,nameField,renameButton])
        renameRow.orientation = .horizontal;renameRow.spacing=8;renameRow.alignment = .centerY
        nameField.translatesAutoresizingMaskIntoConstraints=false;nameField.widthAnchor.constraint(equalToConstant:210).isActive=true
        nameField.placeholderString="输入本场姓名";nameField.delegate=self
        // A prefilled candidate must only save on an explicit click or Return,
        // never when AppKit ends editing while focus moves to another control.
        nameField.target=nil;nameField.action=nil
        nameField.setAccessibilityLabel("发言人姓名")
        renameButton.target=self;renameButton.action=#selector(renameSelectedPerson)
        reuseGroupButton.setAccessibilityLabel("合并到本场已有发言人组")
        reuseGroupButton.toolTip="明确选择一个本场已有组；同名人物不会自动合并。"
        reuseGroupButton.target=self;reuseGroupButton.action=#selector(reuseSelectedGroup)

        selectionLabel.textColor = MeetingVisualStyle.muted;selectionLabel.font = .systemFont(ofSize:12)
        selectionLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.autohidesScrollers=true;scroll.drawsBackground=true;scroll.backgroundColor = MeetingVisualStyle.surface;scroll.borderType = .noBorder
        transcriptScroll=scroll
        textView.isEditable=false;textView.isSelectable=true;textView.allowsUndo=false;textView.drawsBackground=true;textView.backgroundColor = MeetingVisualStyle.surface;textView.font = .systemFont(ofSize:16)
        textView.setAccessibilityLabel("发言人原文")
        textView.selectedTextAttributes=[.backgroundColor:MeetingVisualStyle.selection,.foregroundColor:MeetingVisualStyle.ink]
        textView.textContainerInset=NSSize(width:0,height:0);textView.isRichText=false;textView.delegate=self
        textView.isVerticallyResizable=true;textView.isHorizontallyResizable=false;textView.minSize=NSSize(width:0,height:0);textView.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);textView.autoresizingMask=[.width]
        textView.textContainer?.widthTracksTextView=true;textView.textContainer?.containerSize=NSSize(width:700,height:CGFloat.greatestFiniteMagnitude)
        scroll.documentView=textView
        voiceMemoryButton.target=owner;voiceMemoryButton.action=#selector(Delegate.manageVoiceprintRecommendations)
        scopeLabel.textColor=MeetingVisualStyle.muted;scopeLabel.font = .systemFont(ofSize:12)
        let details=NSStackView(views:[reuseGroupButton,assignmentRow,selectionLabel,rejectVoiceButton,voiceMemoryButton]);details.orientation = .vertical;details.spacing=6;details.alignment = .leading;details.isHidden=true
        editDetails=details
        originalButton.target=self;originalButton.action=#selector(showOriginal)
        listenButton.target=self;listenButton.action=#selector(listenSelection)
        listenButton.toolTip="点击一轮文字，再试听对应声源的录音；低声会适当放大，仅本机播放，最长30秒。"
        let footerRow=NSStackView(views:[listenButton,modifyButton,undoButton,originalButton]);footerRow.orientation = .horizontal;footerRow.spacing=10;footerRow.alignment = .centerY
        let suggestion=NSStackView(views:[recommendationLabel]);suggestion.orientation = .horizontal;suggestion.spacing=10;suggestion.isHidden=true;recommendationRow=suggestion
        recommendationLabel.font = .systemFont(ofSize:12);recommendationLabel.textColor=MeetingVisualStyle.muted
        rejectVoiceButton.target=self;rejectVoiceButton.action=#selector(rejectVoice)
        let column=NSStackView(views:[filterRow,coarseStatus,renameRow,suggestion,scopeLabel,details,scroll,footerRow]);column.orientation = .vertical;column.spacing=12;column.alignment = .leading;column.distribution = .fill
        for view in [column,filterRow,details,assignmentRow,renameRow,selectionLabel,scroll,footerRow,reuseGroupButton] {view.translatesAutoresizingMaskIntoConstraints=false}
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:24),column.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-24),column.topAnchor.constraint(equalTo:root.topAnchor,constant:24),column.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-24),
            filterRow.heightAnchor.constraint(equalToConstant:30),scopeLabel.widthAnchor.constraint(equalTo:column.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200),footerRow.heightAnchor.constraint(greaterThanOrEqualToConstant:24)
        ])
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        return root
    }

    func refresh(preferred:SessionSpeakerKey?=nil) {
        if persistenceInFlight,let owner=owner,
           (owner.activeSession != persistenceSession || owner.currentCacheID != persistenceCacheID || owner.meetingDocumentGeneration != persistenceDocumentGeneration) {
            // A document switch invalidates this window's pending UI transaction. The
            // queued writer still targets its captured file, but its callback must not
            // alter the newly displayed document.
            persistenceToken &+= 1;persistenceInFlight=false
            persistenceSession=nil;persistenceCacheID=nil;persistenceDocumentGeneration=nil
        }
        guard let owner=owner,let session=owner.activeSession else {
            lastDataEpoch=nil;index=nil;visibleEntries=[];otherEntries=[];filter.removeAllItems();target.removeAllItems();render("本场还没有可复核的转写内容。")
            selectionLabel.stringValue="暂无可复核发言。";updateControls();return
        }
        let dataEpoch=refreshDataEpoch(owner,session:session)
        let preferredAlreadySelected=preferred.map{owner.naming.canonical($0)==selectedChoiceKey} ?? true
        if dataEpoch==lastDataEpoch && preferredAlreadySelected {
            // Coarse progress ticks arrive every 0.7 seconds. Keep the existing
            // text storage, selection, scroll position, draft and audio preview
            // intact when transcript and name inputs have not changed.
            updateControls();return
        }
        let previous=selectedChoiceKey
        let previousChoices=choices
        let previousChoiceID=currentChoice.map(choiceIdentity)
        let draft=nameField.stringValue,hadDraft=nameDraftChanged
        let previousWasUnassigned:Bool={if case .unassigned=currentChoice {return true};return false}()
        let previousWasSimultaneous:Bool={if case .simultaneous=currentChoice {return true};return false}()
        let turns=owner.readingTurns()
        let value=SpeakerReviewIndex.build(session:session,turns:turns,names:owner.naming)
        index=value
        otherEntries=value.unassigned
        choices=value.people.map{.person($0.key)}+(!value.simultaneous.isEmpty ? [.simultaneous]:[])+(!otherEntries.isEmpty ? [.unassigned]:[])
        let newChoiceIDs=choices.map(choiceIdentity),newChoiceTitles=choices.map{title($0,index:value)},newChoiceTooltips=choices.map{choiceTooltip($0)}
        let oldChoiceIDs=previousChoices.map(choiceIdentity)
        let oldFilterTitles=filter.itemTitles
        let oldFilterTooltips=filter.itemArray.map{$0.toolTip ?? ""}
        let listChanged=oldChoiceIDs != newChoiceIDs || oldFilterTitles != newChoiceTitles || oldFilterTooltips != newChoiceTooltips
        if listChanged {
            filter.removeAllItems()
            if choices.isEmpty {filter.addItem(withTitle:"暂无发言")}
            for (choice,tooltip) in zip(choices,newChoiceTooltips) {
                filter.addItem(withTitle:title(choice,index:value));filter.lastItem?.toolTip=tooltip
            }
        }
        let wanted=preferred ?? previous
        let selected:Int?
        if let wanted=wanted {selected=choices.firstIndex{if case .person(let key)=$0 {return key==owner.naming.canonical(wanted)};return false}}
        else if previousWasUnassigned {selected=choices.firstIndex{if case .unassigned=$0 {return true};return false}}
        else if previousWasSimultaneous {selected=choices.firstIndex{if case .simultaneous=$0 {return true};return false}}
        else {selected=choices.isEmpty ? nil:0}
        let nextSelection=selected ?? 0
        if listChanged || filter.indexOfSelectedItem != nextSelection {filter.selectItem(at:nextSelection)}

        let newTargets=value.people.map(\.key)
        let oldTargetIDs=targets
        let oldTargetTitles=target.itemTitles
        let oldTargetTooltips=target.itemArray.map{$0.toolTip ?? ""}
        targets=newTargets
        let targetTitles=targets.map{targetTitle($0,index:value)}
        let targetTooltips=targets.map{speakerTooltip($0)}
        if oldTargetIDs != targets || oldTargetTitles != targetTitles || oldTargetTooltips != targetTooltips {
            target.removeAllItems()
            for (key,tooltip) in zip(targets,targetTooltips) {
                target.addItem(withTitle:targetTitle(key,index:value));target.lastItem?.toolTip=tooltip
            }
        }
        if let selectedKey=selectedChoiceKey,let match=targets.firstIndex(of:selectedKey) {
            if target.indexOfSelectedItem != match {target.selectItem(at:match)}
        } else if !targets.isEmpty,target.indexOfSelectedItem<0 {target.selectItem(at:0)}
        let preserveInteraction=previousChoiceID != nil && previousChoiceID==currentChoice.map(choiceIdentity)
        displayCurrentChoice(preservingInteraction:preserveInteraction)
        if hadDraft,previous==selectedChoiceKey {nameField.stringValue=draft;nameDraftChanged=true}
        lastDataEpoch=dataEpoch
        updateControls()
    }

    private func choiceIdentity(_ choice:SpeakerReviewChoice)->String {
        switch choice {
        case .person(let key):return "person|\(key.session)|\(key.source)|\(key.epoch)|\(key.identity)"
        case .unassigned:return "other"
        case .simultaneous:return "simultaneous"
        }
    }

    private func refreshDataEpoch(_ owner:Delegate,session:String)->String {
        let last=owner.sequence.last ?? ""
        let revision=owner.segments[last].map{$0["revision"] as? Int ?? -1} ?? -1
        let coarse=owner.coarseResultToken.map{[$0.cacheID,$0.session,String($0.generation),String($0.revision),$0.sourceSHA256,$0.snapshotSHA256].joined(separator:"|")} ?? ""
        return [session,owner.currentCacheID ?? "",String(owner.meetingDocumentGeneration),String(owner.naming.correctionRevision),
                String(owner.sequence.count),last,String(revision),String(owner.transcriptProjectionComputations),
                String(owner.fullRefreshGeneration),String(owner.dirtyTranscriptQueueIndex),String(owner.dirtyTranscriptQueue.count),
                String(owner.fullTranscriptRefreshPending),String(owner.voiceprintGeneration),coarse].joined(separator:"\u{001E}")
    }

    private var selectedChoiceKey:SessionSpeakerKey? {
        guard filter.indexOfSelectedItem>=0,filter.indexOfSelectedItem<choices.count else{return nil}
        if case .person(let key)=choices[filter.indexOfSelectedItem] {return owner?.naming.canonical(key)}
        return nil
    }
    private var currentChoice:SpeakerReviewChoice? {
        guard filter.indexOfSelectedItem>=0,filter.indexOfSelectedItem<choices.count else{return nil}
        return choices[filter.indexOfSelectedItem]
    }
    private var selectedTarget:SessionSpeakerKey? {
        guard target.indexOfSelectedItem>=0,target.indexOfSelectedItem<targets.count else{return nil}
        return targets[target.indexOfSelectedItem]
    }

    private func title(_ choice:SpeakerReviewChoice,index:SpeakerReviewIndex)->String {
        switch choice {
        case .person(let key):
            let person=index.people.first{$0.key==key}
            return primarySpeakerName(key)+" · \(person?.entries.count ?? 0)轮"
        case .unassigned:
            return "其他发言 · 可查看"
        case .simultaneous:
            return "多人同时发言 · \(index.simultaneous.count)轮"
        }
    }
    private func targetTitle(_ key:SessionSpeakerKey,index:SpeakerReviewIndex)->String {
        let person=index.people.first{$0.key==key}
        return primarySpeakerName(key)+" · \(person?.entries.count ?? 0)轮"
    }
    private func primarySpeakerName(_ key:SessionSpeakerKey)->String {
        if let name=owner?.naming.displayName(speaker:key) {return name.value}
        if let candidate=owner?.voiceprintRecommendation(for:key) {return candidate.recognizedSupport==nil ? "可能是"+candidate.name:candidate.name+" · 部分已识别"}
        return owner?.naming.displayLabel(speaker:key) ?? "发言人"
    }
    private func choiceTooltip(_ choice:SpeakerReviewChoice)->String {
        if case .person(let key)=choice {return speakerTooltip(key)}
        return "未分组或归属有歧义的发言，可在此查看并人工更正。"
    }
    private func speakerTooltip(_ key:SessionSpeakerKey)->String {
        let source="来源："+sourceTitle(key)
        if let name=owner?.naming.displayName(speaker:key) {
            if name.origin == .manual {return "人工确认姓名：\(name.value) · \(source)"}
            let basis=name.origin == .voiceprint ? "声音识别候选" : "语义识别候选"
            return "\(basis)：\(name.value)，尚未人工确认 · \(source)"
        }
        if let candidate=owner?.voiceprintRecommendation(for:key) {
            return candidate.recognizedSupport != nil ? "已按声音识别部分发言："+candidate.name+" · 其余发言待确认 · "+source:(candidate.groupConsistent ? "可能对应：":"部分声音像：")+candidate.name+"，尚未确认 · "+source
        }
        return source
    }
    private func sourceTitle(_ key:SessionSpeakerKey)->String {VoiceprintAcousticContext.channel(for:key.source)=="microphone" ? "麦克风" : "电脑声音 · "+key.source}

    @objc private func rejectVoice() {guard !persistenceInFlight,let key=selectedChoiceKey else{return};nameDraftChanged=false;owner?.rejectVoiceprintRecommendation(key);refresh(preferred:key)}
    @objc private func changeFilter() {stopPreview();nameDraftChanged=false;displayCurrentChoice();updateControls()}
    func controlTextDidChange(_ notification:Notification) {nameDraftChanged=true;updateControls()}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if textView.hasMarkedText() {return false}
            renameSelectedPerson();return true
        }
        return false
    }
    @objc private func changeTarget() {updateControls()}
    @objc private func toggleEditing() {
        editingExpanded.toggle();editDetails?.isHidden = !editingExpanded
        modifyButton.title=editingExpanded ? "收起更正":"更多更正…"
    }
    @objc private func showOriginal() {shouldNavigateToOriginal=true;window?.performClose(nil)}
    private func displayCurrentChoice(preservingInteraction:Bool=false) {
        let oldPartIDs=selectedPartIDs
        let oldReturnID=selectedPartForReturn
        let anchors=preservingInteraction ? selectionAnchors():[]
        let oldScrollOrigin=transcriptScroll?.contentView.bounds.origin
        guard let value=index,let choice=currentChoice else {visibleEntries=[];render("没有可显示的发言。");return}
        switch choice {
        case .person(let key):
            visibleEntries=value.people.first{$0.key==key}?.entries ?? []
            if let person=value.people.first(where:{$0.key==key}) {
                nameField.stringValue=owner?.naming.displayName(speaker:key)?.value ?? owner?.voiceprintRecommendation(for:key)?.name ?? "";nameField.placeholderString="输入姓名"
                scopeLabel.stringValue="用于本场这组 \(person.entries.count) 轮发言及后续同一发言人。"
            }
        case .unassigned:
            visibleEntries=otherEntries;nameField.stringValue="";nameField.placeholderString="先点击一轮文字，再输入姓名"
            scopeLabel.stringValue="点击一轮文字 → 试听所选发言 → 输入姓名并保存；只标注所选内容。"
        case .simultaneous:
            visibleEntries=value.simultaneous;nameField.stringValue="";nameField.placeholderString="选中一轮后可人工更正归属"
            scopeLabel.stringValue="这里是多人同时说话的片段。选中一轮，可试听或更正归属。"
        }
        if let key=selectedChoiceKey,let automatic=owner?.naming.displayName(speaker:key),automatic.origin != .manual {
            recommendationLabel.stringValue=automatic.origin == .semantic ? "已按自我介绍识别，姓名可直接修改。":"已按声音识别，姓名可直接修改。"
            rejectVoiceButton.title="撤销自动识别";recommendationRow?.isHidden=false;rejectVoiceButton.isHidden=false
        }else if let key=selectedChoiceKey,let candidate=owner?.voiceprintRecommendation(for:key) {
            recommendationLabel.stringValue=candidate.recognizedSupport != nil ? "部分发言已识别；请确认这组是否为同一人。":(candidate.groupConsistent ? "按声音建议，姓名可直接修改。":"部分声音相似；请确认这组是否为同一人。")
            rejectVoiceButton.title=candidate.recognizedSupport != nil ? "撤销自动识别":"忽略此建议";recommendationRow?.isHidden=false;rejectVoiceButton.isHidden=false
        }else{recommendationRow?.isHidden=true;rejectVoiceButton.isHidden=true}
        renderEntries(visibleEntries)
        if preservingInteraction {
            let valid=Set(mappedParts.map(\.id))
            selectedPartIDs=oldPartIDs.filter{valid.contains($0)}
            let selected=Set(selectedPartIDs)
            selectedTurnIDs=Array(Set(mappedParts.filter{selected.contains($0.id)}.map(\.turnID))).sorted()
            selectedPartForReturn=oldReturnID.flatMap{valid.contains($0) ? $0:nil} ?? visibleEntries.first?.partIDs.first
            if !anchors.isEmpty {
                let restored=anchors.compactMap { anchor -> NSValue? in
                    guard let part=mappedParts.first(where:{$0.id==anchor.partID}) else{return nil}
                    let location=part.range.location+min(anchor.offset,part.range.length)
                    let length=min(anchor.length,max(0,NSMaxRange(part.range)-location))
                    return NSValue(range:NSRange(location:location,length:length))
                }
                textView.setSelectedRanges(restored,affinity:.downstream,stillSelecting:false)
            }
            if let oldScrollOrigin=oldScrollOrigin {
                DispatchQueue.main.async { [weak self] in
                    guard let self,let scroll=self.transcriptScroll else{return}
                    let maxY=max(0,self.textView.bounds.height-scroll.contentView.bounds.height)
                    let origin=NSPoint(x:oldScrollOrigin.x,y:min(max(0,oldScrollOrigin.y),maxY))
                    scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        } else {
            selectedPartIDs=[];selectedTurnIDs=[];selectedPartForReturn=visibleEntries.first?.partIDs.first
        }
        updateReuseGroupMenu()
    }

    private func selectionAnchors()->[SpeakerReviewSelectionAnchor] {
        let ranges=textView.selectedRanges.map{$0.rangeValue}
        guard !ranges.isEmpty else{return []}
        var result:[SpeakerReviewSelectionAnchor]=[]
        for part in mappedParts {
            for range in ranges {
                let intersection=NSIntersectionRange(part.range,range)
                if intersection.length>0 {
                    result.append(SpeakerReviewSelectionAnchor(partID:part.id,offset:intersection.location-part.range.location,length:intersection.length))
                } else if range.length==0,NSLocationInRange(range.location,part.range) {
                    result.append(SpeakerReviewSelectionAnchor(partID:part.id,offset:range.location-part.range.location,length:0))
                }
            }
        }
        return result
    }

    private func updateReuseGroupMenu() {
        reuseTargets=[];reuseGroupButton.removeAllItems()
        reuseGroupButton.addItem(withTitle:"合并到已有组…")
        reuseGroupButton.item(at:0)?.isEnabled=false
        guard case .person(let source)=currentChoice,let index=index else {
            reuseGroupButton.isHidden=true;return
        }
        let sourceKey=owner?.naming.canonical(source) ?? source
        let destinations=index.people.filter{$0.key != sourceKey}
        guard !destinations.isEmpty else {reuseGroupButton.isHidden=true;return}
        reuseGroupButton.isHidden=false
        for person in destinations {
            reuseTargets.append(person.key)
            let title="\(primarySpeakerName(person.key)) · \(person.entries.count)轮"
            reuseGroupButton.addItem(withTitle:title)
            reuseGroupButton.lastItem?.toolTip=speakerTooltip(person.key)
            reuseGroupButton.lastItem?.tag=reuseTargets.count-1
        }
    }

    @objc private func reuseSelectedGroup() {
        guard let item=reuseGroupButton.selectedItem,item.tag>=0,reuseTargets.indices.contains(item.tag) else{return}
        mergePersonGroup(to:reuseTargets[item.tag])
    }

    private func render(_ value:String) {
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=7
        textView.textStorage?.setAttributedString(NSAttributedString(string:value,attributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:MeetingVisualStyle.muted,.paragraphStyle:paragraph]))
        mappedParts=[];partItems=[:]
    }
    private func renderEntries(_ entries:[SpeakerReviewEntry]) {
        let text=NSMutableAttributedString(string:"")
        var mappings:[SpeakerReviewTextPart]=[];var items:[String:[String:Any]]=[:]
        // The unresolved view is a sentence review, not a bag of isolated
        // words. Restore reading context without changing any speaker evidence.
        // Only original unresolved parts get actionable mappings, with their
        // original turn IDs; a sentence containing several people is never a
        // new unit of speaker assignment.
        let contextual:Bool={if case .unassigned=currentChoice{return true};return false}()
        func scope(_ parent:String,_ item:[String:Any])->String {
            [parent,item["source_id"] as? String ?? "",item["epoch"] as? String ?? ""].joined(separator:"\u{001F}")
        }
        let context=contextual ? Dictionary(grouping:owner?.readingTurns() ?? [],by:{scope($0.parent,$0.item)}):[:]
        var paragraphs:[[SpeakerReviewEntry]]=[],positions:[String:Int]=[:]
        for entry in entries {
            let key=scope(entry.parent,entry.turn.item)
            if contextual,let position=positions[key] {paragraphs[position].append(entry)}
            else {positions[key]=paragraphs.count;paragraphs.append([entry])}
        }
        if contextual {
            func beginning(_ paragraph:[SpeakerReviewEntry])->Double {
                let entry=paragraph[0]
                return context[scope(entry.parent,entry.turn.item)]?.first.map{TranscriptTimeline.start($0.item)} ?? entry.start
            }
            paragraphs.sort {let a=beginning($0),b=beginning($1);return a != b ? a<b:$0[0].id<$1[0].id}
        }
        renderedParagraphCount=paragraphs.count
        for paragraph in paragraphs {
            let entry=paragraph[0]
            let selected=paragraph.flatMap { value in (value.turn.parts.isEmpty ? [(value.id,value.turn.item)]:value.turn.parts).map{($0.0,value.id)} }
            let turnIDs=Dictionary(selected,uniquingKeysWith:{first,_ in first})
            let selectedIDs=Set(turnIDs.keys)
            let unresolved=Set(paragraph.flatMap(\.unresolvedPartIDs))
            let originalParts=paragraph.flatMap{$0.turn.parts.isEmpty ? [($0.id,$0.turn.item)]:$0.turn.parts}
            let sentence=context[scope(entry.parent,entry.turn.item)]?.flatMap{$0.parts.isEmpty ? [($0.id,$0.item)]:$0.parts} ?? []
            let parts = !sentence.isEmpty && Set(originalParts.map{$0.0}).isSubset(of:Set(sentence.map{$0.0})) ? sentence:originalParts
            let at=parts.first.map{TranscriptTimeline.start($0.1)} ?? entry.start
            let start=owner?.transcriptTimeHeading(at) ?? TranscriptTimeline.timestamp(at)
            let source=audioSourceLabel(entry.turn.item)
            let reason=contextual ? " · 原句 · 下划线部分待确认":(entry.personKey==nil ? " · "+entryLabel(entry):"")
            let heading=(start+"  ·  "+source+reason+"\n")
            let headingStyle=NSMutableParagraphStyle();headingStyle.lineSpacing=4;headingStyle.paragraphSpacing=4
            text.append(NSAttributedString(string:heading,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:MeetingVisualStyle.muted,.paragraphStyle:headingStyle]))
            let bodyStyle=NSMutableParagraphStyle();bodyStyle.lineSpacing=7;bodyStyle.paragraphSpacing=24
            for (id,item) in parts {
                let body=item["text"] as? String ?? ""
                let manualName=owner?.naming.name(segment:id)
                if unresolved.contains(id),let manualName {
                    text.append(NSAttributedString(string:"〔"+manualName+"〕",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:MeetingVisualStyle.muted]))
                }
                let bodyStart=text.length
                var bodyAttributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:16),.foregroundColor:MeetingVisualStyle.ink,.paragraphStyle:bodyStyle]
                if contextual && !unresolved.contains(id) {bodyAttributes[.foregroundColor]=MeetingVisualStyle.muted}
                if unresolved.contains(id),manualName==nil {
                    bodyAttributes[.underlineStyle]=NSUnderlineStyle.single.rawValue
                    bodyAttributes[.toolTip]="归属尚未确认；可在“其他发言”中查看并人工更正。"
                }
                text.append(NSAttributedString(string:body,attributes:bodyAttributes))
                let range=NSRange(location:bodyStart,length:(body as NSString).length)
                if !contextual || selectedIDs.contains(id) {
                    if range.length>0 {mappings.append(SpeakerReviewTextPart(range:range,id:id,turnID:turnIDs[id] ?? entry.id,item:item))}
                    items[id]=item
                }
            }
            text.append(NSAttributedString(string:"\n",attributes:[.paragraphStyle:bodyStyle]))
        }
        textView.textStorage?.setAttributedString(text);mappedParts=mappings;partItems=items
        if entries.isEmpty {render("当前筛选下没有发言。")}
        DispatchQueue.main.async { [weak self] in self?.updateTextGeometry() }
    }
    private func entryLabel(_ entry:SpeakerReviewEntry)->String {
        if let key=entry.personKey,let owner=owner {return owner.naming.displayName(speaker:key)?.value ?? owner.naming.displayLabel(speaker:key)}
        let manual=Set(entry.partIDs.compactMap{owner?.naming.name(segment:$0)})
        if manual.count==1,entry.partIDs.allSatisfy({owner?.naming.name(segment:$0) != nil}) {return manual.first!}
        if let owner=owner,let title=SpeakerReviewIndex.simultaneousTitle(entry,names:owner.naming) {return title}
        switch entry.reason {
        case "overlap":return "多人重叠"
        case "speaker_change":return "一轮内多人发言"
        case "insufficient_voiced_evidence":return "声音片段太短 · 待确认"
        case "no_reliable_span":return "转写未完成 · 时间待补齐"
        case "no_speaker_evidence":return "未形成声音分组 · 待确认"
        default:return "待确认"
        }
    }

    func textViewDidChangeSelection(_ notification:Notification) {updateSelection()}
    func windowDidResize(_ notification:Notification) {updateTextGeometry()}
    private func updateTextGeometry() {
        guard let scroll=transcriptScroll else{return}
        let width=max(1,scroll.contentView.bounds.width)
        textView.textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        let height=max(scroll.contentView.bounds.height,textView.frame.height)
        if abs(textView.frame.width-width)>0.5 || abs(textView.frame.height-height)>0.5 {
            textView.setFrameSize(NSSize(width:width,height:height))
        }
        textView.needsLayout=true
    }
    private func updateSelection() {
        let previous=selectedPartIDs
        var ids=Set<String>(),turns=Set<String>(),first:String?
        var selections=textView.selectedRanges.map{$0.rangeValue}.filter{$0.length>0}
        if selections.isEmpty {
            let cursor=textView.selectedRange().location
            if let part=mappedParts.first(where:{NSLocationInRange(cursor,$0.range)}) {selections=[part.range]}
        }
        if !selections.isEmpty {
            for part in mappedParts where selections.contains(where:{NSIntersectionRange($0,part.range).length>0}) {
                // In the unresolved section, only still-unassigned parts are eligible;
                // selecting a mixed turn cannot silently move its known speaker too.
                if case .unassigned=currentChoice,let owner=owner,
                   let entry=visibleEntries.first(where:{$0.partIDs.contains(part.id)}),
                   entry.reason != "overlap",entry.simultaneousParticipants.isEmpty,
                   (owner.naming.key(segment:part.id) != nil || SessionSpeakerKey.from(part.item) != nil) {continue}
                ids.insert(part.id);turns.insert(part.turnID);if first==nil {first=part.id}
            }
        }
        selectedPartIDs=ids.sorted();selectedTurnIDs=turns.sorted();if let first=first {selectedPartForReturn=first}
        if previous != selectedPartIDs {
            stopPreview()
            if case .unassigned=currentChoice {
                nameDraftChanged=false
                let names=Set(selectedPartIDs.compactMap{owner?.naming.name(segment:$0)})
                nameField.stringValue=names.count==1 ? names.first!:""
            } else if case .simultaneous=currentChoice {
                nameDraftChanged=false;nameField.stringValue=""
            }
        }
        updateControls()
    }

    private func updateControls() {
        if let owner=owner {
            coarseStatus.show(owner.coarseProcessingProgress,summary:owner.coarseProcessingSummary,
                              isRecording:owner.phase.phase == .recording,
                              fallbackRunning:owner.hasRunningCoarseRefinement)
        } else {coarseStatus.show(nil,summary:nil,isRecording:false,fallbackRunning:false)}
        refineButton.isEnabled=owner?.canRetrySpeakerRefinement==true || owner?.hasRunningCoarseRefinement==true
        refineButton.title=owner?.hasRunningCoarseRefinement==true ? "停止整理":"重新整理"
        coarseOriginalButton.title=owner?.showsCoarseProjection==true ? "查看原稿":"查看整理稿"
        coarseOriginalButton.isHidden=owner?.hasCoarseResult != true
        coarseOriginalButton.isEnabled=owner?.hasRunningCoarseRefinement != true && owner?.currentCacheID != nil
        let affected=selectedPartIDs.count,turns=selectedTurnIDs.count
        selectionLabel.stringValue=affected==0 ? "选择文字后，可把所选发言重新归属。" : "已选 \(affected) 段原文，涉及 \(turns) 轮发言；重新归属仅作用于这些部分。"
        let key=selectedChoiceKey
        let known=key != nil
        let singleCorrection:Bool={
            switch currentChoice {
            case .unassigned?,.simultaneous?:return affected>0 && turns==1
            default:return false
            }
        }()
        let draft=nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let validName = !draft.isEmpty && draft.count<=80 && !draft.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
        let confirmed=known && !draft.isEmpty && draft==key.flatMap{owner?.naming.name(speaker:$0)}
        renameButton.title=confirmed ? "已确认":"确认"
        renameButton.isEnabled=validName && (known ? draft != key.flatMap{owner?.naming.name(speaker:$0)}:singleCorrection && selectedPartIDs.contains{owner?.naming.name(segment:$0) != draft})
        nameField.isEnabled=known || singleCorrection
        if case .unassigned=currentChoice {
            if singleCorrection,let id=selectedPartIDs.first,let item=partItems[id] {
                scopeLabel.stringValue="已选 "+TranscriptTimeline.timestamp(item["start"])+" · "+audioSourceLabel(item)+"；试听后输入姓名，只标注所选发言。"
            } else {
                scopeLabel.stringValue=turns>1 ? "这些发言可能来自不同人，请一次选择一轮。":"点击一轮文字 → 试听所选发言 → 输入姓名并保存。"
            }
        } else if case .simultaneous=currentChoice {
            if singleCorrection,let id=selectedPartIDs.first,let item=partItems[id] {
                scopeLabel.stringValue="已选 "+TranscriptTimeline.timestamp(item["start"])+" · "+audioSourceLabel(item)+"；此轮有多人同时说话，修改只作用于所选内容。"
            }
            selectionLabel.stringValue=affected==0 ? "选中一轮，可试听或更正归属。":"此轮有多人同时说话，修改只作用于所选内容。"
        }
        listenButton.isEnabled=previewPlayer != nil || (affected>0 && turns==1 && owner?.currentCacheID != nil && owner?.voiceprintManagementOwner.recordingBusy != true && !previewJob.busy)
        let tooManyUnassigned:Bool={
            switch currentChoice {
            case .unassigned?,.simultaneous?:return selectedTurnIDs.count>1
            default:return false
            }
        }()
        let changesAssignment=selectedTarget.map{target in selectedPartIDs.contains{owner?.naming.assignmentWouldChange(segment:$0,to:target)==true}} ?? false
        assignButton.isEnabled=affected>0 && changesAssignment && !tooManyUnassigned
        if tooManyUnassigned {selectionLabel.stringValue="发言归属更正需逐轮选择；没有批量更正操作。"}
        mergeButton.isEnabled=known && selectedTarget != nil && selectedChoiceKey != selectedTarget
        undoButton.isEnabled=owner?.naming.canUndo ?? false
        originalButton.isEnabled=selectedPartForReturn != nil
        rejectVoiceButton.isEnabled = !persistenceInFlight
        if persistenceInFlight {
            filter.isEnabled=false;target.isEnabled=false
            renameButton.isEnabled=false;nameField.isEnabled=false
            assignButton.isEnabled=false;mergeButton.isEnabled=false;undoButton.isEnabled=false
            reuseGroupButton.isEnabled=false
        } else {
            filter.isEnabled=true;target.isEnabled=true;reuseGroupButton.isEnabled = !reuseGroupButton.isHidden
        }
    }

    func clickRunningCoarseStopForChecks()->Bool {
        _=buildContent();updateControls()
        guard refineButton.title=="停止整理",refineButton.isEnabled else{return false}
        refineButton.performClick(nil);return true
    }

    private func confirm(_ title:String,_ message:String,button:String)->Bool {
        if let fixtureConfirmation=fixtureConfirmation {return fixtureConfirmation(title,message,button)}
        let alert=NSAlert();alert.messageText=title;alert.informativeText=message
        alert.addButton(withTitle:button);alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func renameSelectedPerson() {
        if let editor=nameField.currentEditor() as? NSTextView,editor.hasMarkedText() {return}
        if case .unassigned=currentChoice {saveSelectedName();return}
        if case .simultaneous=currentChoice {saveSelectedName();return}
        guard let owner=owner,!persistenceInFlight,case .person(let key)=currentChoice,let value=index,
              let person=value.people.first(where:{$0.key==key}) else{return}
        let name=nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=80,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),name != owner.naming.name(speaker:key) else{return}
        let candidate=owner.voiceprintRecommendation(for:key)
        if candidate != nil,owner.naming.values.contains(where:{row in owner.naming.key(segment:row.key).map{person.keys.contains($0)}==true && row.value != name}) {
            scopeLabel.stringValue="这组已有不同的人工姓名，请在“更多更正”中逐段核对。";return
        }
        let previous=owner.naming
        guard owner.naming.renameSpeaker(keys:person.keys,name:name) else{return}
        owner.cancelPendingVoiceprintMemory()
        // Keep per-source identity keys intact. A grouped rename must not enroll
        // mixed-source audio as one voiceprint sample.
        if person.keys.count==1 {
            if let candidate,!candidate.groupConsistent {
                // Confirming the displayed group name must not turn unmatched
                // audio into a trusted voice sample.
                if VoiceprintLearningPolicy().isEnabled {
                    let ids=Set(owner.naming.segmentIDs(for:key))
                    owner.naming.attachConfirmation(segmentIDs:candidate.support.map(\.id).filter{ids.contains($0)},name:name,learn:true)
                }
            } else {owner.rememberManualVoiceprint(key:key,name:name)}
        }
        let scope=person.keys.count>1 ? "\(person.keys.count)个本场声音分组、":""
        persistMutation(owner,previous:previous,preferred:key,success:"已保存姓名：本场\(scope)「\(person.title)」的 \(person.entries.count) 轮发言。",failure:"姓名未保存；已恢复原姓名，输入内容保留，可重试。",preserveDraft:true)
    }
    private func saveSelectedName() {
        guard let owner,!persistenceInFlight,!selectedPartIDs.isEmpty,selectedTurnIDs.count==1,renameButton.isEnabled else{return}
        let ids=selectedPartIDs,name=nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),previous=owner.naming
        guard owner.naming.confirmSegments(ids,name:name,learn:VoiceprintLearningPolicy().isEnabled) else{return}
        persistMutation(owner,previous:previous,preferred:selectedChoiceKey,success:"已保存「"+name+"」；仅修改所选发言。",failure:"姓名未保存；已恢复原姓名，输入内容保留，可重试。",preserveDraft:true)
    }

    func stopPreview() {
        previewRevision &+= 1;previewJob.cancel();previewPlayer?.stop();previewPlayer=nil;listenButton.title="试听所选发言"
    }
    @objc private func listenSelection() {
        if previewPlayer != nil || previewJob.waiting {stopPreview();updateControls();return}
        guard let owner,owner.voiceprintManagementOwner.recordingBusy==false,let cache=owner.currentCacheID,let session=owner.activeSession,
              selectedTurnIDs.count==1,!selectedPartIDs.isEmpty else{return}
        let items=selectedPartIDs.compactMap{partItems[$0]}
        guard items.count==selectedPartIDs.count else{return}
        let root=owner.recoveryBase(),revision=previewRevision,generation=owner.meetingDocumentGeneration
        listenButton.title="正在读取录音…";listenButton.isEnabled=false
        previewJob.run(work:{try SpeakerAudioPreview.read(root:root,cacheID:cache,session:session,items:items)}) { [weak self,weak owner] result in
            guard let self,let owner,self.window?.isVisible==true,self.previewRevision==revision,owner.currentCacheID==cache,
                  owner.activeSession==session,owner.meetingDocumentGeneration==generation,owner.voiceprintManagementOwner.recordingBusy==false else{return}
            do {
                let clip=try result.get(),player=try AVAudioPlayer(data:SpeakerAudioPreview.listeningData(clip.wav));player.delegate=self
                guard player.prepareToPlay(),player.play() else{throw Failure(code:"speaker_preview_play_failed")}
                self.previewPlayer=player;self.listenButton.title="停止试听";self.listenButton.isEnabled=true
                self.selectionLabel.stringValue=clip.truncated ? "正在试听所选发言的前30秒；播放结束后可填写姓名。":"正在试听所选发言；播放结束后可填写姓名。"
                self.scopeLabel.stringValue=self.selectionLabel.stringValue
            } catch {
                self.stopPreview();self.updateControls();self.selectionLabel.stringValue="所选发言的原音无法试听；请检查录音是否保留、时间是否完整。"
                self.scopeLabel.stringValue=self.selectionLabel.stringValue
            }
        }
    }
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {stopPreview();updateControls()}
    func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?) {stopPreview();updateControls();selectionLabel.stringValue="录音播放失败，原文件保留。";scopeLabel.stringValue=selectionLabel.stringValue}
    @objc private func reassignSelection() {
        guard let owner=owner,!persistenceInFlight,let target=selectedTarget,!selectedPartIDs.isEmpty else{return}
        guard selectedPartIDs.contains(where:{owner.naming.assignmentWouldChange(segment:$0,to:target)}) else{return}
        if (currentChoice.map{choice in if case .unassigned=choice{return true};if case .simultaneous=choice{return true};return false} ?? false),selectedTurnIDs.count>1 {
            selectionLabel.stringValue="发言归属更正需逐轮选择；没有批量更正操作。";return
        }
        let count=selectedPartIDs.count,turnCount=selectedTurnIDs.count
        guard confirm("更改所选发言归属？","将把所选 \(count) 段原文（\(turnCount) 轮）归入「\(owner.naming.displayName(speaker:target)?.value ?? owner.naming.displayLabel(speaker:target))」。原文和音源记录不变。",button:"重新归属") else{return}
        let previous=owner.naming
        guard owner.naming.assignBatch(segmentIDs:selectedPartIDs,to:target,humanConfirmed:true) else {
            selectionLabel.stringValue="更正未应用；请确认目标人物属于本场并重试。";return
        }
        owner.cancelPendingVoiceprintMemory()
        persistMutation(owner,previous:previous,preferred:target,success:"所选发言归属已保存。",failure:"归属未保存；已恢复原归属，请重试。")
    }
    @objc private func mergeSelectedPerson() {
        mergePersonGroup(to:selectedTarget)
    }
    private func mergePersonGroup(to requestedTarget:SessionSpeakerKey?) {
        guard let owner=owner,!persistenceInFlight,case .person(let source)=currentChoice,
              let target=requestedTarget,source != target,
              let value=index,let person=value.people.first(where:{$0.key==source}),let destination=value.people.first(where:{$0.key==target}) else{return}
        guard confirm("合并两组人物？","将把「\(person.title)」（\(person.entries.count) 轮）合并到「\(destination.title)」（\(destination.entries.count) 轮）。这可跨麦克风和电脑声音合并，只更改本场归属。",button:"合并人物组") else{return}
        let previous=owner.naming
        guard owner.naming.mergeSpeakers(from:person.keys,to:target,humanConfirmed:true) else {
            selectionLabel.stringValue="合并未应用；只能合并本场中不同的人物组。";return
        }
        owner.cancelPendingVoiceprintMemory()
        persistMutation(owner,previous:previous,preferred:target,success:"人物合并已保存。",failure:"合并未保存；已恢复原人物组，请重试。")
    }
    @objc private func undoCorrection() {
        guard let owner=owner,!persistenceInFlight else{return}
        let previous=owner.naming
        guard owner.naming.undo() != nil else{return}
        owner.cancelPendingVoiceprintMemory()
        nameDraftChanged=false
        persistMutation(owner,previous:previous,preferred:selectedChoiceKey,success:"已撤销并保存。",failure:"撤销未保存；已恢复原标注，请重试。")
    }

    private func persistMutation(_ owner:Delegate,previous:SessionNames,preferred:SessionSpeakerKey?,success:String,failure:String,preserveDraft:Bool=false) {
        guard !persistenceInFlight else{return}
        guard let session=owner.activeSession,let cache=owner.currentCacheID else {
            owner.naming=previous;owner.markAllTranscriptParentsDirty();nameDraftChanged=preserveDraft
            refresh(preferred:preferred);scopeLabel.stringValue=failure;return
        }
        persistenceToken &+= 1;let token=persistenceToken
        let generation=owner.meetingDocumentGeneration,revision=owner.naming.correctionRevision
        persistenceInFlight=true;persistenceSession=session;persistenceCacheID=cache
        persistenceDocumentGeneration=generation
        nameDraftChanged=preserveDraft
        owner.markAllTranscriptParentsDirty()
        refresh(preferred:preferred)
        scopeLabel.stringValue="正在保存本场人物修改…"
        owner.persistSessionNames { [weak self,weak owner] result in
            guard let self,let owner,self.persistenceToken==token else{return}
            self.persistenceInFlight=false;self.persistenceSession=nil;self.persistenceCacheID=nil
            self.persistenceDocumentGeneration=nil
            guard owner.activeSession==session,owner.currentCacheID==cache,owner.meetingDocumentGeneration==generation else {
                self.refresh();return
            }
            switch result {
            case .success:
                guard owner.naming.correctionRevision==revision else {
                    self.scopeLabel.stringValue="本场人物已更新，请重新核对后保存。";self.refresh(preferred:preferred);return
                }
                self.nameDraftChanged=false;self.refresh(preferred:preferred)
                self.scopeLabel.stringValue=success;(owner.workspaceOwner ?? owner).reloadLibrary()
            case .failure:
                if owner.naming.correctionRevision==revision {owner.naming=previous}
                owner.markAllTranscriptParentsDirty();self.nameDraftChanged=preserveDraft
                self.refresh(preferred:preferred);self.scopeLabel.stringValue=failure
            }
        }
    }

    func windowWillClose(_ notification:Notification) {
        stopPreview()
        guard let owner=owner else{return}
        if owner.speakerReviewWindow === window {owner.speakerReviewWindow=nil}
        if shouldNavigateToOriginal,let id=selectedPartForReturn,let range=owner.incrementalTranscript.range(forPart:id),let output=owner.output {
            owner.cancelTranscriptReadingRestore();owner.window?.makeKeyAndOrderFront(nil);output.setSelectedRange(range);output.scrollRangeToVisible(range)
        } else if let position=openingReadingPosition {
            owner.cancelTranscriptReadingRestore();owner.restoreTranscriptReadingPosition(position)
        }
    }

    @MainActor func runFixtureChecks(owner:Delegate,directory:URL,checkBridge:Bool=false) async throws->[String:Any] {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let originalNames=owner.naming
        let originalPublisher=owner.contextPublisher,originalContextSession=owner.contextSession
        let bridgeDirectory=directory.appendingPathComponent("bridge-"+UUID().uuidString)
        if checkBridge {owner.contextPublisher=MeetingContextPublisher(directory:bridgeDirectory);owner.beginMeetingContext()}
        defer {if checkBridge {owner.contextPublisher=originalPublisher;owner.contextSession=originalContextSession}}
        func readBridge(_ view:Delegate,current:Bool=false)throws->[String:Any] {
            owner.contextPublisher?.flushForChecks()
            let proc=Process(),pipe=Pipe();proc.executableURL=URL(fileURLWithPath:"/usr/local/bin/python3")
            proc.arguments=[owner.root+"/meeting_context.py","--database",bridgeDirectory.appendingPathComponent("context.sqlite").path]+(current ? ["current"]:["read","--session",view.activeSession!])
            proc.standardOutput=pipe;proc.standardError=FileHandle.nullDevice
            try proc.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();proc.waitUntilExit()
            guard proc.terminationStatus==0 else{throw Failure(code:"speaker_bridge_read_failed")}
            return try JSONSerialization.jsonObject(with:data) as! [String:Any]
        }
        func checkBridgeLabels(_ view:Delegate)throws {
            guard checkBridge else{return}
            try view.settleTranscriptForOfflineReview()
            let result=try readBridge(view)
            guard result["status"] as? String=="ok",result["session"] as? String==view.activeSession else{
                let meeting=result["meeting"] as? [String:Any] ?? [:]
                throw Failure(code:"speaker_bridge_scope_or_projection_not_ready:status=\(String(describing:result["status"]));session=\(String(describing:result["session"]));active=\(String(describing:view.activeSession));updating=\(String(describing:meeting["projection_updating"]));context=\(String(describing:view.contextSession));full=\(view.fullTranscriptRefreshPending);build=\(view.fullRefreshBuildInFlight);dirty=\(view.dirtyTranscriptQueueIndex)/\(view.dirtyTranscriptQueue.count);writer=\(String(describing:owner.contextPublisher?.lastError))")
            }
            var labels:[String:String]=[:]
            for segment in result["segments"] as? [[String:Any]] ?? [] {
                for turn in segment["turns"] as? [[String:Any]] ?? [] {
                    for part in turn["parts"] as? [[String:Any]] ?? [] {if let id=part["id"] as? String {labels[id]=part["speaker"] as? String}}
                }
            }
            let parts=view.readingTurns().flatMap(\.parts)
            guard !parts.isEmpty,parts.allSatisfy({labels[$0.0]==view.speakerLabel($0.0,$0.1)}) else{throw Failure(code:"speaker_bridge_labels_differ_from_document")}
        }
        fixtureConfirmation={_,_,_ in true}
        let sourceSnapshot=owner.segments
        let originalIDs=Set(sourceSnapshot.keys)
        let originalTexts=owner.timeline.orderedIDs.compactMap{sourceSnapshot[$0]? ["text"] as? String}.joined()
        let overlapFixtureOwner=Delegate();overlapFixtureOwner.activeSession="speaker-review-overlap-fixture"
        var overlapNames=SessionNames()
        func overlapSlot(_ id:String,_ slot:Int)->[String:Any] {
            ["segment_id":id,"session":"speaker-review-overlap-fixture","source_id":"remote","epoch":"overlap-epoch",
             "start":1.0,"end":2.0,"text":"发言人\(slot)","speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":"remote","epoch":"overlap-epoch"]]
        }
        let overlapA=overlapSlot("overlap-a",0),overlapB=overlapSlot("overlap-b",1)
        overlapNames.register(segment:"overlap-a",item:overlapA);overlapNames.register(segment:"overlap-b",item:overlapB)
        overlapNames.setSpeaker(segment:"overlap-a",name:"甲")
        overlapNames.setSpeaker(segment:"overlap-b",name:"乙")
        var namedOverlap:[String:Any]=["segment_id":"named-overlap","session":"speaker-review-overlap-fixture","source_id":"remote","epoch":"overlap-epoch",
            "start":2.0,"end":2.5,"text":"同时说话","speaker":["basis":"multiple","reason":"overlap","cluster_ids":[0,1]]]
        overlapNames.register(segment:"named-overlap",item:namedOverlap)
        var unknownOverlap=namedOverlap;unknownOverlap["segment_id"]="unknown-overlap";unknownOverlap["start"]=3.0
        var unknownSpeaker=unknownOverlap["speaker"] as! [String:Any];unknownSpeaker["cluster_ids"]=[0,2];unknownOverlap["speaker"]=unknownSpeaker
        overlapNames.register(segment:"unknown-overlap",item:unknownOverlap)
        let overlapIndex=SpeakerReviewIndex.build(session:"speaker-review-overlap-fixture",
            turns:[ReadingTurn(id:"named-overlap",parent:"named-overlap",item:namedOverlap,parts:[("named-overlap",namedOverlap)],uncertain:false),
                   ReadingTurn(id:"unknown-overlap",parent:"unknown-overlap",item:unknownOverlap,parts:[("unknown-overlap",unknownOverlap)],uncertain:false)],names:overlapNames)
        overlapFixtureOwner.naming=overlapNames
        let overlapController=MinimalSpeakerReviewController(owner:overlapFixtureOwner)
        _=overlapController.buildContent()
        overlapController.index=overlapIndex;overlapController.choices=[.simultaneous]
        overlapController.filter.addItem(withTitle:overlapController.title(.simultaneous,index:overlapIndex))
        overlapController.filter.selectItem(at:0)
        overlapController.visibleEntries=overlapIndex.simultaneous
        overlapController.targets=[overlapNames.key(segment:"overlap-a")!,overlapNames.key(segment:"overlap-b")!]
        for key in overlapController.targets {overlapController.target.addItem(withTitle:overlapNames.displayName(speaker:key)!.value)}
        overlapController.target.selectItem(at:0)
        overlapController.renderEntries(overlapController.visibleEntries)
        overlapController.partItems=["named-overlap":namedOverlap]
        overlapController.selectedPartIDs=["named-overlap"];overlapController.selectedTurnIDs=["named-overlap"]
        overlapController.selectedPartForReturn="named-overlap"
        overlapController.updateControls()
        overlapController.nameField.stringValue="人工更正姓名"
        overlapController.updateControls()
        guard overlapIndex.simultaneous.count==1,overlapIndex.unassigned.count==1,
              overlapController.title(.simultaneous,index:overlapIndex)=="多人同时发言 · 1轮",
              overlapController.entryLabel(overlapIndex.simultaneous[0])=="甲、乙 · 同时发言",
              overlapIndex.simultaneous[0].text=="同时说话",
              overlapController.textView.string.contains("甲、乙 · 同时发言"),overlapController.textView.string.contains("同时说话"),
              overlapController.nameField.isEnabled,overlapController.renameButton.isEnabled,overlapController.assignButton.isEnabled,
              overlapController.originalButton.isEnabled else{throw Failure(code:"speaker_review_named_overlap_ui_projection")}
        overlapController.choices=[.unassigned]
        overlapController.otherEntries=overlapIndex.unassigned
        overlapController.filter.removeAllItems();overlapController.filter.addItem(withTitle:overlapController.title(.unassigned,index:overlapIndex))
        overlapController.filter.selectItem(at:0);overlapController.displayCurrentChoice()
        let unknownPart=overlapController.mappedPart(for:"unknown-overlap")
        guard overlapController.choices.count==1,overlapController.title(.unassigned,index:overlapIndex)=="其他发言 · 可查看",
              overlapController.visibleEntries.count==overlapIndex.unassigned.count,
              overlapController.visibleEntries.map(\.id)==["unknown-overlap"],
              !overlapController.textView.string.contains("〔待确认〕"),
              (unknownPart.flatMap{overlapController.textView.textStorage?.attribute(.underlineStyle,at:$0.range.location,effectiveRange:nil) as? Int} ?? 0) != 0,
              unknownPart.flatMap{overlapController.textView.textStorage?.attribute(.toolTip,at:$0.range.location,effectiveRange:nil) as? String}?.contains("其他发言")==true else{throw Failure(code:"speaker_review_other_speech_single_entry")}
        var sameNameFixtureNames=SessionNames()
        let sameA=overlapSlot("same-name-a",0),sameB=overlapSlot("same-name-b",1)
        sameNameFixtureNames.register(segment:"same-name-a",item:sameA);sameNameFixtureNames.setSpeaker(segment:"same-name-a",name:"张三")
        sameNameFixtureNames.register(segment:"same-name-b",item:sameB);sameNameFixtureNames.setSpeaker(segment:"same-name-b",name:"张三")
        var sameOverlap=namedOverlap;sameOverlap["segment_id"]="same-name-overlap";sameOverlap["start"]=2.5;sameOverlap["end"]=3.0
        sameNameFixtureNames.register(segment:"same-name-overlap",item:sameOverlap)
        let sameTurns=[("same-name-a",sameA),("same-name-b",sameB),("same-name-overlap",sameOverlap)].map {
            ReadingTurn(id:$0.0,parent:$0.0,item:$0.1,parts:[($0.0,$0.1)],uncertain:false)
        }
        let sameIndex=SpeakerReviewIndex.build(session:overlapFixtureOwner.activeSession ?? "",turns:sameTurns,names:sameNameFixtureNames)
        let sameNameFixtureOwner=Delegate();sameNameFixtureOwner.activeSession=overlapFixtureOwner.activeSession;sameNameFixtureOwner.naming=sameNameFixtureNames
        let sameController=MinimalSpeakerReviewController(owner:sameNameFixtureOwner)
        let sameTitles=sameIndex.people.map{sameController.title(.person($0.key),index:sameIndex)}
        guard sameIndex.people.count==1,sameIndex.people[0].keys.count==2,sameIndex.simultaneous.isEmpty,
              sameTitles==["张三 · 3轮"] else{throw Failure(code:"speaker_review_same_confirmed_name_is_one_person_choice")}
        var automaticNames=SessionNames();var automaticTurns:[ReadingTurn]=[]
        for slot in 0..<3 {
            var item=overlapSlot("auto-name-\(slot)",0);item["start"]=Double(slot);item["end"]=Double(slot)+0.5;item["revision"]=0
            automaticNames.register(segment:"auto-name-\(slot)",item:item)
            automaticTurns.append(ReadingTurn(id:"auto-name-\(slot)",parent:"auto-name-\(slot)",item:item,parts:[("auto-name-\(slot)",item)],uncertain:false))
        }
        let autoKey=automaticNames.key(segment:"auto-name-0")!
        let autoEvidence=(0..<3).map{VoiceprintEvidenceRef(id:"auto-name-\($0)",revision:0)}
        let autoCandidate=VoiceprintRecommendation(personID:"00000000-0000-4000-8000-000000000001",name:"示例人物82",archiveRevision:1,evidenceCount:3,support:autoEvidence)
        guard automaticNames.reconcileAutoVoiceprint(key:autoKey,candidate:autoCandidate) else{throw Failure(code:"speaker_review_auto_name_fixture_setup")}
        let automaticIndex=SpeakerReviewIndex.build(session:overlapFixtureOwner.activeSession ?? "",turns:automaticTurns,names:automaticNames)
        let automaticFixtureOwner=Delegate();automaticFixtureOwner.activeSession=overlapFixtureOwner.activeSession;automaticFixtureOwner.naming=automaticNames
        let automaticController=MinimalSpeakerReviewController(owner:automaticFixtureOwner)
        guard automaticIndex.people.count==1,automaticController.title(.person(autoKey),index:automaticIndex)=="示例人物82 · 3轮",
              automaticController.speakerTooltip(autoKey).contains("声音识别候选：示例人物82"),
              automaticController.speakerTooltip(autoKey).contains("尚未人工确认") else{throw Failure(code:"speaker_review_auto_candidate_not_presented_as_confirmed")}
        let manualSame=overlapSlot("manual-same-person",1)
        automaticNames.register(segment:"manual-same-person",item:manualSame)
        automaticNames.setSpeaker(segment:"manual-same-person",name:"示例人物82")
        let mixedTurns=automaticTurns+[ReadingTurn(id:"manual-same-person",parent:"manual-same-person",item:manualSame,parts:[("manual-same-person",manualSame)],uncertain:false)]
        let mixedIndex=SpeakerReviewIndex.build(session:overlapFixtureOwner.activeSession ?? "",turns:mixedTurns,names:automaticNames)
        guard mixedIndex.people.count==1,mixedIndex.people[0].keys.count==2,mixedIndex.people[0].entries.count==4,
              automaticNames.displayName(speaker:autoKey)?.origin == .voiceprint else{throw Failure(code:"speaker_review_same_name_not_split_by_recognition_origin")}
        let review=SpeakerReviewIndex.build(session:owner.activeSession ?? "",turns:owner.readingTurns(),names:owner.naming)
        guard review.people.count>=2,let source=review.people.first,let destination=review.people.dropFirst().first,
              let entry=source.entries.first,let partID=entry.partIDs.first else {throw Failure(code:"speaker_review_fixture_insufficient_people")}
        let window=SpeakerReviewWindow(contentRect:NSRect(x:20,y:20,width:640,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        owner.speakerReviewWindow=window
        present(in:window,for:source.key)
        defer {
            owner.naming=originalNames;owner.persistSessionNames();owner.markAllTranscriptParentsDirty()
            if window.isVisible {window.performClose(nil)}
        }
        guard let fixturePart=mappedPart(for:partID) else{throw Failure(code:"speaker_review_refresh_fixture_part_missing")}
        textView.setSelectedRange(fixturePart.range);updateSelection()
        selectedPartForReturn=partID;nameField.stringValue="未保存姓名草稿";nameDraftChanged=true
        let fixtureStorage=textView.textStorage,fixtureText=textView.string
        let fixtureSelection=textView.selectedRanges.map{$0.rangeValue},fixturePartIDs=selectedPartIDs,fixtureTurnIDs=selectedTurnIDs
        refresh()
        guard fixtureStorage===textView.textStorage,textView.string==fixtureText,
              textView.selectedRanges.map({$0.rangeValue})==fixtureSelection,
              selectedPartIDs==fixturePartIDs,selectedTurnIDs==fixtureTurnIDs,
              nameField.stringValue=="未保存姓名草稿",nameDraftChanged else{throw Failure(code:"speaker_review_progress_refresh_lost_selection_or_draft")}
        refresh(preferred:destination.key)
        guard selectedChoiceKey==owner.naming.canonical(destination.key) else{throw Failure(code:"speaker_review_preferred_person_switch_skipped")}
        refresh(preferred:source.key)
        guard selectedChoiceKey==owner.naming.canonical(source.key) else{throw Failure(code:"speaker_review_preferred_person_restore_skipped")}
        window.setFrame(NSRect(x:20,y:20,width:640,height:600),display:true)
        window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        updateTextGeometry()
        guard editDetails?.isHidden==true else {throw Failure(code:"speaker_review_default_not_minimal")}
        guard visibleTranscriptText() else {throw Failure(code:"speaker_review_fixture_body_not_visible")}
        try saveWindow(window,to:directory.appendingPathComponent("speaker-review-default.png"))
        toggleEditing();window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        guard editDetails?.isHidden==false else {throw Failure(code:"speaker_review_editor_not_open")}
        updateTextGeometry()
        guard visibleTranscriptText() else {throw Failure(code:"speaker_review_fixture_editor_body_not_visible")}
        try saveWindow(window,to:directory.appendingPathComponent("speaker-review-editor.png"))

        nameField.stringValue="复核人物"
        renameSelectedPerson()
        guard owner.naming.name(speaker:source.key)=="复核人物" else {throw Failure(code:"speaker_review_group_rename_failed")}
        let deadline=Date().addingTimeInterval(1)
        while (!owner.output.string.contains("复核人物") || owner.fullTranscriptRefreshPending || owner.fullRefreshBuildInFlight || owner.dirtyTranscriptQueueIndex<owner.dirtyTranscriptQueue.count || persistenceInFlight) && Date()<deadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard owner.output.string.contains("复核人物") else {throw Failure(code:"speaker_review_rename_did_not_publish_without_new_audio")}
        try checkBridgeLabels(owner)
        var projectionWait=0
        func waitForProjection(_ view:Delegate,_ predicate:()->Bool,_ controller:MinimalSpeakerReviewController?=nil) async throws {
            projectionWait+=1
            let deadline=Date().addingTimeInterval(2)
            while (!predicate() || view.fullTranscriptRefreshPending || view.fullRefreshBuildInFlight || view.dirtyTranscriptQueueIndex<view.dirtyTranscriptQueue.count || (controller?.persistenceInFlight ?? persistenceInFlight)) && Date()<deadline {
                try await Task.sleep(nanoseconds:10_000_000)
            }
            guard predicate(),!view.fullTranscriptRefreshPending,!view.fullRefreshBuildInFlight,view.dirtyTranscriptQueueIndex>=view.dirtyTranscriptQueue.count,!(controller?.persistenceInFlight ?? persistenceInFlight) else{
                let excerpt=(view.output.string as NSString).substring(to:min(240,(view.output.string as NSString).length))
                throw Failure(code:"speaker_review_automatic_projection_failed_\(projectionWait):\(excerpt)")
            }
        }
        guard nameField.isEnabled,renameButton.isHidden==false,scopeLabel.stringValue.contains("本场") else{throw Failure(code:"speaker_review_simple_name_and_scope_missing")}
        nameField.stringValue="再次改名";controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));renameButton.performClick(nil)
        try await waitForProjection(owner,{owner.output.string.contains("再次改名") && !owner.output.string.contains("复核人物")})
        try checkBridgeLabels(owner)
        guard source.entries.flatMap(\.partIDs).allSatisfy({owner.naming.name(segment:$0)=="再次改名"}),
              destination.entries.flatMap(\.partIDs).allSatisfy({owner.naming.name(segment:$0) != "再次改名"}) else{throw Failure(code:"speaker_review_rename_scope_leaked")}
        let noOpNameRevision=owner.naming.correctionRevision
        renameSelectedPerson()
        guard owner.naming.correctionRevision==noOpNameRevision else{throw Failure(code:"speaker_review_repeated_save_changed_mapping")}
        undoButton.performClick(nil)
        try await waitForProjection(owner,{owner.output.string.contains("复核人物") && !owner.output.string.contains("再次改名")})
        try checkBridgeLabels(owner)

        // Duplicate manually confirmed names are one review choice, while the
        // original source keys remain distinct for future correction and undo.
        let previousReuseNames=owner.naming
        guard let sourcePart=source.entries.first?.partIDs.first,let destinationPart=destination.entries.first?.partIDs.first else {
            throw Failure(code:"speaker_review_reuse_fixture_parts")
        }
        owner.naming.setSpeaker(segment:sourcePart,name:"Alice")
        owner.naming.setSpeaker(segment:destinationPart,name:"Alice")
        owner.markAllTranscriptParentsDirty();refresh(preferred:source.key)
        guard owner.naming.name(speaker:source.key)=="Alice",owner.naming.name(speaker:destination.key)=="Alice",
              owner.naming.canonical(source.key) != owner.naming.canonical(destination.key),
              let sameNamePerson=index?.people.first(where:{$0.keys.contains(source.key) && $0.keys.contains(destination.key)}),
              !reuseTargets.contains(destination.key) else {
            throw Failure(code:"speaker_review_same_confirmed_name_not_grouped")
        }
        nameField.stringValue="Alice统一更名";controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));renameSelectedPerson()
        let groupedRenameDeadline=Date().addingTimeInterval(1)
        while (owner.naming.name(speaker:source.key) != "Alice统一更名" || owner.naming.name(speaker:destination.key) != "Alice统一更名") && Date()<groupedRenameDeadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard owner.naming.name(speaker:source.key)=="Alice统一更名",owner.naming.name(speaker:destination.key)=="Alice统一更名" else {
            throw Failure(code:"speaker_review_multiname_rename_failed_\(owner.naming.name(speaker:source.key) ?? "nil")_\(owner.naming.name(speaker:destination.key) ?? "nil")")
        }
        try await waitForProjection(owner,{owner.output.string.contains("Alice统一更名")})
        undoCorrection()
        try await waitForProjection(owner,{owner.naming.name(speaker:source.key)=="Alice" && owner.naming.name(speaker:destination.key)=="Alice"})
        guard owner.naming.canonical(source.key) != owner.naming.canonical(destination.key),sameNamePerson.keys.count>=2 else {
            throw Failure(code:"speaker_review_grouped_rename_changed_source_identity")
        }
        owner.naming=previousReuseNames;owner.persistSessionNames();owner.markAllTranscriptParentsDirty();refresh(preferred:source.key)
        try checkBridgeLabels(owner)
        guard sourceSnapshot.filter({SessionSpeakerKey.from($0.value)==nil}).keys.allSatisfy({owner.naming.name(segment:$0)==nil}) else{throw Failure(code:"speaker_review_unknown_inherited_name_from_text")}
        owner.cacheWriteQueue.sync{}
        guard let cacheID=owner.currentCacheID,let session=owner.activeSession else{throw Failure(code:"speaker_review_reopen_scope_missing")}
        let saved=try Data(contentsOf:owner.recoveryBase().appendingPathComponent(cacheID).appendingPathComponent("session-names.json"))
        let reopened=Delegate();reopened.previewRenderOnly=true;reopened.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));reopened.activeSession=session;reopened.currentCacheID=owner.currentCacheID;reopened.recoveryRootOverride=owner.recoveryRootOverride;reopened.meetingTitle=owner.meetingTitle;reopened.sessionSource=owner.sessionSource;reopened.phase=owner.phase;reopened.cachedTranscriptionComplete=owner.cachedTranscriptionComplete;reopened.absoluteTime=owner.absoluteTime
        for id in owner.timeline.orderedIDs {if let event=sourceSnapshot[id]{reopened.receive(event)}}
        try reopened.naming.restore(saved,session:session);reopened.markAllTranscriptParentsDirty()
        try await waitForProjection(reopened,{reopened.output.string.contains("复核人物")})
        guard reopened.transcriptExport()==owner.transcriptExport() else{
            try owner.transcriptExport().write(to:directory.appendingPathComponent("export-live.txt"),atomically:true,encoding:.utf8);try reopened.transcriptExport().write(to:directory.appendingPathComponent("export-reopened.txt"),atomically:true,encoding:.utf8)
            throw Failure(code:"speaker_review_saved_names_not_shared_by_export")}
        let history=Delegate();history.previewRenderOnly=true;history.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));history.isHistoryReader=true;history.workspaceOwner=owner
        history.activeSession="speaker-history-scope";history.recoveryRootOverride=directory;history.currentCacheID=UUID().uuidString
        try FileManager.default.createDirectory(at:history.recoveryBase().appendingPathComponent(history.currentCacheID!),withIntermediateDirectories:true)
        for id in owner.timeline.orderedIDs {if var event=sourceSnapshot[id]{event["session"]=history.activeSession!;history.receive(event)}}
        try await waitForProjection(history,{!history.output.string.isEmpty})
        let liveText=owner.output.string,liveNames=owner.naming
        let historyPerson=SpeakerReviewIndex.build(session:history.activeSession!,turns:history.readingTurns(),names:history.naming).people[0]
        let historyWindow=SpeakerReviewWindow(contentRect:NSRect(x:0,y:0,width:640,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        let historyController=MinimalSpeakerReviewController(owner:history);historyController.present(in:historyWindow,for:historyPerson.key)
        owner.historyReader=history
        historyController.nameField.stringValue="历史人物";historyController.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));historyController.renameButton.performClick(nil)
        try await waitForProjection(history,{history.output.string.contains("历史人物")},historyController)
        try checkBridgeLabels(history)
        if checkBridge {guard (try readBridge(owner,current:true))["session"] as? String==owner.activeSession else{throw Failure(code:"speaker_history_bridge_stole_current_meeting")}}
        guard owner.output.string==liveText,owner.naming.correctionRevision==liveNames.correctionRevision,
              sourceSnapshot.keys.allSatisfy({owner.naming.name(segment:$0)==liveNames.name(segment:$0) && owner.naming.key(segment:$0)==liveNames.key(segment:$0)}) else{throw Failure(code:"speaker_review_history_edit_changed_live_session")}
        owner.historyReader=nil
        guard owner.displayedDocument===owner,owner.output.string==liveText else{throw Failure(code:"speaker_review_history_switch_lost_live_names")}
        historyController.undoButton.performClick(nil)
        try await waitForProjection(history,{!history.output.string.contains("历史人物")},historyController)
        try checkBridgeLabels(history)
        historyWindow.performClose(nil);history.window.orderOut(nil);reopened.window.orderOut(nil)

        if let filterRow=choices.firstIndex(where:{if case .person(let key)=$0 {return key==source.key};return false}) {filter.selectItem(at:filterRow)}
        displayCurrentChoice();updateControls()
        guard let selectedRange=mappedPart(for:partID)?.range else {throw Failure(code:"speaker_review_selection_missing")}
        textView.setSelectedRange(selectedRange);updateSelection()
        if let sameIndex=targets.firstIndex(of:source.key) {target.selectItem(at:sameIndex)}
        updateControls()
        let noOpRevision=owner.naming.correctionRevision
        guard !assignButton.isEnabled else {throw Failure(code:"speaker_review_same_target_enabled")}
        reassignSelection()
        guard owner.naming.correctionRevision==noOpRevision else {throw Failure(code:"speaker_review_same_target_pinned")}
        if let targetIndex=targets.firstIndex(of:destination.key) {target.selectItem(at:targetIndex)}
        updateControls();reassignSelection()
        guard owner.naming.key(segment:partID)==destination.key else {throw Failure(code:"speaker_review_selected_reassign_failed")}
        try await waitForProjection(owner,{owner.naming.key(segment:partID)==destination.key})
        undoCorrection()
        try await waitForProjection(owner,{owner.naming.key(segment:partID)==source.key})
        guard owner.naming.key(segment:partID)==source.key else {throw Failure(code:"speaker_review_reassign_undo_failed")}

        // Unknowns are independent sentences, and can be named even when no
        // acoustic group exists. Do not attribute their unknown neighbours.
        if let row=choices.firstIndex(where:{if case .unassigned=$0{return true};return false}) {
            filter.selectItem(at:row);displayCurrentChoice();updateControls()
            guard !nameField.isEnabled else{throw Failure(code:"unknown_name_without_selection_enabled")}
            guard let first=mappedParts.first else{throw Failure(code:"unknown_selection_missing")}
            let unknownID=first.id,untouched=Set(mappedParts.map(\.id)).subtracting([unknownID])
            textView.setSelectedRange(NSRange(location:first.range.location,length:0));updateSelection()
            guard nameField.isEnabled,selectedTurnIDs.count==1 else{throw Failure(code:"unknown_single_click_not_actionable")}
            nameField.stringValue="所选发言姓名";controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
            guard renameButton.isEnabled else{throw Failure(code:"unknown_direct_name_save_disabled")}
            renameButton.performClick(nil)
            try await waitForProjection(owner,{owner.output.string.contains("所选发言姓名")})
            owner.cacheWriteQueue.sync{}
            try await Task.sleep(nanoseconds:30_000_000)
            guard owner.naming.name(segment:unknownID)=="所选发言姓名",owner.naming.key(segment:unknownID)==nil,
                  untouched.allSatisfy({owner.naming.name(segment:$0)==nil}),
                  textView.string.contains("〔所选发言姓名〕"),!owner.naming.voiceConfirmations.contains(where:{$0.segmentIDs.contains(unknownID)}) else{throw Failure(code:"unknown_manual_name_scope_or_learning_leaked")}
            try saveWindow(window,to:directory.appendingPathComponent("speaker-review-unknown-marked.png"))
            undoCorrection();try await waitForProjection(owner,{!owner.output.string.contains("所选发言姓名")})
            guard owner.naming.name(segment:unknownID)==nil else{throw Failure(code:"unknown_direct_name_undo_failed")}
            if mappedParts.count>1 {
                textView.setSelectedRange(NSRange(location:0,length:(textView.string as NSString).length));updateSelection()
                if selectedTurnIDs.count>1 {guard !nameField.isEnabled,!renameButton.isEnabled else{throw Failure(code:"unknown_multiple_turn_name_enabled")}}
            }
        }

        if let filterRow=choices.firstIndex(where:{if case .person(let key)=$0 {return key==source.key};return false}) {filter.selectItem(at:filterRow)}
        if let targetIndex=targets.firstIndex(of:destination.key) {target.selectItem(at:targetIndex)}
        displayCurrentChoice();updateControls();mergeSelectedPerson()
        guard owner.naming.key(segment:partID)==destination.key else {throw Failure(code:"speaker_review_merge_failed")}
        try await waitForProjection(owner,{owner.naming.key(segment:partID)==destination.key})
        undoCorrection()
        try await waitForProjection(owner,{owner.naming.key(segment:partID)==source.key})
        guard owner.naming.key(segment:partID)==source.key else {throw Failure(code:"speaker_review_merge_undo_failed")}

        // Exercise the actual atomic writer failure path using an absent synthetic
        // root, then prove a stale completion cannot affect a switched document.
        refresh(preferred:source.key)
        guard let cacheID=owner.currentCacheID,let session=owner.activeSession else{throw Failure(code:"speaker_review_failure_fixture_scope")}
        let previousNames=owner.naming,previousRoot=owner.recoveryRootOverride
        let namesFile=owner.recoveryBase().appendingPathComponent(cacheID).appendingPathComponent("session-names.json")
        let diskBefore=try Data(contentsOf:namesFile),previousName=owner.naming.name(speaker:source.key) ?? ""
        let failingRoot=directory.appendingPathComponent("missing-speaker-write-root",isDirectory:true)
        try? FileManager.default.removeItem(at:failingRoot)
        owner.recoveryRootOverride=failingRoot
        nameField.stringValue="失败后保留草稿";controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));renameSelectedPerson()
        guard owner.naming.name(speaker:source.key)=="失败后保留草稿",persistenceInFlight else{throw Failure(code:"speaker_review_failure_fixture_did_not_start")}
        let failureDeadline=Date().addingTimeInterval(2)
        while !scopeLabel.stringValue.contains("未保存") && Date()<failureDeadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight,owner.naming.name(speaker:source.key)==previousName,nameField.stringValue=="失败后保留草稿",
              try Data(contentsOf:namesFile)==diskBefore else{throw Failure(code:"speaker_review_failed_write_did_not_rollback_or_preserve_draft")}
        try await waitForProjection(owner,{owner.output.string.contains(previousName) && !owner.output.string.contains("失败后保留草稿")})

        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        owner.cacheWriteQueue.async {entered.signal();release.wait()}
        guard entered.wait(timeout:.now()+2) == .success else{throw Failure(code:"speaker_review_stale_fixture_queue_timeout")}
        owner.recoveryRootOverride=failingRoot
        nameField.stringValue="切页迟到草稿";controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));renameSelectedPerson()
        guard persistenceInFlight else{release.signal();throw Failure(code:"speaker_review_stale_fixture_did_not_start")}
        let switchedSession="speaker-review-switched-session",switchedCache=UUID().uuidString,switchedGeneration=owner.meetingDocumentGeneration+1
        owner.activeSession=switchedSession;owner.currentCacheID=switchedCache;owner.meetingDocumentGeneration=switchedGeneration
        refresh();let staleViewNames=owner.naming
        release.signal();owner.cacheWriteQueue.sync{}
        try await Task.sleep(nanoseconds:50_000_000)
        guard owner.activeSession==switchedSession,owner.currentCacheID==switchedCache,owner.naming.correctionRevision==staleViewNames.correctionRevision,
              owner.naming.name(speaker:source.key)==staleViewNames.name(speaker:source.key) else{throw Failure(code:"speaker_review_stale_callback_contaminated_switched_document")}
        owner.activeSession=session;owner.currentCacheID=cacheID;owner.meetingDocumentGeneration=switchedGeneration+1
        owner.naming=previousNames;owner.recoveryRootOverride=previousRoot;owner.markAllTranscriptParentsDirty();refresh(preferred:source.key)
        try await waitForProjection(owner,{owner.output.string.contains(previousName) && !owner.output.string.contains("切页迟到草稿")})
        let current=owner.segments
        let currentTexts=owner.timeline.orderedIDs.compactMap{current[$0]?["text"] as? String}.joined()
        guard Set(current.keys)==originalIDs,currentTexts==originalTexts else {throw Failure(code:"speaker_review_changed_original_transcript")}
        let pngNames=["speaker-review-default.png","speaker-review-editor.png"]
        return ["type":"minimal_speaker_ui_checks","passed":25,"people":review.people.count,
                "original_records_preserved":true,"default_editor_hidden":true,"selection_reassign":true,
                "default_name_visible":true,"automatic_projection_without_audio":true,"repeat_rename_and_undo":true,"saved_reopen_matches_export":true,"history_switch_scope_preserved":true,
                "current_history_bridge_consistency":checkBridge,
                "merge_undo":true,"unknown_direct_name_and_undo":true,"unknown_no_identity_or_voice_learning_invented":true,
                "explicit_same_name_group_reuse_and_undo":true,
                "named_overlap_filter_separate_and_unknown_count_preserved":true,"overlap_ui_names_both_people_and_marks_simultaneous":true,
                "synthetic_named_overlap_turns":overlapIndex.simultaneous.count,"synthetic_unassigned_turns":overlapIndex.unassigned.count,
                "failed_persistence_rolls_back_projection_and_disk_but_keeps_retry_draft":true,"stale_persistence_callback_ignored_after_document_switch":true,
                "screenshots":pngNames+["speaker-review-unknown-marked.png"],"window_width":640,
                "capture":false,"cloud":false,"keychain":false]
    }

    @MainActor func voiceprintFixture(owner:Delegate,key:SessionSpeakerKey,directory:URL) async throws->[String] {
        let window=SpeakerReviewWindow(contentRect:NSRect(x:0,y:0,width:700,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        present(in:window,for:key);window.orderOut(nil);window.contentView?.layoutSubtreeIfNeeded()
        guard recommendationRow?.isHidden==false,recommendationLabel.stringValue=="已按声音识别，姓名可直接修改。",rejectVoiceButton.title=="撤销自动识别",editDetails?.isHidden==true else{throw Failure(code:"voice_automatic_name_controls")}
        guard nameField.stringValue=="测试甲方",renameButton.title=="确认",renameButton.isEnabled,nameField.action==nil,
              recommendationRow?.arrangedSubviews.count==1,rejectVoiceButton.superview===editDetails else{throw Failure(code:"voice_single_confirmation_control")}
        try saveWindow(window,to:directory.appendingPathComponent("voice-recommendation.png"))
        let automaticNames=owner.naming
        // This UI round trip must not enroll a valid sample into the archive
        // used by the surrounding conflicting-name learning regression.
        let service=owner.voiceprintService;owner.voiceprintService=nil
        defer {owner.voiceprintService=service}
        renameButton.performClick(nil)
        let confirmDeadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<confirmDeadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight,owner.naming.name(speaker:key)=="测试甲方",renameButton.title=="已确认",!renameButton.isEnabled,
              recommendationRow?.isHidden==true else{throw Failure(code:"voice_unified_confirmation_not_saved")}
        try saveWindow(window,to:directory.appendingPathComponent("voice-confirmed.png"))
        undoCorrection()
        let restoreDeadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<restoreDeadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight,owner.naming.name(speaker:key)==nil,owner.naming.autoNameIsSuppressed(key) else{throw Failure(code:"voice_unified_confirmation_undo")}
        owner.naming=automaticNames;owner.voiceprintService=service;refresh(preferred:key)
        rejectVoice()
        guard owner.naming.displayName(speaker:key)==nil,owner.naming.autoNameIsSuppressed(key),recommendationRow?.isHidden==true else{throw Failure(code:"voice_revoke_button")}
        try owner.settleTranscriptForOfflineReview()
        guard !owner.transcriptExport().contains("测试甲方") else{throw Failure(code:"voice_revoke_export")}
        fixtureConfirmation={_,_,_ in true}
        nameField.stringValue="人工确认的姓名";renameSelectedPerson()
        let deadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight else{throw Failure(code:"voice_manual_name_persist_timeout")}
        guard owner.naming.name(speaker:key)=="人工确认的姓名",owner.naming.displayName(speaker:key)?.origin == .manual else{throw Failure(code:"voice_manual_override")}
        undoCorrection()
        let undoDeadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<undoDeadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight else{throw Failure(code:"voice_manual_undo_persist_timeout")}
        guard owner.naming.name(speaker:key)==nil,owner.naming.displayName(speaker:key)==nil,owner.naming.autoNameIsSuppressed(key) else{throw Failure(code:"voice_manual_undo_keeps_suppression")}
        window.performClose(nil)
        return ["automatic_name_has_revoke_control_in_more","single_prefilled_confirmation_saves_and_undoes","confirmed_name_disables_repeat_confirmation","revoke_removes_automatic_name_from_export","manual_override_uses_existing_editor","manual_undo_keeps_automatic_name_suppressed"]
    }

    @MainActor func partialVoiceprintFixture(key:SessionSpeakerKey,directory:URL) async throws->[String] {
        let window=SpeakerReviewWindow(contentRect:NSRect(x:0,y:0,width:700,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        self.window=window;window.reviewController=self;window.contentView=buildContent();refresh(preferred:key)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let owner,let candidate=owner.voiceprintRecommendation(for:key) else{throw Failure(code:"partial_voice_suggestion_missing")}
        let previousNames=owner.naming
        guard recommendationRow?.isHidden==false,recommendationLabel.stringValue.contains("请确认这组是否为同一人"),
              nameField.stringValue==candidate.name,renameButton.title=="确认",renameButton.isEnabled,
              editDetails?.isHidden==true,owner.naming.displayName(speaker:key)==nil else{throw Failure(code:"partial_voice_suggestion_ui")}
        try saveWindow(window,to:directory.appendingPathComponent("partial-voice-suggestion.png"))
        renameButton.performClick(nil)
        let deadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight,owner.naming.name(speaker:key)==candidate.name,
              renameButton.title=="已确认",!renameButton.isEnabled else{throw Failure(code:"partial_voice_single_confirmation_failed")}
        let supported=Set(candidate.support.map(\.id))
        guard owner.naming.voiceConfirmations.filter({$0.name==candidate.name}).allSatisfy({Set($0.segmentIDs).isSubset(of:supported)}) else{throw Failure(code:"partial_voice_learned_unmatched_audio")}
        undoCorrection()
        let undoDeadline=Date().addingTimeInterval(2)
        while persistenceInFlight && Date()<undoDeadline {try await Task.sleep(nanoseconds:10_000_000)}
        guard !persistenceInFlight,owner.naming.name(speaker:key)==nil,owner.naming.autoNameIsSuppressed(key),nameField.stringValue.isEmpty,!renameButton.isEnabled else{throw Failure(code:"partial_voice_confirmation_undo")}
        owner.naming=previousNames;owner.persistSessionNames()
        window.close()
        return ["partial_voice_uses_same_prefilled_confirmation","partial_voice_confirmation_and_undo_work","partial_voice_learning_excludes_unmatched_audio","partial_voice_ui_does_not_show_an_automatic_group_name"]
    }

    private func visibleTranscriptText()->Bool {
        guard textView.frame.width>300,textView.frame.height>0,
              let container=textView.textContainer,let layout=textView.layoutManager,
              let part=mappedParts.first else{return false}
        layout.ensureLayout(for:container)
        let glyphRange=layout.glyphRange(forCharacterRange:part.range,actualCharacterRange:nil)
        guard glyphRange.length>0 else{return false}
        let glyphBounds=layout.boundingRect(forGlyphRange:glyphRange,in:container).insetBy(dx:0,dy:-1)
        return !NSIntersectionRect(glyphBounds,textView.visibleRect).isEmpty
    }

    private func mappedPart(for id:String)->SpeakerReviewTextPart? {mappedParts.first{$0.id==id}}
    @MainActor func renderSavedContext(directory:URL)throws->[String:Any] {
        guard Credential.offline,owner?.previewRenderOnly==true else{throw Failure(code:"saved_context_review_scope")}
        let window=SpeakerReviewWindow(contentRect:NSRect(x:0,y:0,width:800,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        present(in:window,for:nil);window.orderOut(nil)
        defer {window.close()}
        guard let row=choices.firstIndex(where:{if case .unassigned=$0{return true};return false}) else{return ["paragraphs":0,"parts":0]}
        filter.selectItem(at:row);displayCurrentChoice();updateControls();updateTextGeometry()
        let expected=Set(visibleEntries.flatMap(\.partIDs)),actual=Set(mappedParts.map(\.id))
        guard expected==actual,mappedParts.count==actual.count,renderedParagraphCount<=visibleEntries.count,
              mappedParts.allSatisfy({(textView.string as NSString).substring(with:$0.range)==$0.item["text"] as? String}) else{throw Failure(code:"saved_context_mapping_changed")}
        textView.setSelectedRange(NSRange(location:0,length:(textView.string as NSString).length));updateSelection()
        guard Set(selectedPartIDs)==expected else{throw Failure(code:"saved_context_selection_leaked")}
        if selectedTurnIDs.count>1 {guard !nameField.isEnabled,!renameButton.isEnabled,!assignButton.isEnabled else{throw Failure(code:"saved_context_cross_person_assignment")}}
        textView.setSelectedRange(NSRange(location:0,length:0));updateSelection()
        textView.scrollRangeToVisible(NSRange(location:0,length:0));window.contentView?.layoutSubtreeIfNeeded()
        try textView.string.write(to:directory.appendingPathComponent("other-speech-context.txt"),atomically:true,encoding:.utf8)
        try saveWindow(window,to:directory.appendingPathComponent("other-speech-context.png"))
        return ["original_entries":visibleEntries.count,"paragraphs":renderedParagraphCount,"parts":actual.count,
                "all_unresolved_parts_preserved":true,"context_cannot_be_reassigned":true,"original_turn_boundaries_preserved":true]
    }
    private func saveWindow(_ window:NSWindow,to url:URL)throws {
        guard let view=window.contentView else {throw Failure(code:"speaker_review_view_missing")}
        let bounds=view.bounds
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:bounds) else {throw Failure(code:"speaker_review_bitmap_unavailable")}
        view.cacheDisplay(in:bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw Failure(code:"speaker_review_png_unavailable")}
        try png.write(to:url,options:.atomic)
    }
}

@MainActor func renderSavedUnassignedReview(owner:Delegate,directory:URL)throws->[String:Any] {
    try MinimalSpeakerReviewController(owner:owner).renderSavedContext(directory:directory)
}

extension Delegate {
    func stopSpeakerAudioPreview() {
        for document in [self,historyReader].compactMap({$0}) {
            (document.speakerReviewWindow as? SpeakerReviewWindow)?.reviewController?.stopPreview()
        }
    }
    func closeSpeakerReviewWindow(_ foreground:NSWindow?)->Bool {
        guard let review=foreground as? SpeakerReviewWindow else{return false}
        review.performClose(nil);return true
    }
    @objc func showSpeakerReview() {guard !(workspaceOwner ?? self).meetingDeletionBusy else{return};displayedDocument.openSpeakerReview()}
    func refreshOpenSpeakerReview() {refreshQuickVoiceCandidate();(speakerReviewWindow as? SpeakerReviewWindow)?.reviewController?.refresh()}
    func openSpeakerReview(for key:SessionSpeakerKey?=nil) {
        if let existing=speakerReviewWindow as? SpeakerReviewWindow,let controller=existing.reviewController {
            controller.refresh(preferred:key);existing.makeKeyAndOrderFront(nil);return
        }
        let frame=NSRect(x:0,y:0,width:800,height:620)
        let window=SpeakerReviewWindow(contentRect:frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        let controller=MinimalSpeakerReviewController(owner:self)
        speakerReviewWindow=window;controller.present(in:window,for:key)
    }
}

@MainActor func minimalSpeakerUIChecks(owner:Delegate,directory:URL) async throws->[String:Any] {
    let controller=MinimalSpeakerReviewController(owner:owner)
    return try await controller.runFixtureChecks(owner:owner,directory:directory)
}

@MainActor func minimalVoiceprintUIChecks(owner:Delegate,key:SessionSpeakerKey,directory:URL) async throws->[String] {
    try await MinimalSpeakerReviewController(owner:owner).voiceprintFixture(owner:owner,key:key,directory:directory)
}
@MainActor func partialVoiceprintUIChecks(owner:Delegate,key:SessionSpeakerKey,directory:URL) async throws->[String] {
    try await MinimalSpeakerReviewController(owner:owner).partialVoiceprintFixture(key:key,directory:directory)
}

@MainActor func clickSpeakerReviewStopForChecks(owner:Delegate)->Bool {
    MinimalSpeakerReviewController(owner:owner).clickRunningCoarseStopForChecks()
}

@MainActor func speakerConsistencyChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"speaker_consistency_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let owner=Delegate();owner.previewRenderOnly=true;owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    owner.activeSession="speaker-consistency";owner.currentCacheID=UUID().uuidString;owner.recoveryRootOverride=directory;owner.phase.phase = .recording
    let cache=directory.appendingPathComponent(owner.currentCacheID!)
    try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["session":owner.activeSession!,"cache_id":owner.currentCacheID!,"bundle":"*microphone*"]).write(to:cache.appendingPathComponent("meeting.json"))
    for (id,start,slot) in [("person-a",0.0,0),("person-b",2.0,1),("person-a-again",4.0,0),("unknown-short",6.0,-1)] {
        let speaker:[String:Any]=slot<0 ? ["basis":"unknown","reason":"no_speaker_evidence"]:["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"consistency"]
        owner.receive(["type":"segment","session":owner.activeSession!,"segment_id":id,"source_id":"mic","track":"mic","epoch":"consistency","start":start,"end":start+1,"revision":1,"final":true,"text":slot<0 ? "对。":"同一麦克风下的合成发言。","speaker":speaker])
    }
    try owner.settleTranscriptForOfflineReview()
    let result=try await MinimalSpeakerReviewController(owner:owner).runFixtureChecks(owner:owner,directory:directory,checkBridge:true)
    owner.window.orderOut(nil)
    return result
}
