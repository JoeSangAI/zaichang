using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace ZaichangWindows;
internal sealed class Assistant : IDisposable {
    Process? process;
    readonly ConcurrentDictionary<string,TaskCompletionSource<JsonObject>> pending=new();
    readonly SemaphoreSlim sending=new(1);
    internal event Action<string,JsonObject>? State;
    internal async Task Start(bool offline=false) {
        if(process!=null)return;
        string python=Path.Combine(AppContext.BaseDirectory,"python","python.exe");if(!File.Exists(python))python=Environment.GetEnvironmentVariable("ZAICHANG_PYTHON")??"python.exe";
        Directory.CreateDirectory(Storage.Root);
        var start=new ProcessStartInfo(python){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardInputEncoding=new UTF8Encoding(false),WorkingDirectory=Storage.Root};
        foreach(var arg in new[]{"-X","utf8",Path.Combine(AppContext.BaseDirectory,"core","assistant_runtime.py"),"--store",Path.Combine(Storage.Root,"Assistant"),"--cwd",Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)})start.ArgumentList.Add(arg);
        if(offline)start.ArgumentList.Add("--offline");start.Environment["PYTHONUTF8"]="1";start.Environment["PYTHONDONTWRITEBYTECODE"]="1";
        process=Process.Start(start)??throw new IOException("助理没有启动。");
        _=Task.Run(async()=>{while(await process.StandardError.ReadLineAsync() is string _){};});
        _=Task.Run(async()=>{
            try {
                while(await process.StandardOutput.ReadLineAsync() is string line) {
                    if(JsonNode.Parse(line) is not JsonObject message)continue;
                    if(message["type"]?.ToString()=="response"&&pending.TryRemove(message["id"]?.ToString()??"",out var request))request.TrySetResult(message);
                    if(message["type"]?.ToString()=="assistant_state"&&message["state"] is JsonObject state)State?.Invoke(message["workspace_id"]!.ToString(),state);
                }
            } finally {foreach(var request in pending.Values)request.TrySetException(new IOException("助理连接已断开，录音和会议仍然保留。"));pending.Clear();}
        });
        await Task.CompletedTask;
    }
    internal async Task<JsonObject> Call(string method,string? workspace,object? parameters=null) {
        if(process==null)await Start();
        string id=Guid.NewGuid().ToString();var response=new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);pending[id]=response;
        try {
            await sending.WaitAsync();try{await process!.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new{id,method,workspace_id=workspace,@params=parameters??new{}}));await process.StandardInput.FlushAsync();}finally{sending.Release();}
            var message=await response.Task.WaitAsync(TimeSpan.FromSeconds(45));
            if(message["ok"]?.GetValue<bool>()!=true)throw new IOException(message["error"]?["message"]?.ToString()??"助理未完成请求。");
            return message["result"] as JsonObject??new();
        }finally{pending.TryRemove(id,out _);}
    }
    internal async Task Stop(){if(process==null)return;try{if(!process.HasExited){await Call("shutdown",null);process.StandardInput.Close();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));}}catch(IOException){}catch(TimeoutException){}finally{Dispose();}}
    public void Dispose(){if(process!=null){try{if(!process.HasExited)process.Kill(true);}catch{}process.Dispose();process=null;}}
}
