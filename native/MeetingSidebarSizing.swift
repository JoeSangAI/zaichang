import AppKit

enum MeetingSidebarSizing {
    static let preferenceKey="MeetingSidebarWidth"
    static let defaultWidth:CGFloat=200
    static let minimum:CGFloat=200
    static let maximum:CGFloat=360
    static func preferred(_ width:CGFloat)->CGFloat {width.isFinite ? min(maximum,max(minimum,width)):defaultWidth}
    static func effective(_ width:CGFloat,window:CGFloat)->CGFloat {
        let available=window.isFinite ? window:0
        return min(preferred(width),max(minimum,available-(available>=800 ? 540:460)))
    }
}

final class MeetingSidebarDivider:NSView {
    var widthProvider:(()->CGFloat)?
    var changeWidth:((CGFloat,Bool)->Void)?
    private var initialX:CGFloat=0
    private var initialWidth:CGFloat=MeetingSidebarSizing.defaultWidth
    private var dragging=false
    private var hovered=false
    private var hoverTracking:NSTrackingArea?
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override init(frame:NSRect){super.init(frame:frame);configure()}
    required init?(coder:NSCoder){super.init(coder:coder);configure()}
    private func configure(){setAccessibilityElement(true);setAccessibilityRole(.splitter);setAccessibilityLabel("调整会议列表宽度");toolTip="拖动调整会议列表宽度；方向键微调，双击恢复默认"}
    override func accessibilityValue()->Any? {NSNumber(value:Double(widthProvider?() ?? MeetingSidebarSizing.defaultWidth))}
    override func accessibilityPerformIncrement()->Bool {adjust(by:12);return true}
    override func accessibilityPerformDecrement()->Bool {adjust(by:-12);return true}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.resizeLeftRight)}
    override func updateTrackingAreas(){
        if let tracking=hoverTracking {removeTrackingArea(tracking)}
        let tracking=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking);hoverTracking=tracking;super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
    override func becomeFirstResponder()->Bool {needsDisplay=true;return true}
    override func resignFirstResponder()->Bool {needsDisplay=true;return true}
    override func draw(_ dirtyRect:NSRect){
        // The sidebar already owns the hairline. Highlight only its drag target.
        guard hovered || dragging || window?.firstResponder === self else{return}
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect:NSRect(x:bounds.midX-1,y:bounds.minY,width:2,height:bounds.height)).fill()
    }
    override func mouseDown(with event:NSEvent){
        window?.makeFirstResponder(self)
        if event.clickCount==2 {dragging=false;changeWidth?(MeetingSidebarSizing.defaultWidth,true);return}
        initialX=event.locationInWindow.x;initialWidth=widthProvider?() ?? MeetingSidebarSizing.defaultWidth;dragging=true;needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){guard dragging else{return};changeWidth?(initialWidth+event.locationInWindow.x-initialX,false)}
    override func mouseUp(with event:NSEvent){guard dragging else{return};dragging=false;changeWidth?(initialWidth+event.locationInWindow.x-initialX,true);needsDisplay=true}
    private func adjust(by amount:CGFloat){changeWidth?((widthProvider?() ?? MeetingSidebarSizing.defaultWidth)+amount,true)}
    override func keyDown(with event:NSEvent){if [123,124].contains(event.keyCode){adjust(by:event.keyCode==123 ? -12:12)}else{super.keyDown(with:event)}}
}

extension Delegate {
    var sidebarPreferences:UserDefaults? {sidebarPreferencesOverride ?? (Credential.offline || mock || previewRenderOnly ? nil:UserDefaults.standard)}
    func restoreSidebarWidth(){
        preferredSidebarWidth=MeetingSidebarSizing.defaultWidth
        guard let value=sidebarPreferences?.object(forKey:MeetingSidebarSizing.preferenceKey) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else{return}
        preferredSidebarWidth=MeetingSidebarSizing.preferred(CGFloat(value.doubleValue))
    }
    func resizeSidebar(to width:CGFloat,persist:Bool=true){
        preferredSidebarWidth=MeetingSidebarSizing.preferred(width)
        if persist {sidebarPreferences?.set(Double(preferredSidebarWidth),forKey:MeetingSidebarSizing.preferenceKey)}
        layoutWorkspace()
    }
}
