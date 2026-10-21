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
    static let surface=color(0xFBFAF8,0x1D1D20)
    static let sidebar=color(0xF3F1ED,0x232327)
    static let ink=color(0x23252B,0xECEDEF)
    static let muted=color(0x676B75,0xA7AAB3)
    static let selection=color(0xE9E6E1,0x2E2E33)
    static let accent=color(0xC73532,0xCA3935)
    static let accentHover=color(0xB72E2B,0xB82F2B)
    static let accentPressed=color(0xA32826,0xA92B27)
    static let quietAccent=color(0xAB615E,0xC27874)
    static let border=color(0xE6E3DE,0x313136)
    static let faint=color(0xA2A4AA,0x6C6D74)
    static let quietFill=color(0xF1EFEB,0x2A2A2F)
    static let disabledAccent=color(0x565963,0x5B5E69)
    static let keyboardFocus=NSColor.keyboardFocusIndicatorColor

    // One stable colour per speaker identity; unknown speakers stay neutral.
    static let speakerPalette:[NSColor]=[color(0x3B6FD9,0x6E95E8),color(0x2E9D74,0x4DBB91),color(0xC9822B,0xE0A15A),
                                         color(0x8C5BD0,0xA88AE0),color(0xC2507A,0xDB7C9D),color(0x2F8FA8,0x5BB2C8),
                                         color(0x7A8B2E,0x9DB04F),color(0xB0613A,0xCF8762)]
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
    static func speakerAvatar(_ initial:String,color:NSColor,diameter:CGFloat=22)->NSImage {
        let image=NSImage(size:NSSize(width:diameter,height:diameter),flipped:false) {rect in
            color.setFill();NSBezierPath(ovalIn:rect).fill()
            let font=NSFont.systemFont(ofSize:diameter*0.5,weight:.semibold)
            let text=initial as NSString,attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor.white]
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
    return MeetingVisualStyle.whiteTextContrastByState.count
}

/// A native button with a deliberate visual hierarchy and normal NSButton
/// action, key-equivalent, VoiceOver, and enabled-state behavior.
final class RecordingPrimaryButton:NSButton {
    var circularTransport=false
    var brandedRecordGlyph=true {didSet {needsDisplay=true}}
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
            let rect=bounds.insetBy(dx:2,dy:2)
            let rim=NSBezierPath(ovalIn:rect);rim.lineWidth=1.2;NSColor.tertiaryLabelColor.setStroke();rim.stroke()
            fillColor.setFill();NSBezierPath(ovalIn:rect.insetBy(dx:4,dy:4)).fill()
            if !brandedRecordGlyph,let image=image {
                let icon=image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:14,weight:.semibold).applying(NSImage.SymbolConfiguration(paletteColors:[NSColor.white]))) ?? image
                icon.draw(in:NSRect(x:bounds.midX-8,y:bounds.midY-8,width:16,height:16))
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
    override func drawBackground(in dirtyRect:NSRect) {
        // Keep the list surface visible through unselected rows.
    }
    override func drawSelection(in dirtyRect:NSRect) {
        guard isSelected else{return}
        let rect=bounds.insetBy(dx:2,dy:3)
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
