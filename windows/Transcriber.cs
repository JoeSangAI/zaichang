using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace ZaichangWindows;

internal static class Transcriber {
    internal static async Task Run(string folder,string key,Action changed,CancellationToken cancel) {
        using var lease=new FileStream(Path.Combine(folder,"transcription.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        foreach(string track in new[]{"mic","remote"}) {
            string path=Path.Combine(folder,track+"-manifest.json");if(!File.Exists(path))continue;
            var manifest=Storage.Read(path);
            if(manifest["ended"]?.GetValue<bool>()!=true)throw new InvalidOperationException("请先结束录音。");
            long total=Journal.Verify(folder,track);
            long cursor=manifest["asr_committed_bytes"]?.GetValue<long>()??0;
            if(cursor>=total)continue;
            var metadata=Storage.Read(Path.Combine(folder,"meeting.json"));
            metadata["upload_authorized"]=true;metadata["asr_destination"]="dashscope.aliyuncs.com";Storage.Save(Path.Combine(folder,"meeting.json"),metadata);
            using var socket=new ClientWebSocket();socket.Options.SetRequestHeader("Authorization","Bearer "+key);
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancel);deadline.CancelAfter(TimeSpan.FromSeconds(60));
            await socket.ConnectAsync(new Uri("wss://dashscope.aliyuncs.com/api-ws/v1/inference/"),deadline.Token);
            string task=Guid.NewGuid().ToString();
            async Task Send(string action,object payload)=>await socket.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new {header=new{action,task_id=task,streaming="duplex"},payload})),WebSocketMessageType.Text,true,cancel);
            await Send("run-task",new{task_group="audio",task="asr",function="recognition",model=metadata["asr_model"]?.ToString()??"qwen-audio-3.0-asr-flash-streaming",parameters=new{format="pcm",sample_rate=16000,max_sentence_silence=1300},input=new{}});
            var ready=await Receive(socket,deadline.Token);
            if(ready["header"]?["event"]?.ToString()!="task-started")throw new IOException("转写服务未开始，请检查密钥与模型权限。");
            long startCursor=cursor;int seq=0;
            var receiver=Task.Run(async ()=>{
                while(true) {
                    using var idle=CancellationTokenSource.CreateLinkedTokenSource(cancel);idle.CancelAfter(TimeSpan.FromMinutes(2));
                    var result=await Receive(socket,idle.Token);
                    if(result["header"]?["task_id"]?.ToString()!=task)throw new IOException("转写任务标识不一致。");
                    string kind=result["header"]?["event"]?.ToString()??"";
                    if(kind=="task-failed")throw new IOException("转写服务报错；原音已保留，可稍后重试。");
                    if(kind=="task-finished")return;
                    var sentence=result["payload"]?["output"]?["sentence"] as JsonObject;
                    if(kind!="result-generated"||sentence==null||sentence["sentence_end"]?.GetValue<bool>()!=true)continue;
                    string text=sentence["text"]?.ToString()??"";if(string.IsNullOrWhiteSpace(text))continue;
                    double begin=sentence["begin_time"]!.GetValue<double>()/1000,end=sentence["end_time"]!.GetValue<double>()/1000;
                    if(!double.IsFinite(begin)||!double.IsFinite(end)||begin<0||end<begin)throw new IOException("转写时间无效。");
                    seq++;string id=task+":"+sentence["sentence_id"];
                    var segment=new {type="segment",session=metadata["session"]!.ToString(),application=metadata["bundle"]!.ToString(),event_id=task+":delivery:"+seq,segment_id=id,revision=1,source_seq=seq,received_at=Storage.Now,start=startCursor/32000.0+begin,end=startCursor/32000.0+end,end_time_known=true,text,final=true,speaker=new{basis="channel",label=track=="mic"?"本地麦克风":"电脑声音"},track,coverage_basis="local_received_results_not_provider_completeness"};
                    Storage.Append(Path.Combine(folder,track+"-transcript.jsonl"),segment);
                    long committed=Math.Min(total,startCursor+(long)(end*16000)*2);
                    manifest["asr_committed_bytes"]=committed;Storage.Save(path,manifest);changed();
                }
            },cancel);
            try {
                while(cursor<total) {
                    if(receiver.IsFaulted)await receiver;
                    int index=(int)(cursor/Journal.ChunkBytes),offset=(int)(cursor%Journal.ChunkBytes);
                    using var file=new FileStream(Path.Combine(folder,$"{track}-{index:D6}.pcm"),FileMode.Open,FileAccess.Read,FileShare.ReadWrite);file.Position=offset;
                    var buffer=new byte[3200];int n=await file.ReadAsync(buffer,cancel);if(n==0)throw new IOException("录音分片不完整。");
                    await socket.SendAsync(buffer.AsMemory(0,n),WebSocketMessageType.Binary,true,cancel);
                    cursor+=n;await Task.Delay(100,cancel);
                }
                await Send("finish-task",new{input=new{}});await receiver.WaitAsync(TimeSpan.FromSeconds(60),cancel);
                manifest["asr_committed_bytes"]=total;Storage.Save(path,manifest);
            }finally{socket.Abort();try{await receiver;}catch{}}
        }
    }
    static async Task<JsonObject> Receive(ClientWebSocket socket,CancellationToken token) {
        using var stream=new MemoryStream();var buffer=new byte[16384];WebSocketReceiveResult received;
        do{received=await socket.ReceiveAsync(buffer,token);if(received.MessageType!=WebSocketMessageType.Text)throw new IOException("转写连接已结束。");stream.Write(buffer,0,received.Count);if(stream.Length>2_000_000)throw new IOException("转写响应过大。");}while(!received.EndOfMessage);
        return JsonNode.Parse(stream.ToArray()) as JsonObject ?? throw new IOException("转写响应无效。");
    }
}
