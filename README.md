# SideBrief · 侧读

**给使用 Codex 的独立工作者，每天一点值得看的新进展。**

一个原生 macOS 资讯悬浮窗。它在本机采集公开资讯，调用用户已登录的 Codex 生成中文精选，在屏幕右上角安静地展示。可以收进右侧边缘，点击标签展开。

![SideBrief 实际运行界面](docs/images/sidebrief.jpg)

## MVP 能做什么

- 3–5 条精选、简讯和有证据的项目跟踪；资料不足时宁可少选。
- 默认关注 AI、开源项目、自动化、软硬件结合和个人知识库。
- 点击标题在默认浏览器打开原始来源。
- 单独复制研究指令，粘贴到 Codex 后继续了解。
- 默认北京时间 08:00 更新；时间、时区、兴趣和来源均可修改。
- 离线阅读已保存的内容；联网或唤醒后补更。
- 有效结果才写入历史；失败保留上一期，有限重试，避免重复消耗额度。
- 自定义公开 HTTPS RSS/Atom，便于 Fork 后定制其他主题。

当前 **0.1.0 MVP 仅接入本机 Codex**。API Key 接入、多主题独立日报、云端运行和其他平台属于后续扩展。

## 开始使用

### 运行条件

- macOS 14 或更新版本。
- 已安装并登录支持 `codex exec --ignore-user-config --output-schema` 的 Codex CLI。设置中可选择可执行文件路径。
- 联网时生成资讯，调用会占用 Codex 的可用额度。应用不会替用户购买额度或切换到另一个收费接口。

CLI 安装与登录请使用 [Codex 官方文档](https://learn.chatgpt.com/docs/cli)。本机 Codex 应能正常运行 `codex login status`。

### 下载预览版

从 [v0.1.0 MVP 发布页](https://github.com/HeartY1ng/SideBrief/releases/tag/v0.1.0) 下载 `SideBrief-0.1.0-macOS-arm64.zip`，解压后打开 `SideBrief.app`。安装包适用于 Apple Silicon Mac，使用本地 ad-hoc 签名，尚未经过 Apple Developer ID 签名与公证；macOS 可能阻止首次打开。你也可以按下方步骤从源码构建。

### 从源码构建

安装 Swift 6 工具链（Xcode 或包含 Swift 6 的 Command Line Tools）：

```sh
git clone https://github.com/HeartY1ng/SideBrief.git
cd SideBrief
./scripts/test.sh
./scripts/build.sh
```

构建产物：

```text
dist/SideBrief.app
dist/SideBrief-macOS.zip
```

双击 `SideBrief.app`。第一次打开，检查 Codex 连接并点击“生成第一期”。更新完成后即可点击收起到屏幕侧边。菜单栏也可显示小窗、打开设置或退出。

构建默认使用本机 CPU 架构。当前开发验收使用 Apple Silicon；Intel 和更多 macOS 版本仍需设备验证。脚本做本地 ad-hoc 签名，不等于 Apple Developer ID 签名或公证。向公众分发的正式安装包应另行完成签名与公证；仓库不包含开发者证书。

## 日常行为

- 应用运行且 Mac 醒着、联网时才执行任务；关机和休眠期间不执行。
- 08:00 是可修改的默认值，时区默认 `Asia/Shanghai`，不随系统时区悄悄变化。
- 同一时区日期、计划时间之后已成功更新，当天不再自动生成；计划时间之前手动生成不影响早晨更新，主动点刷新也可以重新生成。
- 失败重试间隔为 5、15、30、60 分钟；每天最多自动尝试 3 次模型生成。额度、登录或配置问题可排查后手动重试。
- 无值得新增的内容时，显示“本期没有值得新增的精选”，并记录为成功更新。
- 更新时可以取消。取消后保留上一期，并暂缓自动重试。
- 原始发布时间缺失时明确显示“发布时间未提供”；仓库的创建日期不冒充最新版本发布日期。
- 来源不可用时，其他来源仍可继续。每份日报底部可以展开来源状态。

登录启动可以通过 macOS 的“登录项”自行添加 SideBrief；本版本不会替用户修改登录项。

## 数据与费用

默认数据目录为 `~/Library/Application Support/SideBrief/`：

```text
settings.json       兴趣、来源、更新时间和 Codex 路径
latest.json         最新一期的便捷副本
history/            最近 30 份成功结果
retry.json          重试状态与每日尝试计数
generation.lock     防止同时生成的进程锁
```

应用直接请求公开资讯源，把候选文本、用户填写的兴趣和最近日报摘要交给 Codex。**AI 生成通常仍使用联网模型**；“本机运行”指采集、调度、保存和窗口在本机。

SideBrief 不读取用户的知识库或聊天记录，不读取、复制或上传 Codex 认证文件，也不内置开发者的 API Key。Codex 自行使用现有登录。为隔离资讯内容，生成任务不加载用户自定义 Codex 配置或 AGENTS.md，使用 CLI 默认模型和只读沙盒，并禁用可检测的执行、插件、浏览器等工具功能。自定义模型服务商配置暂不属于首版支持范围。

每条链接由采集程序回填，模型只能选择已提供的候选 ID。AI 归纳仍应结合原文判断；推荐理由不是项目实测报告。

## 定制

通过“设置”修改关注方向，启用、关闭或添加来源即可调整内容。扩展其他主题时，**同时更换兴趣和资讯源**，只改主题名称不会自动取得新领域的资料。

- [来源说明](docs/SOURCES.md)
- [定制指南](docs/CUSTOMIZATION.md)
- [架构说明](docs/ARCHITECTURE.md)
- [验收清单](docs/UX-CHECKLIST.md)
- [验证记录](docs/VALIDATION.md)

## 开发检查

```sh
# 不调用模型
.build/debug/SideBrief --check-codex
.build/debug/SideBrief --check-feeds --data-dir ./test-output/check

# 调用真实 Codex，会使用已有额度；适合手动端到端检查
.build/debug/SideBrief --generate-once --data-dir ./test-output/real

# 明确标记的演示界面，不调用模型
.build/debug/SideBrief --demo --data-dir ./test-output/demo
```

自动测试使用临时目录和假的 Codex 可执行文件，不访问真实账号、不使用模型额度。联网测试需要显式设置 `SIDEBRIEF_VERIFY_LIVE_NETWORK=1`。默认 CI 执行离线测试及构建。

## 贡献与许可

欢迎反馈安装、连接、资讯质量和窗口体验问题。提交 Issue 时请提供系统版本、Codex 版本和复现步骤，移除密钥、私人来源地址和账号信息。

[MIT License](LICENSE)。
