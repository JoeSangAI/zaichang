import Foundation
import SQLite3

// A rebuildable read projection. The recording owner never waits for SQLite,
// an Agent, a network request, or a reader. No inference occurs here.
final class MeetingContextStore {
    let file:URL
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(directory:URL)throws {
        let fm=FileManager.default
        if fm.fileExists(atPath:directory.path) {
            let attrs=try fm.attributesOfItem(atPath:directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else{throw Failure(code:"context_directory_invalid")}
        } else {try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        file=directory.appendingPathComponent("context.sqlite")
        for path in [file.path,file.path+"-wal",file.path+"-shm"] where fm.fileExists(atPath:path) {
            guard (try fm.attributesOfItem(atPath:path))[.type] as? FileAttributeType == .typeRegular else{throw Failure(code:"context_file_invalid")}
        }
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK else{throw Failure(code:"context_open_failed")}
        sqlite3_busy_timeout(db,100)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        var version:OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&version,nil)==SQLITE_OK,
              sqlite3_step(version)==SQLITE_ROW else{sqlite3_finalize(version);throw Failure(code:"context_schema_read")}
        let schema=sqlite3_column_int(version,0);sqlite3_finalize(version)
        guard (0...2).contains(schema) else{throw Failure(code:"unsupported_database_schema")}
        try execute("BEGIN IMMEDIATE")
        do {
        try execute("CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS meetings(session TEXT PRIMARY KEY,metadata TEXT NOT NULL,revision INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS deleted_meetings(session TEXT PRIMARY KEY)")
        try execute("CREATE TABLE IF NOT EXISTS segments(session TEXT NOT NULL,parent TEXT NOT NULL,revision INTEGER NOT NULL,start REAL NOT NULL,end REAL,payload TEXT NOT NULL,updated_revision INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(session,parent))")
        try execute("CREATE INDEX IF NOT EXISTS context_time ON segments(session,start,parent)")
        try execute("CREATE INDEX IF NOT EXISTS context_changes ON segments(session,updated_revision)")
        try execute("CREATE TABLE IF NOT EXISTS notes(session TEXT NOT NULL,id TEXT NOT NULL,rev INTEGER NOT NULL,anchor_relative REAL,state TEXT NOT NULL,text TEXT NOT NULL,starred INTEGER NOT NULL,archive INTEGER NOT NULL,images TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(session,id))")
        try execute("PRAGMA user_version=2")
        try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
        for path in [file.path,file.path+"-wal",file.path+"-shm"] where fm.fileExists(atPath:path) {try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)}
    }
    deinit {sqlite3_close(db)}
    private func execute(_ sql:String,_ values:[Any]=[])throws {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else{throw Failure(code:"context_prepare_failed")}
        defer {sqlite3_finalize(statement)}
        for (index,value) in values.enumerated() {
            let slot=Int32(index+1)
            if value is NSNull {sqlite3_bind_null(statement,slot)}
            else if let text=value as? String {sqlite3_bind_text(statement,slot,text,-1,transient)}
            else if let integer=value as? Int {sqlite3_bind_int64(statement,slot,Int64(integer))}
            else if let number=value as? Double {sqlite3_bind_double(statement,slot,number)}
            else {throw Failure(code:"context_bind_invalid")}
        }
        let status=sqlite3_step(statement)
        guard status==SQLITE_DONE || status==SQLITE_ROW else{throw Failure(code:"context_write_failed")}
    }
    private func json(_ value:Any)throws->String {String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!}
    func revision(_ session:String)throws->Int {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT revision FROM meetings WHERE session=?",-1,&statement,nil)==SQLITE_OK else{throw Failure(code:"context_revision_failed")}
        defer {sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,session,-1,transient)
        return sqlite3_step(statement)==SQLITE_ROW ? Int(sqlite3_column_int64(statement,0)):0
    }
    /// Reconcile durable cache recovery into an already-published saved meeting.
    /// This metadata-only transaction never activates the meeting or touches turns.
    func reconcileRecordingRecovery(session:String,cacheID:String,transcriptionComplete:Bool,recovery:[String:Any])throws->Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            if try isDeleted(session) {try execute("COMMIT");return false}
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db,"SELECT metadata FROM meetings WHERE session=?",-1,&statement,nil)==SQLITE_OK else{throw Failure(code:"context_recovery_read_failed")}
            sqlite3_bind_text(statement,1,session,-1,transient)
            let status=sqlite3_step(statement)
            guard status==SQLITE_ROW,let text=sqlite3_column_text(statement,0) else {
                sqlite3_finalize(statement);try execute("COMMIT");return false
            }
            let original=String(cString:text)
            guard var value=(try? JSONSerialization.jsonObject(with:Data(original.utf8))) as? [String:Any],value["session"] as? String==session else {
                sqlite3_finalize(statement);try execute("COMMIT");return false
            }
            sqlite3_finalize(statement)
            let phase=value["phase"] as? String ?? ""
            guard !["connecting","recording","paused","stopping"].contains(phase),value["projection_updating"] as? Bool != true,
                  (value["cache_id"] as? String == nil || value["cache_id"] as? String == cacheID) else {try execute("COMMIT");return false}
            value["cache_id"]=cacheID
            value["transcription_complete"]=transcriptionComplete
            value["recording_recovery"]=recovery
            let newValue=try json(value)
            guard newValue != original else{try execute("COMMIT");return false}
            try execute("UPDATE meetings SET metadata=?,revision=revision+1 WHERE session=?",[newValue,session])
            try execute("COMMIT");return true
        } catch {try? execute("ROLLBACK");throw error}
    }
    // Metadata and changed original parents share one committed revision.
    func write(metadata:[String:Any],parents:[String:[[String:Any]]],notes:[String:[String:Any]]=[:],current:[String:Any]?)throws {
        guard let session=metadata["session"] as? String,!session.isEmpty else{throw Failure(code:"context_session_missing")}
        try execute("BEGIN IMMEDIATE")
        do {
            if try isDeleted(session) {try execute("COMMIT");return}
            let revision=try self.revision(session)+1
            try execute("INSERT INTO meetings VALUES(?,?,?) ON CONFLICT(session) DO UPDATE SET metadata=excluded.metadata,revision=excluded.revision",[session,try json(metadata),revision])
            for (parent,rows) in parents {
                let start=rows.compactMap{$0["start"] as? Double}.min() ?? 0
                let end=rows.compactMap{$0["end"] as? Double}.max()
                try execute("INSERT INTO segments VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(session,parent) DO UPDATE SET revision=excluded.revision,start=excluded.start,end=excluded.end,payload=excluded.payload,updated_revision=excluded.updated_revision,deleted=excluded.deleted WHERE segments.payload<>excluded.payload OR segments.deleted<>excluded.deleted",[session,parent,revision,start,end as Any? ?? NSNull(),try json(rows),revision,rows.isEmpty ? 1:0])
            }
            for (id,note) in notes {
                try execute("INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session,id) DO UPDATE SET rev=excluded.rev,anchor_relative=excluded.anchor_relative,state=excluded.state,text=excluded.text,starred=excluded.starred,archive=excluded.archive,images=excluded.images,deleted=excluded.deleted",[session,id,note["rev"]!,note["anchor_relative"]!,note["state"]!,note["text"]!,note["starred"]!,note["archive"]!,try json(note["images"]!),note["deleted"]!])
            }
            if let current {try execute("INSERT INTO state VALUES('current',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[try json(current)])}
            try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
    }
    func heartbeat(_ state:[String:Any])throws {var state=state;if let session=state["session"] as? String,try isDeleted(session){state["session"]=NSNull();state["phase"]="idle"};try execute("INSERT INTO state VALUES('current',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[try json(state)])}
    private func isDeleted(_ session:String)throws->Bool {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT 1 FROM deleted_meetings WHERE session=?",-1,&statement,nil)==SQLITE_OK else{throw Failure(code:"context_delete_check")};defer{sqlite3_finalize(statement)};sqlite3_bind_text(statement,1,session,-1,transient);return sqlite3_step(statement)==SQLITE_ROW
    }
    func deleteSession(_ session:String)throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT OR IGNORE INTO deleted_meetings VALUES(?)",[session])
            try execute("DELETE FROM segments WHERE session=?",[session]);try execute("DELETE FROM notes WHERE session=?",[session]);try execute("DELETE FROM meetings WHERE session=?",[session])
            try execute("DELETE FROM state WHERE key='current' AND json_extract(value,'$.session')=?",[session]);try execute("COMMIT")
        }catch{try? execute("ROLLBACK");throw error}
    }
    func restoreSession(_ session:String)throws {try execute("DELETE FROM deleted_meetings WHERE session=?",[session])}
}

final class MeetingContextPublisher {
    private let queue=DispatchQueue(label:"meeting.agent-context",qos:.utility)
    private let lock=NSLock()
    private var pending:[String:[String:[[String:Any]]]]=[:]
    private var pendingNotes:[String:[String:[String:Any]]]=[:]
    private var noteSources:[String:URL]=[:]
    // Only successfully committed notes are acknowledged here. Source I/O and
    // these signatures stay on the publisher queue, outside the mailbox lock.
    private var noteFingerprints:[String:String]=[:]
    private var noteReadFailures=Set<String>() // Accessed only on the publisher queue.
    private var noteValues:[String:[String:Data]]=[:]
    private var metadata:[String:[String:Any]]=[:]
    private var dirtyMetadata=Set<String>()
    private var deletedSessions=Set<String>()
    private struct RecoveryUpdate {let session:String;let cacheID:String;let complete:Bool;let metadata:[String:Any]}
    private var recoveryUpdates:[String:RecoveryUpdate]=[:]
    private var current:[String:Any]
    private var scheduled=false
    private var store:MeetingContextStore?
    private var timer:DispatchSourceTimer?
    private let directory:URL
    var databaseURL:URL {directory.appendingPathComponent("context.sqlite")}
    let writerID=UUID().uuidString
    private(set) var lastError:String?
    init(directory:URL) {
        self.directory=directory
        current=["schema":1,"session":NSNull(),"pid":Int(getpid()),"writer_id":writerID,"heartbeat":Date().timeIntervalSince1970,"phase":"idle"]
        queue.async{[weak self] in guard let self else{return};self.open();self.drain();let timer=DispatchSource.makeTimerSource(queue:self.queue);timer.schedule(deadline:.now()+2,repeating:2);timer.setEventHandler{[weak self] in self?.drain()};self.timer=timer;timer.resume()}
    }
    deinit {timer?.cancel()}
    private func open() {do {store=try MeetingContextStore(directory:directory);lastError=nil}catch{lastError="context_unavailable"}}
    func activate(_ value:[String:Any]) {update(value,activate:true)}
    func update(_ value:[String:Any],activate:Bool=false) {
        guard let session=value["session"] as? String else{return}
        lock.lock();guard !deletedSessions.contains(session) else{lock.unlock();return};var value=value;value["writer_id"]=writerID;value["updated_at"]=Date().timeIntervalSince1970
        metadata[session]=value;dirtyMetadata.insert(session)
        if activate {current["session"]=session}
        if current["session"] as? String==session {current["phase"]=value["phase"] ?? "idle"}
        scheduleLocked();lock.unlock()
    }
    func clearCurrent() {lock.lock();current["session"]=NSNull();current["phase"]="idle";scheduleLocked();lock.unlock()}
    func updateTitle(session:String,title:String) {
        lock.lock();defer{lock.unlock()}
        guard !deletedSessions.contains(session),var info=metadata[session] else{return}
        info["title"]=title;info["updated_at"]=Date().timeIntervalSince1970
        metadata[session]=info;dirtyMetadata.insert(session);scheduleLocked()
    }
    func replace(session:String,parent:String,rows:[[String:Any]]) {
        lock.lock();guard !deletedSessions.contains(session) else{lock.unlock();return};pending[session,default:[:]][parent]=rows;scheduleLocked();lock.unlock()
    }
    func trackNotes(session:String,directory:URL) {
        lock.lock();defer{lock.unlock()}
        guard !deletedSessions.contains(session),noteSources[session] != directory else{return}
        noteSources[session]=directory;scheduleLocked()
    }
    private func collectNotes()->[String:String] {
        lock.lock();let sources=noteSources;lock.unlock()
        var observed:[String:String]=[:]
        for (session,directory) in sources {
            do {
                let source=MeetingNotesStore(directory:directory)
                func safe(_ file:URL)throws {try source.safe(file)}
                let log=source.notes.appendingPathComponent("notes.jsonl"),ocr=source.notes.appendingPathComponent("ocr")
                try safe(log);try safe(ocr)
                let fingerprint=[log,ocr].map { file -> String in
                    let attrs=try? FileManager.default.attributesOfItem(atPath:file.path)
                    return "\(attrs?[.modificationDate] as? Date ?? .distantPast)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs?[.size] ?? 0)|\(attrs?[.systemFileNumber] ?? 0)"
                }.joined(separator:";")
                if noteFingerprints[session]==fingerprint {noteReadFailures.remove(session);continue}
                let snapshot=try MeetingNotesStore.queue.sync {try source.snapshot()}
                var changed:[String:[String:Any]]=[:]
                for note in snapshot.latest {
                    var images:[[String:Any]]=[]
                    for image in note.images {
                        guard image.sha256.count==64,image.sha256.allSatisfy({$0.isHexDigit}),
                              ["assets/\(image.sha256).png","assets/\(image.sha256).jpg"].contains(image.file) else{throw Failure(code:"context_notes_image_path")}
                        try safe(source.notes.appendingPathComponent(image.file))
                        let file=ocr.appendingPathComponent(image.sha256+".json");try safe(file)
                        var text=""
                        if FileManager.default.fileExists(atPath:file.path) {
                            let value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]
                            if value?["sha256"] as? String==image.sha256 {text=value?["text"] as? String ?? ""}
                        }
                        images.append(["sha256":image.sha256,"cache_path":"notes/"+image.file,"ocr_text":text])
                    }
                    let value:[String:Any]=["rev":note.rev,"anchor_relative":note.anchor?.relative as Any? ?? NSNull(),"state":note.anchor?.state ?? "after","text":note.text,"starred":note.starred ? 1:0,"archive":note.archive ? 1:0,"images":images,"deleted":note.op=="delete" ? 1:0]
                    let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
                    if noteValues[session]?[note.note_id] != data {changed[note.note_id]=value}
                }
                lock.lock()
                if !deletedSessions.contains(session) {
                    // Rebuild the unpublished set from the durable source, rather
                    // than merging a failed batch that may contain older revisions.
                    if changed.isEmpty {pendingNotes.removeValue(forKey:session)}
                    else {pendingNotes[session]=changed}
                }
                lock.unlock()
                noteReadFailures.remove(session)
                observed[session]=fingerprint
                // A touch with no content change needs no new SQLite transaction:
                // every source value already matches a successful commit.
                if changed.isEmpty {noteFingerprints[session]=fingerprint}
            } catch {
                // A damaged note/OCR artifact in one saved meeting must not
                // stop new speech, other meetings, or the current heartbeat.
                // Do not acknowledge its fingerprint or publish an older queued
                // note revision: re-read the durable source after recovery.
                noteReadFailures.insert(session)
                noteFingerprints.removeValue(forKey:session)
                lock.lock();pendingNotes.removeValue(forKey:session);lock.unlock()
            }
        }
        return observed
    }
    func finishProjection(session:String) {
        lock.lock();defer{lock.unlock()}
        guard !deletedSessions.contains(session),var info=metadata[session] else{return}
        info["projection_updating"]=false;info["updated_at"]=Date().timeIntervalSince1970
        metadata[session]=info;dirtyMetadata.insert(session);scheduleLocked()
    }
    func reconcileRecordingRecovery(session:String,cacheID:String,transcriptionComplete:Bool,metadata:[String:Any]) {
        guard UUID(uuidString:cacheID) != nil,metadata["kind"] as? String=="interrupted_capture",
              ["recovered_unclean_shutdown","source_error"].contains(metadata["state"] as? String ?? "") else{return}
        lock.lock();guard !deletedSessions.contains(session) else{lock.unlock();return}
        recoveryUpdates[session]=RecoveryUpdate(session:session,cacheID:cacheID,complete:transcriptionComplete,metadata:metadata)
        scheduleLocked();lock.unlock()
    }
    private func scheduleLocked() {if !scheduled {scheduled=true;queue.asyncAfter(deadline:.now()+0.08){[weak self] in self?.drain()}}}
    private func drain() {
        if store==nil {open()}
        guard let store else{return} // Reader sees no data/stale heartbeat, never a false live claim.
        let observed=collectNotes()
        lock.lock()
        scheduled=false
        let dirty=dirtyMetadata.union(pending.keys).union(pendingNotes.keys)
        var jobs:[(String,[String:Any],[String:[[String:Any]]],[String:[String:Any]])]=[]
        let recoveryJobs=Array(recoveryUpdates.values)
        recoveryUpdates.removeAll()
        for session in dirty {
            guard var info=metadata[session] else{continue}
            var rows:[String:[[String:Any]]]=[:]
            for parent in pending[session]?.keys.prefix(128) ?? Dictionary<String,[[String:Any]]>().keys.prefix(0) {rows[parent]=pending[session]?[parent]}
            for parent in rows.keys {pending[session]?.removeValue(forKey:parent)}
            if pending[session]?.isEmpty==true {pending.removeValue(forKey:session)}
            var notes:[String:[String:Any]]=[:]
            for id in pendingNotes[session]?.keys.prefix(128) ?? Dictionary<String,[String:Any]>().keys.prefix(0) {notes[id]=pendingNotes[session]?[id]}
            for id in notes.keys {pendingNotes[session]?.removeValue(forKey:id)}
            if pendingNotes[session]?.isEmpty==true {pendingNotes.removeValue(forKey:session)}
            if pending[session] != nil || pendingNotes[session] != nil {info["projection_updating"]=true}
            dirtyMetadata.remove(session);jobs.append((session,info,rows,notes))
        }
        var state=current;state["heartbeat"]=Date().timeIntervalSince1970
        if (!pending.isEmpty || !pendingNotes.isEmpty || !recoveryUpdates.isEmpty) && !scheduled {scheduled=true;queue.async{[weak self] in self?.drain()}}
        lock.unlock()
        var committedSessions=Set<String>()
        do {
            for (session,info,rows,notes) in jobs {
                // Encode before committing so no fallible work can separate the
                // successful SQLite transaction from its acknowledgement.
                let encoded=try notes.mapValues{try JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys])}
                try store.write(metadata:info,parents:rows,notes:notes,current:state["session"] as? String==session ? state:nil)
                committedSessions.insert(session)
                for (id,value) in encoded {noteValues[session,default:[:]][id]=value}
                lock.lock();let complete=pendingNotes[session]==nil;lock.unlock()
                if complete,let fingerprint=observed[session] {noteFingerprints[session]=fingerprint}
            }
            for update in recoveryJobs {_ = try store.reconcileRecordingRecovery(session:update.session,cacheID:update.cacheID,transcriptionComplete:update.complete,recovery:update.metadata)}
            try store.heartbeat(state);lastError=noteReadFailures.isEmpty ? nil:"context_notes_read_failed"
        } catch {
            lastError="context_write_failed"
            // Preserve undelivered latest values. Do not replace a newer queued correction.
            lock.lock();for (session,_,rows,notes) in jobs {
                dirtyMetadata.insert(session)
                for (parent,value) in rows where pending[session]?[parent]==nil {pending[session,default:[:]][parent]=value}
                if !committedSessions.contains(session) {
                    // Even if file attributes look unchanged, the next drain
                    // must resample notes.jsonl/OCR before retrying this session.
                    noteFingerprints.removeValue(forKey:session)
                    for (id,value) in notes where pendingNotes[session]?[id]==nil {pendingNotes[session,default:[:]][id]=value}
                }
            }
            for update in recoveryJobs where recoveryUpdates[update.session]==nil {recoveryUpdates[update.session]=update}
            if !scheduled {scheduled=true;queue.asyncAfter(deadline:.now()+1){[weak self] in self?.drain()}}
            lock.unlock()
        }
    }
    // Offline checks only. Production never waits on publication.
    func flushForChecks() {queue.sync{drain()}}
    /// Confirms all queued metadata and turn writes have reached the WAL. Runs
    /// on the publisher queue and reports failure without blocking AppKit.
    func flush(timeout:TimeInterval=10,completion:@escaping(Bool)->Void) {
        let completionLock=NSLock();var completed=false
        let finish:(Bool)->Void={success in
            completionLock.lock();guard !completed else{completionLock.unlock();return};completed=true;completionLock.unlock()
            completion(success)
        }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout){finish(false)}
        func drainUntilClear() {
            queue.async { [weak self] in
                guard let self else{finish(false);return}
                self.drain()
                self.lock.lock();let pending = !self.pending.isEmpty || !self.pendingNotes.isEmpty || !self.dirtyMetadata.isEmpty || !self.recoveryUpdates.isEmpty;self.lock.unlock()
                if self.lastError != nil {finish(false)}
                else if pending {drainUntilClear()}
                else {finish(true)}
            }
        }
        drainUntilClear()
    }
    // Called from the filesystem transaction's background queue, never AppKit.
    func deleteSession(_ session:String)throws {
        try queue.sync {
            if store==nil {open()};guard let store else{throw Failure(code:"context_delete_unavailable")}
            try store.deleteSession(session)
            lock.lock();deletedSessions.insert(session);metadata.removeValue(forKey:session);pending.removeValue(forKey:session);dirtyMetadata.remove(session)
            pendingNotes.removeValue(forKey:session);noteSources.removeValue(forKey:session)
            noteFingerprints.removeValue(forKey:session);noteValues.removeValue(forKey:session);noteReadFailures.remove(session)
            if current["session"] as? String==session {current["session"]=NSNull();current["phase"]="idle"}
            lock.unlock()
        }
    }
    func restoreSession(_ session:String)throws {
        try queue.sync {if store==nil {open()};guard let store else{throw Failure(code:"context_restore_unavailable")};try store.restoreSession(session);lock.lock();deletedSessions.remove(session);lock.unlock()}
    }
}

extension Delegate {
    // Historical documents share the recording owner's serial writer, but can
    // never activate or replace the current recording's projection.
    var documentContextPublisher:MeetingContextPublisher? {isHistoryReader ? workspaceOwner?.contextPublisher:contextPublisher}
    var documentContextSession:String? {
        if isHistoryReader {
            guard let session=activeSession,session != workspaceOwner?.contextSession else{return nil}
            return session
        }
        return contextSession
    }
    func configureMeetingContext() {
        guard !previewRenderOnly,!isHistoryReader else{return}
        let base=RuntimeConfiguration.dataRoot()
        let folder=Credential.offline ? base.appendingPathComponent("DevelopmentQA/AgentContext"):base.appendingPathComponent("AgentContext")
        contextPublisher=MeetingContextPublisher(directory:folder)
    }
    func contextMetadata()->[String:Any]? {
        guard let session=documentContextSession,activeSession==session else{return nil}
        var metadata:[String:Any] = ["schema":1,"session":session,"cache_id":currentCacheID.map{$0 as Any} ?? NSNull(),"title":meetingTitle,"phase":phase.phase.rawValue,"local_only":sessionLocalOnly,"projection_updating":fullTranscriptRefreshPending || fullRefreshBuildInFlight,"recording_elapsed_seconds":phase.elapsed,"asr_states":asrNetworkStates,"transcription_complete":cachedTranscriptionComplete,"response_mode":isHistoryReader ? "saved_meeting":"live_meeting"]
        if let absoluteTime {metadata["absolute_clock"]=["schema":1,"basis":"capture_clock","time_zone":absoluteTime.zone.identifier,"anchors":absoluteTime.anchors.map{["relative_start":$0.relative,"unix_time":$0.unix]}]}
        if let recovery=recordingRecoveryContext(session:session) {metadata["recording_recovery"]=recovery}
        return metadata
    }
    private func recordingRecoveryContext(session:String)->[String:Any]? {
        guard let id=currentCacheID,UUID(uuidString:id) != nil else{return nil}
        let directory=meetingCacheRoot().appendingPathComponent(id,isDirectory:true)
        guard let metadata=(try? JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("meeting.json")))) as? [String:Any],metadata["session"] as? String==session else{return nil}
        func read(_ name:String,limit:Int)->[String:Any]? {
            let path=directory.appendingPathComponent(name)
            guard let attributes=try? path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),attributes.isRegularFile==true,attributes.isSymbolicLink != true,(attributes.fileSize ?? Int.max)<=limit,
                  let data=try? Data(contentsOf:path),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  value["schema"] as? Int==1,value["cache_id"] as? String==id else{return nil}
            return value
        }
        let receipt=read("journal-recovery.json",limit:128*1024)
        let diagnostic=read("journal-recovery-diagnostic.json",limit:16*1024)
        let receiptState=receipt?["state"] as? String
        let diagnosticState=diagnostic?["state"] as? String
        guard let state=(receiptState.flatMap{["prepared","recovered_unclean_shutdown"].contains($0) ? $0:nil}) ?? (diagnosticState=="source_error" ? "source_error":nil) else{return nil}
        let tracks=(receipt?["tracks"] as? [[String:Any]] ?? []).compactMap{row -> [String:Any]? in
            guard let track=row["track"] as? String,isMeetingAudioTrack(track),let before=row["original_written_bytes"] as? Int,let after=row["verified_written_bytes"] as? Int,let tail=row["verified_tail_bytes"] as? Int else{return nil}
            return ["track":track,"before_bytes":before,"verified_bytes":after,"verified_tail_bytes":tail]
        }
        return ["kind":"interrupted_capture","state":state,"code":diagnostic?["code"] ?? NSNull(),"audio_files_preserved":true,"gapless_capture_verified":false,"transcript_modified":false,"transcription_started":false,"tracks":tracks,"warnings":receipt?["warnings"] as? [String] ?? []]
    }
    func beginMeetingContext() {
        guard !isHistoryReader,let session=activeSession,let contextPublisher else{return}
        contextSession=session
        if let info=contextMetadata(){contextPublisher.activate(info)}
        trackMeetingNotesContext()
        // Resume may already contain restored canonical turns; ordinary new starts are empty.
        if !sequence.isEmpty {markAllTranscriptParentsDirty();scheduleTranscriptRender()}
    }
    func updateMeetingContext() {
        if let info=contextMetadata(){documentContextPublisher?.update(info)}
        else if !isHistoryReader,contextSession != nil,activeSession != contextSession {contextSession=nil;contextPublisher?.clearCurrent()}
        trackMeetingNotesContext()
    }
    private func trackMeetingNotesContext() {
        guard let session=documentContextSession,activeSession==session,let id=currentCacheID,UUID(uuidString:id) != nil,
              !Credential.offline || recoveryRootOverride != nil else{return}
        documentContextPublisher?.trackNotes(session:session,directory:recoveryBase().appendingPathComponent(id))
    }
    func flushMeetingContext(completion:@escaping(Bool)->Void) {
        // A restored history view must drain the shared owner's serial writer
        // even when the viewed session is also its current context session.
        // The flush is read-only with respect to the selected historical view.
        let session=isHistoryReader ? activeSession:contextSession
        let publisher=isHistoryReader ? workspaceOwner?.contextPublisher:contextPublisher
        guard let session,activeSession==session,let publisher else{completion(false);return}
        publisher.flush(timeout:10,completion:completion)
    }
    func publishMeetingContext(parent:String,turns:[ReadingTurn]) {
        agentController?.invalidateContext()
        guard let session=documentContextSession,activeSession==session,let contextPublisher=documentContextPublisher else{return}
        let rows:[[String:Any]]=turns.map{turn in
            let item=turn.item,start=TranscriptTimeline.start(item)
            let end=item["end_time_known"] as? Bool==false ? nil:item["end"] as? Double
            let parts:[[String:Any]]=turn.parts.map{id,part in
                let resolved=naming.displayName(segment:id) ?? (naming.key(segment:id) ?? SessionSpeakerKey.from(part)).flatMap{naming.displayName(speaker:$0)}
                let confirmed=resolved?.origin == .manual
                var row:[String:Any]=["id":id,"text":part["text"] as? String ?? "","speaker":speakerLabel(id,part),"speaker_confirmed":confirmed,"speaker_name_origin":resolved?.origin.rawValue ?? "anonymous","start":TranscriptTimeline.start(part),"end":part["end_time_known"] as? Bool==false ? NSNull():part["end"] ?? NSNull()]
                if let final=part["final"] as? Bool {row["final"]=final}
                row["quality_flags"]=part["quality_flags"] as? [String] ?? []
                if let quality=part["text_quality"] as? String {row["text_quality"]=quality}
                if confirmed,let reference=naming.personReference(segment:id),reference.name==resolved?.value {
                    row["shared_person_id"]=reference.id;row["shared_person_evidence"]=reference.evidence
                }
                return row
            }
            let origins=Set(parts.compactMap{$0["speaker_name_origin"] as? String})
            var row:[String:Any]=["id":turn.id,"parent":parent,"text":item["text"] as? String ?? "","speaker":readingTurnLabel(turn),"speaker_confirmed":!turn.uncertain && parts.allSatisfy{$0["speaker_confirmed"] as? Bool==true},"speaker_name_origin":origins.count==1 ? origins.first! : "mixed","uncertain":turn.uncertain,"final":item["final"] as? Bool ?? false,"start":start,"end":end as Any? ?? NSNull(),"absolute_start":absoluteTime?.iso(start) as Any? ?? NSNull(),"absolute_end":end.flatMap{absoluteTime?.iso($0,endBoundary:true)} as Any? ?? NSNull(),"source":audioSourceLabel(item),"parts":parts]
            var flags=(item["quality_flags"] as? [String] ?? []) + parts.flatMap{$0["quality_flags"] as? [String] ?? []}
            if parts.contains(where:{$0["final"] as? Bool==false}) {flags.append("contains_nonfinal_part")}
            if parts.contains(where:{["unreliable","needs_review"].contains($0["text_quality"] as? String ?? "")}) {flags.append("text_needs_review")}
            row["quality_flags"]=Array(Set(flags)).sorted()
            if let quality=item["text_quality"] as? String {row["text_quality"]=quality}
            // A turn-level identity is safe only if every constituent part was
            // manually linked to the same person and the same source evidence.
            if !turn.uncertain,let first=parts.first,let id=first["shared_person_id"] as? String,
               let evidence=first["shared_person_evidence"] as? [String],
               parts.allSatisfy({$0["shared_person_id"] as? String==id && $0["shared_person_evidence"] as? [String]==evidence}) {
                row["shared_person_id"]=id;row["shared_person_evidence"]=evidence
            }
            return row
        }
        contextPublisher.replace(session:session,parent:parent,rows:rows)
    }
}
