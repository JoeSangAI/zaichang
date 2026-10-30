import AppKit

/// Charcoal, paper and vermilion derived from the supplied app icon.
enum MeetingVisualStyle {
    private static func color(_ light:UInt32,_ dark:UInt32)->NSColor {
        NSColor(name:nil,dynamicProvider:{appearance in
            let choice=appearance.bestMatch(from:[.aqua,.darkAqua])
            return Self.rgb(choice == .darkAqua ? dark:light)
        })
    }
    private static func rgb(_ hex:UInt32)->NSColor {
        NSColor(srgbRed:CGFloat((hex>>16)&0xff)/255,
                green:CGFloat((hex>>8)&0xff)/255,
                blue:CGFloat(hex&0xff)/255,alpha:1)
    }

    // Warm paper reading surface (2026-10-15 visual pass); dark mode stays neutral.
    static let surface=color(0xFBFAF7,0x1D1D20)
    static let sidebar=color(0xF3F1EC,0x232327)
    static let ink=color(0x1F2024,0xECEDEF)
    static let muted=color(0x6B6E76,0xA7AAB3)
    static let selection=color(0xFFFFFF,0x2E2E33)
    static let accent=color(0xC73532,0xCA3935)
    static let accentHover=color(0xB72E2B,0xB82F2B)
    static let accentPressed=color(0xA32826,0xA92B27)
    static let quietAccent=color(0xAB615E,0xC27874)
    static let border=color(0xE6E2DA,0x313136)
    static let faint=color(0xA2A4AA,0x6C6D74)
    static let quietFill=color(0xF1EFEB,0x2A2A2F)
    static let disabledAccent=color(0x565963,0x5B5E69)
    static let keyboardFocus=NSColor.keyboardFocusIndicatorColor

    // One stable colour per speaker identity; unknown speakers stay neutral.
    static let charcoal=color(0x1C1D21,0x2C2D32)
    static let charcoalBorderWidth:CGFloat=0.5
    static let charcoalBorder=color(0x1C1D21,0x3D3E42) // white 8% on dark charcoal, 0.5pt
    static let accentTint=color(0xFBF0EE,0x3A2624)
    static let accentText=color(0x8E2A27,0xF0A19C)
    static let accentTintBorder=color(0xEBD3CF,0x553230)
    static let listeningDot:NSImage={
        let image=NSImage(size:NSSize(width:12,height:12),flipped:false) {rect in
            MeetingVisualStyle.accent.setFill();NSBezierPath(ovalIn:NSRect(x:3,y:3,width:6,height:6)).fill();return true
        }
        image.isTemplate=false;return image
    }()
    /// Maximum line length of the transcript and its header, in points.
    static let readingWidth:CGFloat=700
    // Fixed tones on the charcoal capsule, the same in light and dark mode.
    static let capsuleInk=rgb(0x1C1D21)
    static let capsulePaper=rgb(0xF2F0EC)
    static let capsulePaperPressed=rgb(0xDCD8D1)
    static let capsuleLive=rgb(0xF0544D)
    static let capsuleIdleDot=rgb(0x8A8D94)
    static let capsuleSecondary=NSColor.white.withAlphaComponent(0.62)
    static let capsuleComputerBar=rgb(0x8E9099)
    static func titleFont(_ size:CGFloat=32)->NSFont {NSFontManager.shared.font(withFamily:"Songti SC",traits:.boldFontMask,weight:9,size:size) ?? .systemFont(ofSize:size,weight:.semibold)}
    static let taskTitleFont=NSFontManager.shared.font(withFamily:"Songti SC",traits:.boldFontMask,weight:6,size:15) ?? .systemFont(ofSize:15,weight:.semibold)
    static let bodyFont=NSFont(name:"PingFangSC-Regular",size:16) ?? .systemFont(ofSize:16)
    static let nameFont=NSFont.systemFont(ofSize:14,weight:.semibold)
    static let auxiliaryFont=NSFont.systemFont(ofSize:12)
    static var reducesMotion:Bool {NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    static let speakerHex:[UInt32]=[0x3F5F8A,0x3E7A64,0x9A6229,0x6E5A8C,0x9C4A5F]
    // Lift each dark avatar only as far as white text's 4.5:1 limit permits.
    static let darkSpeakerHex:[UInt32]=[0x496C99,0x407E68,0xA16A30,0x7B6599,0xAA536A]
    static let speakerPalette=zip(speakerHex,darkSpeakerHex).map{color($0.0,$0.1)}
    static func speakerColor(_ token:String?)->NSColor {
        guard let token,!token.isEmpty else{return faint}
        var hash:UInt64=1469598103934665603
        for byte in token.utf8 {hash=(hash^UInt64(byte))&*1099511628211}
        return speakerPalette[Int(hash%UInt64(speakerPalette.count))]
    }
    static func speakerInitial(_ name:String)->String {
        let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.hasPrefix("发言人"),let digit=trimmed.last(where:{$0.isNumber}) {return String(digit)}
        guard let first=trimmed.first else{return "?"}
        return String(first).uppercased()
    }
    /// Drawn at display time so the circle follows light/dark appearance.
    static func speakerAvatar(_ initial:String,color:NSColor,diameter:CGFloat=22,dashed:Bool?=nil)->NSImage {
        let outlined=dashed ?? (initial=="?")
        let image=NSImage(size:NSSize(width:diameter,height:diameter),flipped:false) {rect in
            if outlined {
                let outline=NSBezierPath(ovalIn:rect.insetBy(dx:1,dy:1));outline.lineWidth=1
                outline.setLineDash([2,2],count:2,phase:0);MeetingVisualStyle.muted.setStroke();outline.stroke()
            } else {color.setFill();NSBezierPath(ovalIn:rect).fill()}
            let font=NSFont.systemFont(ofSize:diameter*0.5,weight:.semibold)
            let text=initial as NSString,attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:outlined ? MeetingVisualStyle.muted:NSColor.white]
            let size=text.size(withAttributes:attributes)
            text.draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2+0.5),withAttributes:attributes)
            return true
        }
        image.isTemplate=false
        return image
    }
    private static func linear(_ component:Double)->Double {
        component<=0.04045 ? component/12.92:pow((component+0.055)/1.055,2.4)
    }
    private static func luminance(_ hex:UInt32)->Double {
        let red=Double((hex>>16)&0xff)/255,green=Double((hex>>8)&0xff)/255,blue=Double(hex&0xff)/255
        return 0.2126*linear(red)+0.7152*linear(green)+0.0722*linear(blue)
    }
    static func contrastRatio(foreground:UInt32,background:UInt32)->Double {
        let pair=[luminance(foreground),luminance(background)].sorted()
        return (pair[1]+0.05)/(pair[0]+0.05)
    }
    static let whiteOnLightAccentContrast=contrastRatio(foreground:0xFFFFFF,background:0xC73532)
    static let whiteOnDarkAccentContrast=contrastRatio(foreground:0xFFFFFF,background:0xCA3935)
    static let whiteTextContrastByState:[String:Double]=[
        "light.normal":whiteOnLightAccentContrast,
        "light.hover":contrastRatio(foreground:0xFFFFFF,background:0xB72E2B),
        "light.pressed":contrastRatio(foreground:0xFFFFFF,background:0xA32826),
        "light.disabled":contrastRatio(foreground:0xFFFFFF,background:0x565963),
        "dark.normal":whiteOnDarkAccentContrast,
        "dark.hover":contrastRatio(foreground:0xFFFFFF,background:0xB82F2B),
        "dark.pressed":contrastRatio(foreground:0xFFFFFF,background:0xA92B27),
        "dark.disabled":contrastRatio(foreground:0xFFFFFF,background:0x5B5E69)
    ]
}

enum MeetingVoiceGlyph {
    static func draw(in rect:NSRect,color:NSColor) {
        color.setFill()
        for (x,height) in [(0.07,0.52),(0.405,0.88),(0.74,0.52)] {
            let width=rect.width*0.19,h=rect.height*height
            let bar=NSRect(x:rect.minX+rect.width*x,y:rect.midY-h/2,width:width,height:h)
            NSBezierPath(roundedRect:bar,xRadius:width/2,yRadius:width/2).fill()
        }
    }
}

final class MeetingVoiceMark:NSView {
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(false)}
    required init?(coder:NSCoder) {super.init(coder:coder);setAccessibilityElement(false)}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        MeetingVoiceGlyph.draw(in:bounds.insetBy(dx:8,dy:6),color:MeetingVisualStyle.quietAccent)
    }
}

final class MeetingEmptyLabel:NSTextField {
    weak var voiceMark:NSView?
    override var isHidden:Bool {didSet {voiceMark?.isHidden=isHidden}}
}

func meetingVisualStyleContrastChecks()throws->Int {
    guard MeetingVisualStyle.whiteTextContrastByState.values.allSatisfy({$0>=4.5}) else {
        throw Failure(code:"meeting_visual_white_text_contrast")
    }
    let pairs=MeetingVisualStyle.speakerHex+MeetingVisualStyle.darkSpeakerHex
    guard pairs.allSatisfy({MeetingVisualStyle.contrastRatio(foreground:0xFFFFFF,background:$0)>=4.5}),
          MeetingVisualStyle.contrastRatio(foreground:0x6B6E76,background:0xF3F1EC)>=4.5,
          MeetingVisualStyle.contrastRatio(foreground:0xA7AAB3,background:0x232327)>=4.5 else {throw Failure(code:"meeting_visual_speaker_muted_contrast")}
    return MeetingVisualStyle.whiteTextContrastByState.count+pairs.count+2
}

/// A native button with a deliberate visual hierarchy and normal NSButton
/// action, key-equivalent, VoiceOver, and enabled-state behavior.
final class RecordingPrimaryButton:NSButton {
    var circularTransport=false
    var brandedRecordGlyph=true {didSet {needsDisplay=true}}
    var resumeStyle=false {didSet {if oldValue != resumeStyle {needsDisplay=true}}}
    private var hoverArea:NSTrackingArea?
    private var hovered=false
    private let cornerRadius:CGFloat=12

    override init(frame:NSRect) {
        super.init(frame:frame)
        configure()
    }
    required init?(coder:NSCoder) {
        super.init(coder:coder)
        configure()
    }
    private func configure() {
        setButtonType(.momentaryPushIn)
        isBordered=false
        bezelStyle = .regularSquare
        controlSize = .large
        imagePosition = .imageLeading
        font=NSFont.systemFont(ofSize:14,weight:.semibold)
        contentTintColor = .white
        wantsLayer=true
        layer?.masksToBounds=false
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? "录音" : title)
        setAccessibilityHelp("开始、暂停或继续当前会议录音")
        focusRingType = .none
    }
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func updateTrackingAreas() {
        if let area=hoverArea {removeTrackingArea(area)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);hoverArea=area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) {hovered=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent) {hovered=false;needsDisplay=true}
    override func mouseDown(with event:NSEvent) {needsDisplay=true;super.mouseDown(with:event);needsDisplay=true}
    override func mouseUp(with event:NSEvent) {super.mouseUp(with:event);needsDisplay=true}
    override func becomeFirstResponder()->Bool {let accepted=super.becomeFirstResponder();needsDisplay=true;return accepted}
    override func resignFirstResponder()->Bool {let resigned=super.resignFirstResponder();needsDisplay=true;return resigned}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}

    private var fillColor:NSColor {
        guard isEnabled else{return MeetingVisualStyle.disabledAccent}
        if isHighlighted {return MeetingVisualStyle.accentPressed}
        if hovered {return MeetingVisualStyle.accentHover}
        return MeetingVisualStyle.accent
    }
    private var isKeyboardFocused:Bool {window?.firstResponder === self}
    private func contentFont()->NSFont {font ?? NSFont.systemFont(ofSize:14,weight:.semibold)}
    private func drawTitleAttributes()->[NSAttributedString.Key:Any] {
        [.font:contentFont(),.foregroundColor:NSColor.white]
    }
    override func draw(_ dirtyRect:NSRect) {
        guard bounds.width>0,bounds.height>0 else{return}
        if circularTransport {
            // Sits on the charcoal capsule: vermilion while recording or ready,
            // paper-white once paused so the red retreats with the live state.
            let rect=bounds.insetBy(dx:1,dy:1)
            let fill:NSColor=resumeStyle && isEnabled ? (isHighlighted ? MeetingVisualStyle.capsulePaperPressed:MeetingVisualStyle.capsulePaper):fillColor
            fill.setFill();NSBezierPath(ovalIn:rect).fill()
            let glyphColor:NSColor=resumeStyle && isEnabled ? MeetingVisualStyle.capsuleInk:.white
            if brandedRecordGlyph {MeetingVoiceGlyph.draw(in:NSRect(x:bounds.midX-10,y:bounds.midY-10,width:20,height:20),color:glyphColor)}
            else if let image=image {
                let icon=image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:15,weight:.bold).applying(NSImage.SymbolConfiguration(paletteColors:[glyphColor]))) ?? image
                icon.draw(in:NSRect(x:bounds.midX-8+(resumeStyle ? 1:0),y:bounds.midY-8,width:16,height:16))
            }
            if isKeyboardFocused {let focus=NSBezierPath(ovalIn:bounds.insetBy(dx:0.5,dy:0.5));focus.lineWidth=2;MeetingVisualStyle.keyboardFocus.setStroke();focus.stroke()}
            return
        }
        setAccessibilityLabel(title.isEmpty ? "录音" : title)
        let rect=bounds.insetBy(dx:0.5,dy:0.5)
        let path=NSBezierPath(roundedRect:rect,xRadius:cornerRadius,yRadius:cornerRadius)
        fillColor.setFill();path.fill()
        if isEnabled {
            // A small inset edge echoes the icon's physical finish; no glow,
            // moving gradient or extra layer is added to the reading surface.
            let edge=NSBezierPath();edge.lineWidth=0.75
            let y=isFlipped ? rect.minY+1.2:rect.maxY-1.2
            edge.move(to:NSPoint(x:rect.minX+cornerRadius,y:y));edge.line(to:NSPoint(x:rect.maxX-cornerRadius,y:y))
            NSColor.white.withAlphaComponent(0.20).setStroke();edge.stroke()
        }

        let titleText=title
        let titleAttributes=drawTitleAttributes()
        let titleSize=(titleText as NSString).size(withAttributes:titleAttributes)
        let icon=image
        let iconSize:CGFloat=icon == nil ? 0:18
        let spacing:CGFloat=icon == nil || titleText.isEmpty ? 0:8
        let maxTitleWidth=max(0,bounds.width-24-iconSize-spacing)
        let visibleTitleWidth=min(titleSize.width,maxTitleWidth)
        let totalWidth=visibleTitleWidth+iconSize+spacing
        var x=max(10,(bounds.width-totalWidth)/2)
        let centerY=bounds.midY
        if let icon=icon {
            let iconRect=NSRect(x:x,y:centerY-iconSize/2,width:iconSize,height:iconSize)
            if brandedRecordGlyph {MeetingVoiceGlyph.draw(in:iconRect,color:.white)}
            else {
                NSColor.white.set()
                let configured=icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[NSColor.white])) ?? icon
                configured.draw(in:iconRect)
            }
            x+=iconSize+spacing
        }
        if !titleText.isEmpty {
            var attributes=titleAttributes
            let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle]=paragraph
            let titleRect=NSRect(x:x,y:centerY-titleSize.height/2,width:visibleTitleWidth,height:titleSize.height+2)
            (titleText as NSString).draw(in:titleRect,withAttributes:attributes)
        }
        if isKeyboardFocused {
            let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:2.5,dy:2.5),xRadius:cornerRadius-2,yRadius:cornerRadius-2)
            focus.lineWidth=2;MeetingVisualStyle.keyboardFocus.setStroke();focus.stroke()
        } else if !isEnabled {
            let outline=NSBezierPath(roundedRect:rect,xRadius:cornerRadius,yRadius:cornerRadius)
            outline.lineWidth=1;MeetingVisualStyle.border.setStroke();outline.stroke()
        }
    }
}

/// Replaces the default saturated table selection strip with a quiet inset row.
final class MeetingListRow:NSTableRowView {
    var sectionInset:CGFloat=0
    override func drawBackground(in dirtyRect:NSRect) {
        // Keep the list surface visible through unselected rows.
    }
    override func drawSelection(in dirtyRect:NSRect) {
        guard isSelected else{return}
        let rect=NSRect(x:bounds.minX+2,y:bounds.minY+3+sectionInset,width:bounds.width-4,height:bounds.height-6-sectionInset)
        MeetingVisualStyle.selection.setFill()
        NSBezierPath(roundedRect:rect,xRadius:9,yRadius:9).fill()

    }
    override func drawSeparator(in dirtyRect:NSRect) {
        let line=NSBezierPath();line.lineWidth=0.5
        line.move(to:NSPoint(x:bounds.minX+10,y:bounds.minY+0.25))
        line.line(to:NSPoint(x:bounds.maxX-10,y:bounds.minY+0.25))
        MeetingVisualStyle.border.setStroke();line.stroke()
    }
}
