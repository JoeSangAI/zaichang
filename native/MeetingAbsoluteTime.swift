import Foundation

// Recording offsets omit pauses; these measured anchors restore actual capture
// time without using cache creation, ASR arrival, or transcript processing time.
struct MeetingAbsoluteTime {
    let anchors:[(relative:Double,unix:Double)]
    let zone:TimeZone
    private let displayFormatter:DateFormatter
    private let isoFormatter:DateFormatter
    init?(_ object:Any?) {
        guard let value=object as? [String:Any],value["schema"] as? Int==1,
              value["basis"] as? String=="capture_clock",
              let zoneID=value["time_zone"] as? String,let zone=TimeZone(identifier:zoneID),
              let rows=value["anchors"] as? [[String:Any]],!rows.isEmpty,rows.count<=10000 else{return nil}
        var anchors:[(relative:Double,unix:Double)]=[]
        for row in rows {
            guard let relative=row["relative_start"] as? Double,let unix=row["unix_time"] as? Double,
                  relative.isFinite,relative>=0,relative<=86400,unix.isFinite,unix>0,
                  anchors.last.map({relative >= $0.relative}) ?? true else{return nil}
            anchors.append((relative,unix))
        }
        self.anchors=anchors;self.zone=zone
        let display=DateFormatter();display.locale=Locale(identifier:"en_US_POSIX");display.timeZone=zone;display.dateFormat="HH:mm:ss";displayFormatter=display
        let iso=DateFormatter();iso.locale=Locale(identifier:"en_US_POSIX");iso.timeZone=zone;iso.dateFormat="yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX";isoFormatter=iso
    }
    func date(_ offset:Double,endBoundary:Bool=false)->Date? {
        guard offset.isFinite,offset>=0 else{return nil}
        var lo=0,hi=anchors.count
        while lo<hi {let mid=(lo+hi)/2
            let included=endBoundary && offset>0 ? anchors[mid].relative<offset-1e-7 : anchors[mid].relative<=offset+1e-7
            if included {lo=mid+1}else{hi=mid}
        }
        guard lo>0 else{return nil}
        let anchor=anchors[lo-1]
        return Date(timeIntervalSince1970:anchor.unix+offset-anchor.relative)
    }
    func display(_ offset:Double)->String? {
        guard let date=date(offset) else{return nil}
        return displayFormatter.string(from:date)
    }
    func iso(_ offset:Double,endBoundary:Bool=false)->String? {
        guard let date=date(offset,endBoundary:endBoundary) else{return nil}
        return isoFormatter.string(from:date)
    }
}

func meetingAbsoluteTimeChecks() throws->Int {
    var checks=0
    func check(_ ok:Bool)throws {guard ok else{throw Failure(code:"absolute_time_check_\(checks)")};checks+=1}
    let clock=CaptureBudgetClock(wallTime:{1791215990},uptime:{100},zone:TimeZone(identifier:"Asia/Shanghai")!)
    try check(MeetingAbsoluteTime(clock.absoluteClock())==nil)
    clock.mark(100)
    let first=MeetingAbsoluteTime(clock.absoluteClock())!
    try check(first.iso(15)=="2026-10-06T00:00:05.000+08:00")
    clock.pause(at:110);clock.resume(at:710)
    let resumed=MeetingAbsoluteTime(clock.absoluteClock())!
    try check(resumed.date(11)!.timeIntervalSince1970-first.date(11)!.timeIntervalSince1970==600)
    try check(resumed.date(10,endBoundary:true)==first.date(10))
    try check(resumed.date(10)!.timeIntervalSince1970-first.date(10)!.timeIntervalSince1970==600)
    clock.pause(at:715);clock.resume(at:735)
    let twice=MeetingAbsoluteTime(clock.absoluteClock())!
    try check(twice.date(20)!.timeIntervalSince1970-first.date(20)!.timeIntervalSince1970==620)
    try check(twice.date(5)==first.date(5)) // Delayed ASR retains its original time.
    let restored=MeetingAbsoluteTime(try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:clock.absoluteClock())))!
    try check(restored.iso(20)==twice.iso(20))
    try check(MeetingAbsoluteTime(["created_at":1791215990])==nil)
    try check(twice.date(-1)==nil && twice.date(.infinity)==nil)
    let delayed=MeetingAbsoluteTime(["schema":1,"basis":"capture_clock","time_zone":"Asia/Shanghai",
        "anchors":[["relative_start":42.0,"unix_time":1791215990.0]]])!
    try check(delayed.iso(0)==nil && delayed.iso(41.9)==nil && delayed.iso(42) != nil)
    return checks
}
