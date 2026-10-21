import Foundation

/// Small event gate for the UI lifecycle. It deliberately knows nothing about
/// audio, files, or models, so pause/end ordering can be checked synthetically.
struct MeetingSpeakerRefinementLifecycle {
    private(set) var session:String?
    private(set) var lastPauseRevision:Int?

    mutating func begin(session:String?) {
        self.session=session
        lastPauseRevision=nil
    }

    mutating func resumed(session:String?) -> Bool {
        guard let session,session==self.session else{return false}
        lastPauseRevision=nil
        return true
    }

    mutating func pauseTailCompleted(session:String?,revision:Int?,states:[String:String],localOnly:Bool)->Bool {
        guard !localOnly,let session,session==self.session,let revision,
              !states.isEmpty,states.values.allSatisfy({$0=="complete"}),
              lastPauseRevision != revision else{return false}
        lastPauseRevision=revision
        return true
    }

    func shouldRefineStopped(session:String?,reason:String,transcriptionComplete:Bool,
                             localOnly:Bool,recoverySucceeded:Bool)->Bool {
        guard !localOnly,let session,session==self.session,transcriptionComplete else{return false}
        return recoverySucceeded || ["user_stop","user_finish","local_duration_limit","cloud_duration_limit","input_device_changed"].contains(reason)
    }

    func acceptsResult(session:String?,cacheID:String?,expectedSession:String,expectedCacheID:String,
                       phase:RecordingPhase,currentRevision:Int,expectedRevision:Int)->Bool {
        guard session==expectedSession,cacheID==expectedCacheID,currentRevision==expectedRevision,
              phase == .paused || phase == .stopped || phase == .failed else{return false}
        return true
    }
}
