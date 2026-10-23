import Foundation
import Darwin

enum SpeakerRefinementJobError:Error,Equatable {
    case cancelled
    case invalidRequest
    case timeout
    case outputTooLarge
    case invalidOutput
    case helperFailed(Int32)
    case serviceFailure(String)
}

/// Runs one bounded local refinement helper. It never reads or writes meeting
/// files; callers own the snapshot and the final atomic sidecar commit.
final class SpeakerRefinementJob {
    private let queue=DispatchQueue(label:"meeting.speaker-refinement",qos:.utility)
    private let lock=NSLock()
    private let pendingWork=DispatchGroup()
    private var generation=UUID()
    private var process:Process?
    private var busyValue=false
    private var waitingValue=false
    private let timeout:TimeInterval
    private let outputLimit:Int

    init(timeout:TimeInterval=1800,outputLimit:Int=2*1024*1024) {
        self.timeout=min(1800,max(0.01,timeout))
        self.outputLimit=min(2*1024*1024,max(1,outputLimit))
    }

    var busy:Bool {lock.lock();defer{lock.unlock()};return busyValue}
    var waiting:Bool {lock.lock();defer{lock.unlock()};return waitingValue}

    private static func stop(_ child:Process) {
        guard child.isRunning else{return}
        let pid=child.processIdentifier
        child.terminate()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.5) {
            guard child.isRunning,child.processIdentifier==pid,pid>0 else{return}
            _=Darwin.kill(pid,SIGKILL)
        }
    }

    /// Invalidates an outstanding result and signals only the Process owned by
    /// this worker. It never waits for the child on the caller's thread.
    func cancel() {
        lock.lock();generation=UUID();let old=process;process=nil;busyValue=false;waitingValue=false;lock.unlock()
        if let old {Self.stop(old)}
    }

    var hasPendingWork:Bool {pendingWork.wait(timeout:.now()) != .success}

    /// Quit keeps the UI alive until cancellation has reaped owned subprocesses,
    /// including a job cancelled earlier whose SIGKILL escalation is still pending.
    func cancelAndWait(_ completion:@escaping()->Void) {
        cancel()
        pendingWork.notify(queue:.main,execute:completion)
    }

    /// Reserves the next result slot before its input snapshot is assembled.
    /// Pass this token to start(reservedToken:) to keep the same commit gate.
    func reserve()->UUID {
        cancel()
        let token=UUID()
        lock.lock();generation=token;waitingValue=true;lock.unlock()
        return token
    }

    /// Continue a completed stage without changing its cancellation/commit scope.
    func prepareNextProcess(_ token:UUID)throws {
        lock.lock();defer{lock.unlock()}
        guard generation==token,!busyValue,process==nil else{throw SpeakerRefinementJobError.cancelled}
        waitingValue=true
    }

    func isCurrent(_ token:UUID)->Bool {
        lock.lock();defer{lock.unlock()};return generation==token
    }

    /// Keep the closure limited to a quick atomic replacement. The lock makes
    /// cancellation/reservation and the replacement a single ordering point.
    func commitIfCurrent(_ token:UUID,_ replace:()throws->Void)throws {
        lock.lock();defer{lock.unlock()}
        guard generation==token else{throw SpeakerRefinementJobError.cancelled}
        try replace()
    }

    @discardableResult
    func start(request:[String:Any],executable:URL,models:URL,reservedToken:UUID?=nil,
               done:@escaping(UUID,Result<Data,Error>)->Void)->UUID {
        startProcess(request:request,executable:executable,arguments:["--refine-meeting-speakers",models.path],maximumInput:64*1024,reservedToken:reservedToken,done:done)
    }

    @discardableResult
    func startProcess(request:[String:Any],executable:URL,arguments:[String],maximumInput:Int=2*1024*1024,
                      maximumOutput:Int?=nil,reservedToken:UUID?=nil,done:@escaping(UUID,Result<Data,Error>)->Void)->UUID {
        let token=reservedToken ?? reserve()
        pendingWork.enter()
        queue.async {
            defer {self.pendingWork.leave()}
            var child:Process?
            var input:Pipe?
            var output:Pipe?
            var timer:DispatchWorkItem?
            var timedOut=false
            var result:Result<Data,Error>
            do {
                guard self.isCurrent(token) else{throw SpeakerRefinementJobError.cancelled}
                let outputLimit=maximumOutput ?? self.outputLimit
                guard executable.isFileURL,maximumInput>0,maximumInput<=4*1024*1024,outputLimit>0,outputLimit<=8*1024*1024 else{throw SpeakerRefinementJobError.invalidRequest}
                let data=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
                guard data.count+1<=maximumInput else{throw SpeakerRefinementJobError.invalidRequest}

                let proc=Process(),stdin=Pipe(),stdout=Pipe()
                proc.executableURL=executable
                proc.arguments=arguments
                var environment=RuntimeConfiguration.childEnvironment()
                for name in ["DASHSCOPE_API_KEY","ALIYUN_API_KEY","BAILIAN_API_KEY"] {environment.removeValue(forKey:name)}
                environment["PYTHONDONTWRITEBYTECODE"]="1"
                proc.environment=environment
                proc.standardInput=stdin;proc.standardOutput=stdout;proc.standardError=FileHandle.nullDevice
                proc.qualityOfService = .utility
                child=proc;input=stdin;output=stdout

                self.lock.lock()
                guard self.generation==token,self.waitingValue,self.process==nil else{self.lock.unlock();throw SpeakerRefinementJobError.cancelled}
                self.process=proc;self.busyValue=true;self.waitingValue=false
                do {try proc.run();self.lock.unlock()} catch {self.process=nil;self.busyValue=false;self.lock.unlock();throw error}

                let deadline=DispatchWorkItem {
                    self.lock.lock();let owns=self.generation==token && self.process===proc
                    if owns {timedOut=true};self.lock.unlock()
                    if owns {Self.stop(proc)}
                }
                timer=deadline
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+self.timeout,execute:deadline)

                try stdin.fileHandleForWriting.write(contentsOf:data+Data([10]))
                try stdin.fileHandleForWriting.close()
                let descriptor=stdout.fileHandleForReading.fileDescriptor
                let flags=fcntl(descriptor,F_GETFL)
                guard flags>=0,fcntl(descriptor,F_SETFL,flags | O_NONBLOCK)>=0 else{throw SpeakerRefinementJobError.invalidOutput}
                var bytes=Data();bytes.reserveCapacity(min(outputLimit,64*1024))
                var eof=false
                while !eof {
                    var buffer=[UInt8](repeating:0,count:16*1024)
                    let count=buffer.withUnsafeMutableBytes{Darwin.read(descriptor,$0.baseAddress,$0.count)}
                    if count>0 {
                        bytes.append(contentsOf:buffer.prefix(count))
                        if bytes.count>outputLimit {Self.stop(proc);throw SpeakerRefinementJobError.outputTooLarge}
                    } else if count==0 {eof=true}
                    else if errno==EAGAIN || errno==EWOULDBLOCK {
                        // Once our child exits, don't wait for an unrelated
                        // descendant that inherited its stdout descriptor.
                        if !proc.isRunning {break}
                        Thread.sleep(forTimeInterval:0.01)
                    } else if errno==EINTR {continue}
                    else {throw SpeakerRefinementJobError.invalidOutput}
                }
                proc.waitUntilExit()
                self.lock.lock();let stillCurrent=self.generation==token,expired=timedOut;self.lock.unlock()
                guard stillCurrent else{throw SpeakerRefinementJobError.cancelled}
                if expired {throw SpeakerRefinementJobError.timeout}
                guard proc.terminationStatus==0 else {
                    if let value=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],value["ok"] as? Bool==false || value["type"] as? String=="error",
                       let code=(value["error"] ?? value["code"]) as? String,code.range(of:"^[a-z_0-9]{1,80}$",options:.regularExpression) != nil {throw SpeakerRefinementJobError.serviceFailure(code)}
                    throw SpeakerRefinementJobError.helperFailed(proc.terminationStatus)
                }
                do {
                    guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],JSONSerialization.isValidJSONObject(object) else{throw SpeakerRefinementJobError.invalidOutput}
                } catch {throw SpeakerRefinementJobError.invalidOutput}
                result = .success(bytes)
            } catch {
                result = .failure(error)
            }

            self.lock.lock();let tokenCurrent=self.generation==token,deadlineExpired=timedOut;self.lock.unlock()
            if !tokenCurrent {result = .failure(SpeakerRefinementJobError.cancelled)}
            else if deadlineExpired {result = .failure(SpeakerRefinementJobError.timeout)}

            timer?.cancel()
            if let child {Self.stop(child)}
            try? input?.fileHandleForWriting.close()
            try? output?.fileHandleForReading.close()
            if let child,child.isRunning {
                // SIGKILL escalation above bounds the otherwise blocking reap.
                child.waitUntilExit()
            }
            self.lock.lock()
            if self.generation==token {
                if self.process === child {self.process=nil}
                self.busyValue=false;self.waitingValue=false
            }
            self.lock.unlock()
            done(token,result)
        }
        return token
    }

    deinit {cancel()}
}
