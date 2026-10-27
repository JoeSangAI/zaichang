# Changelog

## Fixes — 2026-10-27

- 外放回声不再变成第二份发言：麦克风收到扬声器里的远端声音时，按回声消除的能量比和本场麦克风说话人的声音判断，阅读与导出隐藏这份重复，“查看原稿”仍完整保留。
- 同一句话里被切碎的语气词和重叠瞬间，前后是同一人时并回此人；人工标注、回声和明确属于他人的声音仍会阻止合并。回声和并回片段不进入声纹识别与学习样本。
- 已有归属的重叠小片段不再让整轮发言显示为“多人重叠”。
- 发言人面板的姓名框可下拉选择本场已有发言人：在“其他发言”里选中即归入此人，在人物视图里选中即合并，避免同一人被输入成两个名字。
- 删除没有入口的“从所选历史原音学习”整条旧链路及其校验。

## Fixes — 2026-10-26

- 改进发言人整理：保留未被独立证据否定的原分组，使用人工确认参考恢复短发言，并明确显示已知双方同时发言。
- 声纹匹配使用完整合格人工参考，避免较早的录音环境样本被有限展示集合挤出；局部连续语音恢复不会反过来成为学习样本。
- “其他发言”按所属原句合并展示，补充只读上下文，保留待确认标记和原有归属边界。
- 自动标题增加正文语境校验，避免孤立识别碎词成为业务主体；长会议摘录避免重复取样。
- 助理显示工作进度与停止入口，用户交办支持受控执行、确认及问题表单；图片按正文顺序展示，支持复制和另存为。
- 修复笔记定时刷新干扰输入和光标的问题，并稳定离线验收中的文件刷新与测试数据隔离。

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
