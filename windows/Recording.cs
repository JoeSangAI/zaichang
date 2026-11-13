using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ZaichangWindows;

internal static class Storage {
    internal static string Root => Environment.GetEnvironmentVariable("ZAICHANG_DATA_ROOT") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ZaichangStandalone");
    internal static readonly JsonSerializerOptions Json=new(){WriteIndented=true};
    internal static void Save(string path,object data) {
        string temp=path+".tmp";
        using(var file=new FileStream(temp,FileMode.Create,FileAccess.Write,FileShare.None)) {JsonSerializer.Serialize(file,data,Json);file.Flush(true);}
        File.Move(temp,path,true);
    }
    internal static double Now=>DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()/1000.0;
    internal static JsonObject Read(string path)=>JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new InvalidDataException("记录格式无效");
    internal static void Append(string path,object data) {
        byte[] bytes=System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(data)+"\n");
        using var file=new FileStream(path,FileMode.Append,FileAccess.Write,FileShare.Read);file.Write(bytes);file.Flush(true);
    }
}

internal sealed class Journal : IAsyncDisposable {
    internal const int ChunkBytes=320000;
    const int MaximumPendingBytes=32000*180;
    readonly string folder,track;
    readonly double origin;
    readonly Channel<(byte[] Data,long Offset)> queue=Channel.CreateUnbounded<(byte[],long)>(new UnboundedChannelOptions{SingleReader=true});
    readonly Task writer;
    readonly List<Dictionary<string,object>> chunks=new();
    FileStream? file;
    long written,pending,offered,padding;
    int count;
    string? error;
    bool ended,accepting=true;
    internal string? Error=>error;
    internal long Bytes=>Interlocked.Read(ref written);
    internal Journal(string folder,string track,double origin) {
        this.folder=folder;this.track=track;this.origin=origin;
        SaveManifest();writer=Task.Run(WriteLoop);
    }
    internal void Offer(ReadOnlySpan<byte> bytes,double elapsed) {
        if(!accepting)return;
        long offset=Math.Max(0,(long)((elapsed-bytes.Length/32000.0)*16000)*2);
        Interlocked.Add(ref offered,bytes.Length);
        if(Interlocked.Read(ref pending)+bytes.Length>MaximumPendingBytes) {error="cache_writer_backpressure";return;}
        var copy=bytes.ToArray();Interlocked.Add(ref pending,copy.Length);
        if(!queue.Writer.TryWrite((copy,offset))) Interlocked.Add(ref pending,-copy.Length);
    }
    async Task WriteLoop() {
        try {
            await foreach(var packet in queue.Reader.ReadAllAsync()) {
                try {
                    // Timeline gaps (paused input or a device returning silence) are explicit zeros.
                    long gap=packet.Offset-written;
                    if(gap>3200) {padding+=gap;while(gap>0){int n=(int)Math.Min(gap,32000);Write(new byte[n]);gap-=n;}}
                    Write(packet.Data);
                } finally {Interlocked.Add(ref pending,-packet.Data.Length);}
            }
            Seal();ended=true;SaveManifest();
        } catch(Exception ex) {error=ex is IOException ? "cache_write_failed" : ex.GetType().Name;try{file?.Flush(true);}catch{} file?.Dispose();file=null;try{SaveManifest();}catch{} throw;}
    }
    void Write(byte[] bytes) {
        int cursor=0;
        while(cursor<bytes.Length) {
            if(new DriveInfo(Path.GetPathRoot(folder)!).AvailableFreeSpace<32*1024*1024) throw new IOException("磁盘空间不足");
            if(file==null){int index=chunks.Count;file=new FileStream(Path.Combine(folder,$"{track}-{index:D6}.pcm"),FileMode.CreateNew,FileAccess.Write,FileShare.Read);count=0;chunks.Add(new(){{"index",index},{"start_sample",written/2},{"bytes",0}});SaveManifest();}
            int n=Math.Min(ChunkBytes-count,bytes.Length-cursor);file.Write(bytes,cursor,n);cursor+=n;count+=n;Interlocked.Add(ref written,n);chunks[^1]["bytes"]=count;
            if(count==ChunkBytes)Seal();
        }
    }
    void Seal(){if(file==null)return;string path=file.Name;file.Flush(true);file.Dispose();file=null;chunks[^1]["sha256"]=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();SaveManifest();}
    void SaveManifest()=>Storage.Save(Path.Combine(folder,track+"-manifest.json"),new{schema=1,track,format="pcm_s16le",sample_rate=16000,channels=1,written_bytes=written,offered_bytes=offered+padding,origin_uptime=origin,ended,error,chunks,asr_committed_bytes=0,model_committed_bytes=0,archived=false,audio_cleaned=false,contains_voiceprint_embeddings=false,alignment_padding_bytes=padding,admitted_pcm_bytes=offered,padding_counters_known=true});
    public async ValueTask DisposeAsync(){accepting=false;queue.Writer.TryComplete();await writer;}
    internal static void Recover(string folder) {
        if(Storage.Read(Path.Combine(folder,"meeting.json"))["source_platform"]?.ToString()!="windows")return;
        using var lease=new FileStream(Path.Combine(folder,".writer.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        foreach(string track in new[]{"mic","remote"}) {
            string path=Path.Combine(folder,track+"-manifest.json");if(!File.Exists(path))continue;
            var manifest=Storage.Read(path);if(manifest["ended"]?.GetValue<bool>()==true)continue;
            var previous=(manifest["chunks"] as JsonArray??new()).ToArray();
            var names=Directory.GetFiles(folder,track+"-*.pcm").Order().ToArray();var recovered=new JsonArray();long total=0;
            for(int i=0;i<names.Length;i++) {
                if(Path.GetFileName(names[i])!=$"{track}-{i:D6}.pcm")throw new InvalidDataException("录音分片不连续，原件已保留。");
                byte[] bytes=File.ReadAllBytes(names[i]);
                if(bytes.Length%2!=0||bytes.Length>ChunkBytes||(i<names.Length-1&&bytes.Length!=ChunkBytes))throw new InvalidDataException("录音分片不完整，原件已保留。");
                string hash=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
                if(i<previous.Length&&previous[i]?["sha256"] is JsonNode sealedHash&&sealedHash.ToString()!=hash)throw new InvalidDataException("已保存录音的校验不一致，原件已保留。");
                recovered.Add(new JsonObject{["index"]=i,["start_sample"]=total/2,["bytes"]=bytes.Length,["sha256"]=hash});total+=bytes.Length;
            }
            string backups=Path.Combine(folder,".journal-recovery-backups");Directory.CreateDirectory(backups);
            File.Copy(path,Path.Combine(backups,track+"-"+Guid.NewGuid()+".json"));
            manifest["chunks"]=recovered;manifest["written_bytes"]=total;manifest["offered_bytes"]=Math.Max(total,manifest["offered_bytes"]?.GetValue<long>()??0);manifest["ended"]=true;manifest["error"]="cache_unclean_shutdown";Storage.Save(path,manifest);
        }
    }
    internal static long Verify(string folder,string track) {
        var manifest=Storage.Read(Path.Combine(folder,track+"-manifest.json"));long total=0;
        foreach(var row in (JsonArray)manifest["chunks"]!) {
            int index=row!["index"]!.GetValue<int>();var bytes=File.ReadAllBytes(Path.Combine(folder,$"{track}-{index:D6}.pcm"));
            if(bytes.Length!=row["bytes"]!.GetValue<int>()||Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()!=row["sha256"]!.GetValue<string>()) throw new InvalidDataException("录音校验不一致");
            total+=bytes.Length;
        }
        if(total!=manifest["written_bytes"]!.GetValue<long>())throw new InvalidDataException("录音长度不一致");return total;
    }
    internal static void Export(string folder,string track,string target) {
        Verify(folder,track);
        using var wav=new WaveFileWriter(target,new WaveFormat(16000,16,1));
        foreach(var row in (JsonArray)Storage.Read(Path.Combine(folder,track+"-manifest.json"))["chunks"]!) {
            int index=row!["index"]!.GetValue<int>();var bytes=File.ReadAllBytes(Path.Combine(folder,$"{track}-{index:D6}.pcm"));wav.Write(bytes,0,bytes.Length);
        }
    }
}

internal sealed class RecordingSession : IAsyncDisposable {
    internal readonly string Folder,Id;
    readonly Stopwatch clock=Stopwatch.StartNew();
    readonly List<(WasapiCapture Capture,Journal Journal,TaskCompletionSource Done)> tracks=new();
    readonly FileStream lease;
    internal bool Paused;
    string? captureError;
    Task? ending;
    internal string? Error=>captureError??tracks.Select(t=>t.Journal.Error).FirstOrDefault(e=>e!=null);
    internal RecordingSession(bool microphone,bool computer) {
        if(!microphone&&!computer)throw new InvalidOperationException("请选择一个声音来源。");
        Id=Guid.NewGuid().ToString();Folder=Path.Combine(Storage.Root,"SessionCache",Id);Directory.CreateDirectory(Folder);
        lease=new FileStream(Path.Combine(Folder,".writer.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        Storage.Save(Path.Combine(Folder,"meeting.json"),new {session=Id,cache_id=Id,bundle=computer?"*system*":"*microphone*",mic_enabled=microphone,created_at=Storage.Now,capture_mode="local_only",upload_authorized=false,asr_destination="",asr_model="qwen-audio-3.0-asr-flash-streaming",source_platform="windows",capture_origin_uptime=0});
        try {
            using var devices=new MMDeviceEnumerator();
            if(microphone)Add(new WasapiCapture(devices.GetDefaultAudioEndpoint(DataFlow.Capture,Role.Communications)),"mic");
            if(computer)Add(new WasapiLoopbackCapture(devices.GetDefaultAudioEndpoint(DataFlow.Render,Role.Multimedia)),"remote");
            foreach(var track in tracks)track.Capture.StartRecording();
        }catch{foreach(var t in tracks){try{t.Capture.StopRecording();}catch{}t.Capture.Dispose();t.Journal.DisposeAsync().AsTask().GetAwaiter().GetResult();}lease.Dispose();throw;}
    }
    void Add(WasapiCapture capture,string track) {
        capture.WaveFormat=new WaveFormat(16000,16,1);
        var journal=new Journal(Folder,track,0);var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        capture.DataAvailable+=(_,e)=>{if(!Paused)journal.Offer(e.Buffer.AsSpan(0,e.BytesRecorded),clock.Elapsed.TotalSeconds);};
        capture.RecordingStopped+=(_,e)=>{if(e.Exception!=null)captureError=e.Exception.Message;done.TrySetResult();};
        tracks.Add((capture,journal,done));
    }
    public ValueTask DisposeAsync()=>new(ending??=End());
    async Task End() {
        try {
            foreach(var t in tracks){try{t.Capture.StopRecording();}catch(Exception ex){captureError??=ex.Message;}}
            foreach(var t in tracks) {
                try{await t.Done.Task.WaitAsync(TimeSpan.FromSeconds(10));}catch(Exception ex){captureError??=ex.Message;}
                try{t.Capture.Dispose();}catch(Exception ex){captureError??=ex.Message;}
                try{await t.Journal.DisposeAsync();}catch(Exception ex){captureError??=ex.Message;}
            }
            var metadata=Storage.Read(Path.Combine(Folder,"meeting.json"));metadata["ended_at"]=Storage.Now;metadata["capture_error"]=Error;Storage.Save(Path.Combine(Folder,"meeting.json"),metadata);
        }finally{lease.Dispose();}
    }
    internal static object Probe() {
        using var devices=new MMDeviceEnumerator();
        return new{microphones=devices.EnumerateAudioEndPoints(DataFlow.Capture,DeviceState.Active).Select(d=>d.FriendlyName).ToArray(),outputs=devices.EnumerateAudioEndPoints(DataFlow.Render,DeviceState.Active).Select(d=>d.FriendlyName).ToArray(),recording=false};
    }
}
