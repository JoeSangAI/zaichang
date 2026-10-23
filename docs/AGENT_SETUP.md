# Agent 安装在场

用户说“帮我安装在场”时，从这里执行。默认由 Codex 完成；其他有本机终端能力的 agent 也可按同样步骤操作。先完成基础安装，再主动推荐下面的可选增强，每项获得用户同意后才配置。不要因为用户暂时不配置增强而阻止使用。

仓库应放在用户目录下（例如 `~/zaichang` 或 `~/Documents/zaichang`），不要放在 `/tmp`、`/private/tmp` 等系统临时目录：在场的数据安全检查会拒绝这些目录的路径别名。在仓库根目录执行命令，记录每步退出状态。安装涉及联网下载、编译和本机临时签名；先告诉用户这些操作。已有应用运行时，提醒用户保存并退出，再更新。不要替用户开始录音，不改系统隐私授权，不读取凭据文件或钥匙串。

## 必做：逐步安装并核验

1. 检查环境：

   ```sh
   uname -m
   sw_vers -productVersion
   python3 --version
   /usr/local/bin/python3 --version
   swift --version
   xcode-select -p
   ```

   必须是 Apple Silicon（`arm64`）、macOS 15+、Python 3.12、Swift 6、已安装 Xcode Command Line Tools。应用工作进程使用 `/usr/local/bin/python3`，也须确认它是可用的 Python 3.12；推荐 INSTALL 所述官方安装器。若缺少 CLT，运行 `xcode-select --install` 后由用户完成系统安装；Python 安装方法见 [INSTALL](INSTALL.md)。修复缺项后重查，不继续带病构建。

2. 安装 Python 依赖：

   ```sh
   python3 -m pip install -r requirements.txt
   python3 -c "import certifi, numpy; print('certifi', certifi.__version__, 'numpy', numpy.__version__)"
   ```

   第二条退出 0、能打印两个版本即可继续。只检查在场需要的这两个包；用户环境里其他工具之间的版本冲突与在场无关，不要用全局 `pip check` 判断，也不要为此改动用户的其他包。使用与后续构建相同的 Python；如果系统拒绝全局安装，采用 INSTALL 中要求的 Python 3.12 安装器，并确认与 `/usr/local/bin/python3` 一致，不用 `sudo pip`。pip 自身检查更新时打印的证书警告可以忽略；只有依赖安装失败、或上面的导入命令报错时，若错误是访问 PyPI 的证书校验失败（`CERTIFICATE_VERIFY_FAILED`），请用户运行 Python 安装目录里的 `Install Certificates.command`（例如 `open "/Applications/Python 3.12/Install Certificates.command"`）后重试。

3. 下载并验证模型及 SDK（约 570 MB，首次需要网络）：

   ```sh
   python3 scripts/bootstrap_dependencies.py
   ```

   退出 0 表示固定清单、大小与哈希验证通过。失败时修复网络或提示中指明的依赖，重跑会复用已验证的文件，不跳过校验。

4. 构建、离线验收、安装：

   ```sh
   python3 scripts/install_standalone.py
   test -x "$HOME/Applications/在场.app/Contents/MacOS/MeetingAssistant"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/在场.app/Contents/Info.plist"
   codesign --verify --deep --strict "$HOME/Applications/在场.app"
   ```

   安装器调用 `build_offline.py --edition standalone` 和 `offline_check.py --edition standalone`；任一步失败就停止。首次构建加离线验收通常需要十几分钟，期间会出现大量 Swift 编译警告（并发兼容、第三方 SDK 弃用接口等），以命令退出状态为准。离线验收通过只说明程序本身正常，不代表麦克风权限、真实录音或云端转写已经验证。确认版本为 `0.3.0`、签名检查退出 0。数据目录为 `~/Library/Application Support/ZaichangStandalone`；安装不会清空会议资料。

5. 检查本机 Codex：

   ```sh
   command -v codex
   codex --version
   codex login status
   ```

   没装 CLI 时按 [官方安装文档](https://developers.openai.com/codex/cli/) 安装。未登录时，请用户**自己在终端运行 `codex login`** 并完成登录。agent 不代登、不索要密码或令牌。用户选择暂不使用 Codex 时可先用录音、转写和导出，明确标注助理尚未就绪。

6. 登录后验证本机连接：

   ```sh
   python3 scripts/check_codex_runtime.py --connection-only --output .runtime/codex-connection
   ```

   确认 `ok: true`、`initialized: true`、`logged_in: true`。此模式只握手和读取登录状态，不启动模型轮次、不发送会议。`--live` 是单独的模型调用验收，基础安装不需要运行。

7. 交接给用户（这一步 agent 无法、也不应核验，告诉用户怎么做即可，不要去读钥匙串或系统隐私数据库）：请用户打开 `~/Applications/在场.app`，在设置里**自己填写百炼密钥**；没填时应用会显示“去设置里填写百炼密钥”，填好后这句提示消失。agent 不在对话中索要、不接收、不替用户写入密钥，也不把它放进 `connectors.json`。用户首次点击开始录音时，再按 macOS 提示授权麦克风与电脑声音；agent 不替用户采音。没有密钥时仍可选择仅录音；实时转写、整理、翻译与生成纪要需要该用户自己的服务凭据。

## 可选增强：安装完成后主动推荐

建议用一句话介绍：“基础功能已装好。还可以让助理了解你的项目、识别常用写法，或让你自己的 Codex 读取在场会议。”逐项询问，用户拒绝就保持基础安装。

唯一配置文件是 `~/Library/Application Support/ZaichangStandalone/connectors.json`。不存在即可正常使用；首建写 `{"schema":1}`。已有文件先读取、保留未修改字段，只合并获同意的项目，不整份覆盖。使用 UTF-8 JSON；路径可写绝对路径或 `~/`。修改后退出并重开应用；术语文件在运行中最长约一分钟刷新。配置文件不是密钥存放处，不提交到仓库。

### 项目资料目录

- **好处：** 助理对话与旁听知道在哪里查项目背景；暂停整理可识别本场项目的术语表。
- **先问：** “你希望助理查哪些项目文件夹？这些内容可以由你登录的 Codex 在回答中使用吗？”只选用户确认的目录，避免整个个人主目录。
- **写入：** `project_roots` 为目录数组，例如 `{"schema":1,"project_roots":["~/Documents/Projects"]}`。可加 `context_hint`，例如“先看项目上下文.md 和 README，历史纪要用于背景核对”；指引追加在通用提示之后，不改变会议事实的证据规则。
- **验证：** 确认目录实际存在；运行下面的检查，核对目录数量；重开应用后，请助理找一份用户指定的公开或可读文件并给出实际路径。不要把配置存在等同于模型已读到文件。

### 术语表

- **好处：** 暂停整理参考标准写法，降低跨项目同音词误改。实时识别不注入热词。
- **先问：** “哪些产品名、缩写已有确认写法？要不要在这个项目目录创建术语表？”只写有书面依据或用户确认过的词。
- **写入：** 项目表放在已配置目录下各项目的 `实体与术语.md`，不需要逐项目增加配置。跨项目通用表用 `general_terms` 指向一个文件。可在用户同意后创建模板：

   ```markdown
   # 实体与术语

   在正文记录来源、含义和待确认内容。

   ## 转写词表

   - 示例产品｜确认过的别名｜本项目确认过的误识写法
   ```

   每行 `标准写法｜别名｜常被误识为`，多项用 `、` 分隔，后两栏可省略。模板里的示例须替换为用户确认的写法，否则删除示例行。只有本场匹配项目层的“常被误识为”可作为精确纠正依据；通用层和人员层只提供标准写法与别名。不要猜读音、批量造词；应用只读，编辑由用户或获授权的 agent 完成。
- **验证：** 运行检查确认读取行数和无解析错误；必要时在 Python 中调用 `shared_terms.project_rows(已确认项目路径)` 核对层级。不要为了测试去录音或调用云服务。

### 人员表

- **好处：** 整理时能参考已确认姓名和别名；不会凭名字猜测声音是谁。
- **先问：** “要参考哪份人员文件？其中哪些姓名和别名已经确认？”
- **写入：** 使用同样的 `## 转写词表` 格式，将 `people_terms` 指向该文件，例如 `~/Documents/People.md`。人物层的误识栏不参与自动纠正。已有自有人员系统的用户可另接 `people_loader`，契约见 [架构](ARCHITECTURE.md#可选配置接口)；普通使用不需要 Python 人员加载器。
- **验证：** 检查人员层行数、解析错误为 0。人物候选搜索只有配置加载器才启用；没有加载器仍可手动纠正发言人、使用声音记忆。

合并字段后，在仓库根目录验证（只读本机配置，不调用模型）：

```sh
ZAICHANG_EDITION=standalone python3 scripts/check_connectors.py
```

输出只含路径存在性、层级数量和配置状态；未配置项显示关闭，非法配置返回错误。它验证读取链路，不证明云端整理效果。

### 让用户自己的 Codex 读取在场会议

- **好处：** 在自己的 Codex 对话中问“看看在场正在开的会”，按需只读当前会议，无需手动粘贴逐字稿。
- **先问：** “是否把本机在场的只读会议工具注册到你的 Codex？调用时会议文字会进入该对话的模型上下文。”用户同意才执行注册。
- **注册：** 此项配置属于 Codex MCP，不向 `connectors.json` 增加伪字段。先 `codex mcp get zaichang` 检查是否已有同名配置；已有配置先核对，改动需用户同意。在仓库根目录运行：

   ```sh
   codex mcp add zaichang --env ZAICHANG_EDITION=standalone -- python3 "$PWD/agent-plugin/zaichang/scripts/mcp_server.py"
   codex mcp get zaichang
   ```

   核对绝对脚本路径与 edition；保留仓库目录，移动后更新注册路径。其他 agent 使用同一 stdio 服务：命令 `python3`、参数为该脚本绝对路径、环境变量 `ZAICHANG_EDITION=standalone`。插件目录还包含 meeting-context Skill，可按客户端支持的插件方式安装；MCP 命令是本机直接可用的通路。
- **验证：** 重开 Codex 会话，实际调用 `zaichang.current_meeting`。空闲时应返回无当前会议；未装读取器会返回 unavailable，不能当作成功。活跃会议必须先获得用户授权，再核对返回的会话及 revision，用同一会话读原文。不要为验收启动录音。仅 `mcp get` 成功不证明工具可调用；本机成功也不证明云端 Chat 已连通。

## 排错

- **日志：** 构建目录 `.runtime/build/standalone/`，离线验收日志 `.runtime/standalone-review/`，连接检查 `.runtime/codex-connection/result.json`，助理启动日志在数据目录 `Assistant/runtime-startup.log`；分享前去除私人内容。
- **依赖下载失败：** 脚本会自动重试网络错误，已校验的文件下次复用，直接重跑 `python3 scripts/bootstrap_dependencies.py` 即可。若始终在 huggingface.co 失败而其他站点正常，多半是本机代理不通 Hugging Face：先用 `curl -I https://huggingface.co` 分别在开/关代理时测试，能直连就去掉代理环境变量重跑（例如 `env -u HTTPS_PROXY -u HTTP_PROXY python3 scripts/bootstrap_dependencies.py`）。
- **离线自检失败：** 重跑 `python3 scripts/offline_check.py --edition standalone`，查看首个失败项对应的日志，修复后重验，不跳过失败继续安装。
- **未授权麦克风：** 请用户到 macOS“系统设置 → 隐私与安全性 → 麦克风”开启在场，再重开应用；电脑声音按系统对应权限处理。
- **无密钥：** 请用户自己在在场设置中填写百炼密钥；agent 不索要密钥。
- **Codex 未登录：** 请用户自己运行 `codex login`，再执行连接检查。
