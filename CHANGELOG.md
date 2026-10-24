# Changelog

## Documentation — 2026-10-24

- 主页改为两条对等场景：别人的会从本机留下原文，开会时在同一场助理对话里旁听和追问。场景配图为标明的概念示意；产品界面证据仍是已标注的 0.3.0 真实截图。

## Documentation — 2026-10-23

- 更新主页的产品叙事与安装入口，并使用 0.3.0 原生界面重新制作明确标注的公开演示图。

## 0.3.0 — 2026-10-23

- 实时识别不再注入热词，避免把同音词误写成其他项目里的真实实体。
- 概览在后台持续更新，切换标签后继续整理本场讨论。
- 助理改为每场会议一个对话：开启“旁听”后，助理自己判断什么时候提醒、提醒什么，并可结合你配置的项目资料；你随时提问，它在同一对话里接着回答。助理会话不再写入 Codex 的会话列表。
- 修复暂停收尾状态与后台整理衔接。
- 支持导出原文和六部分会议纪要。
- 同一套源码通过可选 connectors.json 接入项目目录、术语、人员与资料指引；不配置也能使用基础功能。
- 首推 Agent 安装教程，逐步检查、安装、验收并引导可选增强。

## 0.2.0 — 2026-10-21

First public source release of 在场 for Apple Silicon Macs running macOS 15+.

- Record microphone and computer audio with local audio journals and interrupted-session recovery.
- Read live transcripts, correct speakers, and use optional local voice memory.
- Work with a native Codex assistant before, during and after a meeting; run independent tasks and opt in to proactive follow-up.
- Switch between assistant, meeting overview and notes in a resizable sidebar.
- Enable English-to-Chinese translation and export original text or structured meeting minutes.
- Provide local PDF, text or Markdown reference files for minutes generation.
- Build with pinned, verified upstream dependencies; install with independent user data and credentials.

See the README and installation guide for current requirements, permissions and limitations.
