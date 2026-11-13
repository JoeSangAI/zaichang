using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
namespace ZaichangWindows;
internal static class Program {
    [STAThread] static int Main(string[] args) {
        try {
            if(args.Length>0&&args[0]=="--probe") {File.WriteAllText(args[1],JsonSerializer.Serialize(RecordingSession.Probe(),Storage.Json));return 0;}
            var app=new Application();
            if(args.Length>0&&args[0]=="--self-test")return Check(app,args[1],args[2]);
            app.Run(new MeetingWindow());return 0;
        }catch(Exception ex){if(args.Length>1)File.WriteAllText(args[1]+".error",ex.ToString());else MessageBox.Show(ex.Message,"在场");return 1;}
    }
    static int Check(Application app,string output,string audio) {
        Directory.CreateDirectory(output);int result=1;
        var window=new MeetingWindow();
        window.Loaded+=async (_,_)=>{
            try {
                var folder=Path.Combine(output,"journal");Directory.CreateDirectory(folder);
                var journal=new Journal(folder,"mic",0);var buffer=new byte[3200];long count=0;
                using var hash=System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
                // Repeat the supplied real recording to cross a sealed chunk boundary.
                for(int replay=0;replay<40;replay++) {
                    using var input=new WaveFileReader(audio);
                    var samples=new WdlResamplingSampleProvider(input.ToSampleProvider(),16000);IWaveProvider pcm=new SampleToWaveProvider16(samples);
                    for(int n;(n=pcm.Read(buffer,0,buffer.Length))>0;){count+=n;hash.AppendData(buffer,0,n);journal.Offer(buffer.AsSpan(0,n),count/32000.0);}
                }
                await journal.DisposeAsync();long bytes=Journal.Verify(folder,"mic");Journal.Export(folder,"mic",Path.Combine(output,"roundtrip.wav"));
                using var wav=new WaveFileReader(Path.Combine(output,"roundtrip.wav"));using var reread=new MemoryStream();wav.CopyTo(reread);
                bool lossless=hash.GetHashAndReset().SequenceEqual(System.Security.Cryptography.SHA256.HashData(reread.ToArray()));
                // Reopen the real public-audio journal as after an interrupted seal.
                Storage.Save(Path.Combine(folder,"meeting.json"),new{source_platform="windows"});
                string manifestPath=Path.Combine(folder,"mic-manifest.json");var interrupted=Storage.Read(manifestPath);
                interrupted["ended"]=false;interrupted["written_bytes"]=0;interrupted["chunks"]![0]!["bytes"]=0;
                ((JsonObject)interrupted["chunks"]![0]!).Remove("sha256");Storage.Save(manifestPath,interrupted);
                Journal.Recover(folder);bool recovered=Journal.Verify(folder,"mic")==count;
                string sealedManifest=File.ReadAllText(manifestPath);Journal.Recover(folder);
                bool idempotent=File.ReadAllText(manifestPath)==sealedManifest;
                var damaged=Storage.Read(manifestPath);damaged["ended"]=false;damaged["chunks"]![0]!["sha256"]="invalid";Storage.Save(manifestPath,damaged);
                bool corruptionRejected=false;try{Journal.Recover(folder);}catch(InvalidDataException){corruptionRejected=true;}
                File.WriteAllText(manifestPath,sealedManifest);
                bool recovery=recovered&&idempotent&&corruptionRejected&&Journal.Verify(folder,"mic")==count;
                using var assistant=new Assistant();await assistant.Start(offline:true);var bound=await assistant.Call("bind","windows-check",new{title="Windows 离线验收"});await assistant.Call("context","windows-check",new{title="Windows 离线验收",notes="",segments=Array.Empty<object>(),meeting_state="stopped"});await assistant.Stop();
                var visual=(FrameworkElement)window.Content;var bitmap=new RenderTargetBitmap((int)visual.ActualWidth,(int)visual.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(visual);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using(var file=File.Create(Path.Combine(output,"window.png")))png.Save(file);
                File.WriteAllText(Path.Combine(output,"result.json"),JsonSerializer.Serialize(new{passed=bytes==count&&count>0&&lossless&&recovery,bytes,lossless,recovery,idempotent,corruptionRejected,assistant=bound,recording=false,cloud=false},Storage.Json));result=bytes==count&&count>0&&lossless&&recovery?0:1;
            }catch(Exception ex){File.WriteAllText(Path.Combine(output,"failure.txt"),ex.ToString());}
            window.Close();
        };app.Run(window);return result;
    }
}
internal sealed class MeetingWindow : Window {
    readonly ListBox library=new(){Margin=new Thickness(16),DisplayMemberPath="Title"};
    readonly TextBox transcript=new(){IsReadOnly=true,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,BorderThickness=new Thickness(0),Padding=new Thickness(20),FontSize=16};
    readonly TextBox notes=new(){AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Padding=new Thickness(20),FontSize=16};
    readonly TextBox conversation=new(){IsReadOnly=true,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,BorderThickness=new Thickness(0),Padding=new Thickness(20)};
    readonly TextBox question=new(){Margin=new Thickness(12),MinHeight=50,TextWrapping=TextWrapping.Wrap,AcceptsReturn=true};
    readonly TextBlock status=new(){Text="准备好时，开始一场讨论。",Margin=new Thickness(20,10,20,15),Foreground=Brushes.DimGray};
    readonly CheckBox mic=new(){Content="麦克风",IsChecked=true,Margin=new Thickness(10)},computer=new(){Content="电脑声音",IsChecked=true,Margin=new Thickness(10)};
    readonly PasswordBox key=new(){Width=220,Margin=new Thickness(10)};
    readonly Button record=new(){Content="开始录音",Padding=new Thickness(18,9,18,9),Margin=new Thickness(8)},pause=new(){Content="暂停",IsEnabled=false,Margin=new Thickness(8)};
    readonly Assistant assistant=new();
    readonly CancellationTokenSource cancellation=new();
    RecordingSession? recording;
    string? selected;
    bool stopping,busy,allowClose;
    sealed record Entry(string Folder,string Title);
    internal MeetingWindow() {
        Title="在场";Width=1200;Height=780;MinWidth=850;MinHeight=580;Background=Brushes.White;FontFamily=new FontFamily("Microsoft YaHei UI");
        var root=new DockPanel{Background=Brushes.White};Content=root;
        var header=new DockPanel{Margin=new Thickness(20,12,20,0)};DockPanel.SetDock(header,Dock.Top);root.Children.Add(header);
        header.Children.Add(new TextBlock{Text="在场",FontSize=30,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,30,0)});
        var controls=new StackPanel{Orientation=Orientation.Horizontal};header.Children.Add(controls);controls.Children.Add(mic);controls.Children.Add(computer);controls.Children.Add(record);controls.Children.Add(pause);
        DockPanel.SetDock(status,Dock.Bottom);root.Children.Add(status);
        var grid=new Grid();grid.ColumnDefinitions.Add(new(){Width=new GridLength(240)});grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=new GridLength(350)});root.Children.Add(grid);
        grid.Children.Add(library);
        var tabs=new TabControl{Margin=new Thickness(10)};Grid.SetColumn(tabs,1);grid.Children.Add(tabs);tabs.Items.Add(new TabItem{Header="原文",Content=transcript});tabs.Items.Add(new TabItem{Header="笔记",Content=notes});
        var tools=new StackPanel{Margin=new Thickness(20)};
        tools.Children.Add(new TextBlock{Text="转写录音",FontSize=22});tools.Children.Add(new TextBlock{Text="录音始终先保存在本机。转写会将本场音频发送给百炼，由你的账号计费。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,15,0,15)});tools.Children.Add(new TextBlock{Text="百炼密钥（仅本次打开期间使用）"});tools.Children.Add(key);
        var transcribe=Button("转写本场录音",async()=>await Transcribe());tools.Children.Add(transcribe);
        tools.Children.Add(Button("导出录音",()=>{ExportAudio();return Task.CompletedTask;}));
        tools.Children.Add(Button("导出原文与笔记",()=>{ExportText();return Task.CompletedTask;}));
        tools.Children.Add(new TextBlock{Text="Windows 预览版：已接入录音、会后转写、笔记和助理；声音记忆、实时旁听及自动更新仍待接入。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,24,0,0),Foreground=Brushes.DimGray});
        tabs.Items.Add(new TabItem{Header="本场设置",Content=tools});
        var aside=new DockPanel{Background=new SolidColorBrush(Color.FromRgb(247,247,247))};Grid.SetColumn(aside,2);grid.Children.Add(aside);
        var title=new TextBlock{Text="助理",FontSize=23,Margin=new Thickness(20)};DockPanel.SetDock(title,Dock.Top);aside.Children.Add(title);
        var send=Button("交给助理",async()=>await Ask());DockPanel.SetDock(send,Dock.Bottom);aside.Children.Add(send);DockPanel.SetDock(question,Dock.Bottom);aside.Children.Add(question);aside.Children.Add(conversation);
        record.Click+=async(_,_)=>await Guard(Record);pause.Click+=(_,_)=>{if(recording!=null){recording.Paused=!recording.Paused;pause.Content=recording.Paused?"继续":"暂停";status.Text=recording.Paused?"已暂停收音。":"正在录音，原音保存在本机。";}};
        library.SelectionChanged+=(_,_)=>{if(library.SelectedItem is Entry entry){SaveNotes();selected=entry.Folder;LoadMeeting();}};
        assistant.State+=(workspace,state)=>Dispatcher.BeginInvoke(()=>{if(selected==null||Path.GetFileName(selected)!=workspace)return;conversation.Text=string.Join("\n\n",(state["messages"] as JsonArray??new()).Select(m=>(m?["role"]?.ToString()=="user"?"你":"小满")+"："+m?["text"]));if(state["runtime_message"]!=null)status.Text=state["runtime_message"]!.ToString();});
        Closing+=async(_,e)=>{if(allowClose)return;e.Cancel=true;if(stopping)return;stopping=true;cancellation.Cancel();try{SaveNotes();if(recording!=null)await recording.DisposeAsync();await assistant.Stop();allowClose=true;_ = Dispatcher.BeginInvoke(Close);}catch(Exception ex){stopping=false;status.Text="退出前保存失败："+ex.Message;}};
        var health=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};
        health.Tick+=(_,_)=>{if(recording?.Error is string error)status.Text="录音遇到问题，已有原音保留："+error;};
        health.Start();Closed+=(_,_)=>health.Stop();
        Refresh();
    }
    Button Button(string label,Func<Task> action){var button=new Button{Content=label,Margin=new Thickness(10),Padding=new Thickness(12,8,12,8)};button.Click+=async(_,_)=>await Guard(action);return button;}
    async Task Guard(Func<Task> action){try{await action();}catch(Exception ex){status.Text=ex.Message;}}
    void Refresh(){string cache=Path.Combine(Storage.Root,"SessionCache");Directory.CreateDirectory(cache);library.Items.Clear();foreach(string folder in Directory.GetDirectories(cache).OrderDescending()){try{var meta=Storage.Read(Path.Combine(folder,"meeting.json"));try{Journal.Recover(folder);}catch(IOException){status.Text="有录音正在使用或需要检查，原件已保留。";}double stamp=meta["created_at"]?.GetValue<double>()??0;string title=DateTimeOffset.FromUnixTimeSeconds((long)stamp).ToLocalTime().ToString("MM-dd HH:mm");library.Items.Add(new Entry(folder,title));}catch{}}}
    async Task Record(){if(busy)throw new InvalidOperationException("请等本场处理结束。");if(recording==null){SaveNotes();recording=new RecordingSession(mic.IsChecked==true,computer.IsChecked==true);selected=recording.Folder;record.Content="结束录音";pause.IsEnabled=true;library.IsEnabled=false;LoadMeeting();status.Text="正在录音，原音保存在本机。";}else{await recording.DisposeAsync();string? captureError=recording.Error;recording=null;record.Content="开始录音";pause.IsEnabled=false;library.IsEnabled=true;status.Text=captureError==null?"录音已保存。可在本场设置中转写或导出。":"录音结束，已有原音保留；请检查："+captureError;Refresh();}}
    void LoadMeeting(){if(selected==null)return;var segments=Segments();transcript.Text=string.Join("\n\n",segments.Select(s=>$"{TimeSpan.FromSeconds(s["start"]?.GetValue<double>()??0):hh\\:mm\\:ss}  {s["speaker"]?["label"]}\n{s["text"]}"));notes.Text=ReadNotes();conversation.Clear();}
    JsonObject[] Segments(){if(selected==null)return [];return new[]{"mic","remote"}.SelectMany(track=>{string path=Path.Combine(selected,track+"-transcript.jsonl");return File.Exists(path)?File.ReadLines(path).Where(l=>l.Trim().Length>0).Select(l=>JsonNode.Parse(l) as JsonObject).Where(n=>n?["final"]?.GetValue<bool>()==true).Select(n=>n!):[];}).GroupBy(s=>s["segment_id"]!.ToString()).Select(g=>g.Last()).OrderBy(s=>s["start"]!.GetValue<double>()).ToArray();}
    string ReadNotes(){string path=Path.Combine(selected!,"notes","notes.jsonl");if(!File.Exists(path))return "";return string.Join("\n\n",File.ReadLines(path).Where(l=>l.Trim().Length>0).Select(l=>JsonNode.Parse(l)!).GroupBy(n=>n["note_id"]!.ToString()).Select(g=>g.Last()).Where(n=>n["op"]?.ToString()!="delete"&&n["note_id"]?.ToString()=="windows-note").Select(n=>n["text"]!.ToString()));}
    void SaveNotes(){if(selected==null||notes.Text==ReadNotes())return;string folder=Path.Combine(selected,"notes");Directory.CreateDirectory(folder);string path=Path.Combine(folder,"notes.jsonl");int rev=File.Exists(path)?File.ReadLines(path).Count()+1:1;Storage.Append(path,new{schema=1,op=rev==1?"create":"update",note_id="windows-note",rev,at_unix=Storage.Now,anchor=(object?)null,text=notes.Text,images=Array.Empty<object>(),starred=false,archive=true});}
    async Task Transcribe(){if(selected==null)throw new InvalidOperationException("请先选择一场会议。");if(recording!=null)throw new InvalidOperationException("请先结束录音。");if(busy)return;if(string.IsNullOrWhiteSpace(key.Password))throw new InvalidOperationException("请在本场设置里填写百炼密钥。");busy=true;library.IsEnabled=false;status.Text="正在转写，原音保持保留。";try{await Transcriber.Run(selected,key.Password,()=>Dispatcher.BeginInvoke(()=>{var savedNotes=notes.Text;LoadMeeting();notes.Text=savedNotes;}),cancellation.Token);status.Text="转写完成。";}finally{busy=false;library.IsEnabled=true;}}
    async Task Ask(){if(selected==null||string.IsNullOrWhiteSpace(question.Text))return;SaveNotes();string id=Path.GetFileName(selected);await assistant.Call("bind",id,new{cache_id=id,session_id=Storage.Read(Path.Combine(selected,"meeting.json"))["session"]!.ToString(),title="本场会议"});await assistant.Call("context",id,new{title="本场会议",notes=notes.Text,segments=Segments().Select(s=>new{id=s["segment_id"]!.ToString(),revision=1,start=s["start"]!.GetValue<double>(),end=s["end"]!.GetValue<double>(),text=s["text"]!.ToString(),final=true,speaker=s["speaker"]!.DeepClone()}).ToArray(),meeting_state=recording==null?"stopped":"recording"});if(!string.IsNullOrWhiteSpace(key.Password))await assistant.Call("overview_key",null,new{key=key.Password});await assistant.Call("send",id,new{text=question.Text});question.Clear();}
    void ExportAudio(){if(selected==null||recording!=null)throw new InvalidOperationException("请先结束并选择一场录音。");var dialog=new Microsoft.Win32.OpenFolderDialog();if(dialog.ShowDialog(this)!=true)return;foreach(string track in new[]{"mic","remote"})if(File.Exists(Path.Combine(selected,track+"-manifest.json")))Journal.Export(selected,track,Path.Combine(dialog.FolderName,$"在场-{Path.GetFileName(selected)}-{track}.wav"));status.Text="录音已导出。";}
    void ExportText(){if(selected==null)return;SaveNotes();var dialog=new Microsoft.Win32.SaveFileDialog{Filter="Markdown|*.md",FileName="会议记录.md"};if(dialog.ShowDialog(this)==true){File.WriteAllText(dialog.FileName,"# 原文\n\n"+transcript.Text+"\n\n# 个人笔记\n\n"+notes.Text,Encoding.UTF8);status.Text="原文与笔记已导出。";}}
}
