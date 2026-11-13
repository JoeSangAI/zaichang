# Windows 开发预览

`windows/` 提供独立的 WPF Windows 宿主；保留现有 Swift/macOS 宿主，共用 Python 助理和数据格式。目前不是与 Mac 功能对齐的正式发行版，不进入 Mac 发布或自动更新流程。

## 构建与运行

拿到预编译 ZIP 的试用者：将整个压缩包解压到一个文件夹，双击 `Zaichang.exe`，保留旁边的文件和目录。建议先录一段自己的短语音，检查暂停、结束和 WAV 导出，再按需填写自己的百炼密钥试转写与助理；在线功能由你的账号计费。反馈请附 Windows 版本、使用的声音来源、失败步骤和截图，不发送密钥或私人会议内容。只有源码包时才需要执行下面的构建步骤。

需要 Windows 11 x64 与 .NET 10 SDK；已使用 SDK 10.0.404 编译。运行成品不需要另装 SDK 或 Python。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
.runtime/windows/app/Zaichang.exe
```

脚本发布自包含程序，并下载 Python 3.14.10 官方嵌入包，核对固定 SHA-256 后打包。可用 `-Python` 指定已有官方嵌入式 Python，`-Output` 指定目标。NAudio.Core 和 NAudio.Wasapi 固定为 2.3.0。

默认数据目录 `%LOCALAPPDATA%/ZaichangStandalone`，隔离测试用 `ZAICHANG_DATA_ROOT`。录音文件、原文、笔记与助理状态全部留在这个目录；Mac 默认路径不变。会话标记 `source_platform=windows`，自动恢复只处理 Windows 创建的会话。

## 当前功能与边界

原生界面包含会议列表、麦克风/电脑声音选择、开始/暂停/结束录音、原文、笔记、会后转写、WAV/Markdown 导出及助理面板。

录音通过 WASAPI，保存为 mono 16 kHz s16le 分片及带 SHA-256 的清单。先保存原音，再由用户单独点击转写。转写将音频发送至用户自己的百炼账号并产生费用；密钥仅在本次打开期间保留。助理提问也按已有百炼路由计费，没有后台自动授权。声音来源只标为“本地麦克风/电脑声音”，不冒认身份。

未接入实时转写、声纹与声音记忆、旁听唤醒、自动命名、完整原文整理、Keychain 对应的持久密钥保存、Mac 的完整笔记展示及自动更新。当前笔记编辑器只编辑自己的 `windows-note`，不覆盖导入的其他笔记。录音设备和云端链路尚不能仅凭编译或文件测试认定通过。

## 无模型费用的验证

```powershell
$env:ZAICHANG_DATA_ROOT = "$env:TEMP/Zaichang-Windows-check"
Zaichang.exe --probe "$env:TEMP/Zaichang-audio-devices.json"
Zaichang.exe --self-test "$env:TEMP/Zaichang-check" C:/path/to/public-mono.wav
```

`--probe` 仅枚举设备，不录音。`--self-test` 使用提供的真实公开单声道 WAV，重复输入以跨越 320000 字节分片边界，核对导出音频一致性、中断恢复、幂等恢复、损坏校验拒绝、离线助理连接和窗口渲染。不会打开麦克风、电脑声音或云端模型。生成 `result.json`、`window.png`、`roundtrip.wav` 与测试分片。

本次使用 [Free Spoken Digit Dataset](https://github.com/Jakobovski/free-spoken-digit-dataset) 的 `recordings/0_george_0.wav`（公开真人语音，原始 8 kHz）。测试材料只保存在被忽略的本地目录，未纳入产品包或会议库。

Windows 没有登录桌面时，设备枚举和界面交互可能受限。必须另行核对真实录音、暂停恢复、设备切换、云端转写和助理请求，才能发布给普通用户。
