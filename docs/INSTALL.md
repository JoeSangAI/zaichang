# 在 macOS 上安装

目前提供源码安装。需要一台 Apple Silicon Mac、macOS 15 或更新版本、Python 3.12、Xcode Command Line Tools 和 Swift 6。Codex 助理还需要安装并登录 Codex CLI。

也可直接请你的 agent 按 [AGENT_SETUP.md](AGENT_SETUP.md) 安装。

## 首次安装

1. 安装 Python 3.12。若本机没有合适版本，可从 [Python for macOS](https://www.python.org/downloads/macos/) 下载 Python 3.12 的 universal2 安装器。
2. 安装 Xcode Command Line Tools。若尚未安装，在终端运行 `xcode-select --install` 并按 macOS 提示完成。
3. 安装并登录 [Codex CLI](https://developers.openai.com/codex/cli/)。终端可运行官方安装命令，之后运行 `codex` 并选择登录方式：

   ```sh
   curl -fsSL https://chatgpt.com/codex/install.sh | sh
   codex
   ```

4. 先从仓库首页克隆本仓库，然后在终端运行以下命令。`requirements.txt` 会先安装依赖下载器所需的证书包，以及说话人辅助工具需要的 NumPy；随后下载并校验约 570 MB 的锁定依赖，最后构建、运行离线自检并安装应用：

   ```sh
   cd zaichang
   python3 --version
   swift --version
   python3 -m pip install -r requirements.txt
   python3 scripts/bootstrap_dependencies.py
   python3 scripts/install_standalone.py
   ```

   确认 `python3 --version` 显示 3.12，`swift --version` 显示 Swift 6。首次下载的模型和 SDK 会保存在仓库的忽略目录中；再次运行时会复用哈希匹配的文件。构建与自检不启动录音，也不调用转写服务。

应用安装到 `~/Applications/在场.app`，会议数据保存在 `~/Library/Application Support/ZaichangStandalone`。这份安装使用独立数据目录和应用设置，不会替换其他版本的在场。首次启动时，macOS 会在你启用相应声音来源时请求权限；只有按下应用里的“开始录音”后才会开始录音。

源码构建使用本机临时签名，不包含 Apple Developer ID 签名或公证。应用更新通过拉取新源码并重新运行安装脚本完成，不会自动更新。

转写需要你在应用中配置自己的语音服务凭据。Codex 助理使用你已登录的 Codex CLI 账号和本机权限；Codex 能访问的项目文件取决于该账号和当前机器的配置。

## 更新

在已克隆的仓库目录中运行：

```sh
git pull
python3 -m pip install -r requirements.txt
python3 scripts/bootstrap_dependencies.py
python3 scripts/install_standalone.py
```

安装器更新你已有的那份在场（`~/Applications` 或 `/Applications`，没有时装到 `~/Applications`），并保留 `ZaichangStandalone` 数据目录。若当前在场仍在运行，请先退出应用再更新。

## 依赖下载失败

安装 Python 依赖时若出现 `CERTIFICATE_VERIFY_FAILED`，运行 Python 安装目录里的 `Install Certificates.command`（例如 `open "/Applications/Python 3.12/Install Certificates.command"`）后重试。

下载脚本会自动重试网络错误，已校验的文件再次运行时复用，直接重跑即可。若始终在 huggingface.co 失败而其他站点正常，通常是本机代理无法访问 Hugging Face：能直连时可去掉代理环境变量重跑，例如 `env -u HTTPS_PROXY -u HTTP_PROXY python3 scripts/bootstrap_dependencies.py`。

## 自检

如果只需要验证已构建的离线测试应用，可运行：

```sh
python3 scripts/offline_check.py --edition standalone
```

修改源码后，另运行 Python 测试套件：

```sh
python3 -m unittest discover -s tests -t .
```

安装脚本本身会先完成构建和离线自检。依赖来源、固定版本和许可证见[依赖与许可证](DEPENDENCIES.md)。
