# AI接入助手

AI接入助手是面向 macOS Codex Desktop 用户的本机接入、运行证据、故障解释与安全恢复工具。重点回答三件事：当前能否工作、失败后做什么、如何安全继续。

本项目不是 OpenAI 或 Codex 官方产品，也不代表任何第三方中转服务商。

## 当前发布状态

`source-snapshot` 是 **source-only 连续源码快照（非 tag、非 Release）**：只公开源码，不提供 DMG、App、ZIP 或其他可执行文件。

macOS 正式公开二进制仍被以下门槛阻断：Developer ID Application 签名、hardened runtime、secure timestamp、公证、stapling、Gatekeeper 验证，以及独立真实机器验收。不要把本仓库中的 ad-hoc 本机构建当作正式公开安装版。

Windows 目录保留原生源码目标和安全合同；Windows 11 x64 用户运行、安装器与分发身份仍未验证。

## 产品边界

- 默认本机处理；不设应用内遥测、广告追踪或云端会话索引。
- 普通浏览不自动发起模型请求，不读取 `auth.json`。
- 中转凭据只存入应用自有 Keychain 命名空间；联网或可能收费动作必须由用户明确触发。
- 配置与恢复动作先预览、再确认、再做受管字段写入；失败保留可恢复证据。
- 文件存在、HTTP 200、配置写入或界面显示不冒充真实任务可用。

完整边界见 [PRIVACY.md](PRIVACY.md) 与 [SOURCE-CODE.md](SOURCE-CODE.md)。

## 从源码首次使用 macOS App

要求：macOS 15 或更高版本、Apple Silicon、Apple Command Line Tools 或 Xcode。一个入口完成环境预检、锁定依赖准备、
独立目录源码构建、App 定位和首次使用说明：

```bash
python3 Scripts/first-use.py
```

首次获取锁定 Rust 工具链或依赖可能联网；只使用已有缓存时加 `--offline`。该入口复用
`Scripts/verify-source-build.py` 和仓库 `build.sh`，不会自动验证网络接入、写 Codex 配置、安装、启动或上传 App。

成功时输出 App 的仓库内相对路径，并写入可分享的 `build/first-use-diagnostic.json`。失败时只返回一个阶段、一个安全原因码、
一个首要动作和同一脱敏回执。回执不含用户名、完整 home 路径、token、端点、配置值、提示词、响应、项目内容或原始日志。
原始编译日志只留在 `build/first-use-runs/`，可能含本机路径，不应直接分享。

失败阶段区分：缺工具、版本不兼容、依赖获取、Rust 构建、Swift 构建、ad-hoc 签名和 App 产物定位。构建成功只证明
macOS arm64 源码可构建；macOS x86_64、Windows 11 x64、打包、安装、启动和 Gatekeeper 仍未验证，
`FAST_UNVERIFIED` 不改变。

## CPA 采集器运行时前置准备

本快照的 `build.sh` 在编译前要求 `AI_ACCESS_CPA_RUNTIME` 指向一个已构建的 CPA 采集器运行时。它由 `ThirdParty/CPACollector/upstreams.json` 固定的上游归档与本地 patch 重建，本仓库不下载归档、不安装 Go 工具链，`Scripts/first-use.py` 与 `Scripts/verify-source-build.py` 也不会代取这些依赖。

请先按 `ThirdParty/CPACollector/README.md` 准备固定版本的 Go 工具链和两个已校验归档，再运行：

```bash
python3 Scripts/build-cpa-collector.py --go <go>/bin/go \
  --cpa-archive <CLIProxyAPI tarball> --quota-archive <cpa-quota-estimator tarball> \
  --output <runtime-dir> --cache-root <cache-dir>
AI_ACCESS_CPA_RUNTIME=<runtime-dir> python3 Scripts/first-use.py
```

运行时缺失或回执不完整时，首次构建会在 `preflight` 阶段以 `cpa-runtime-missing` 或 `cpa-runtime-incomplete` 明确失败，不会静默跳过采集器。

## 首次启动与接入验证

1. 在 Finder 定位回执记录的 App，由你决定是否打开；脚本不会代替你启动。
2. 若 macOS 阻止启动，停止。不要运行 `xattr`、不要关闭或降低系统安全设置；ad-hoc 不等于 Developer ID 或公证。
3. App 首页“首次使用”先点“读取当前状态”。该步不改 Codex 配置、不联网。
4. 按首页唯一主动作确认基础连接；需要联网时 App 会再次确认。
5. 只有需要时再确认“验证真实任务”；可能计入官方额度或中转费用。
6. 失败时进入“高级诊断 > Codex诊断”。结果只给一个首要动作，也可由你主动导出脱敏求助包。

## 目录

- `Sources/`：macOS SwiftUI 应用与本机控制面
- `SessionCore/`：Rust 会话辅助组件
- `Windows/`：Windows 11 x64 原生源码目标
- `Scripts/`：最小源码构建脚本
- `Assets/`、`Configuration/`：图标和空生产更新公钥配置

## 许可证与第三方来源

项目采用 `AGPL-3.0-only`。完整条款见 [LICENSE](LICENSE)。第三方来源、固定上游版本和许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目名称和图标用于识别本项目。分支或再发布不得暗示 OpenAI、Codex 或原项目维护者为其背书。
