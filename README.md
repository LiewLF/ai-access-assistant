# AI接入助手

AI接入助手是面向 macOS Codex Desktop 用户的本机接入、运行证据、故障解释与安全恢复工具。重点回答三件事：当前能否工作、失败后做什么、如何安全继续。

本项目不是 OpenAI 或 Codex 官方产品，也不代表任何第三方中转服务商。

## 当前发布状态

`v0.12.0-preview.1` 是 **source-only preview**：只公开源码，不提供 DMG、App、ZIP 或其他可执行文件。

macOS 正式公开二进制仍被以下门槛阻断：Developer ID Application 签名、hardened runtime、secure timestamp、公证、stapling、Gatekeeper 验证，以及独立真实机器验收。不要把本仓库中的 ad-hoc 本机构建当作正式公开安装版。

Windows 目录保留原生源码目标和安全合同；Windows 11 x64 用户运行、安装器与分发身份仍未验证。

## 产品边界

- 默认本机处理；不设应用内遥测、广告追踪或云端会话索引。
- 普通浏览不自动发起模型请求，不读取 `auth.json`。
- 中转凭据只存入应用自有 Keychain 命名空间；联网或可能收费动作必须由用户明确触发。
- 配置与恢复动作先预览、再确认、再做受管字段写入；失败保留可恢复证据。
- 文件存在、HTTP 200、配置写入或界面显示不冒充真实任务可用。

完整边界见 [PRIVACY.md](PRIVACY.md) 与 [SOURCE-CODE.md](SOURCE-CODE.md)。

## 从源码构建 macOS App

要求：macOS 15 或更高版本、Apple Silicon、Apple Command Line Tools 或 Xcode。首次获取锁定 Rust 依赖需要联网。

```bash
./Scripts/bootstrap-rust-toolchain.sh
AI_ACCESS_TARGET_ARCH=arm64 ./build.sh
```

输出位于 `build/AI接入助手.app`。脚本只做本地 ad-hoc 签名，不生成 DMG，不上传，不安装，也不绕过 Gatekeeper。

## 目录

- `Sources/`：macOS SwiftUI 应用与本机控制面
- `SessionCore/`：Rust 会话辅助组件
- `Windows/`：Windows 11 x64 原生源码目标
- `Scripts/`：最小源码构建脚本
- `Assets/`、`Configuration/`：图标和空生产更新公钥配置

## 许可证与第三方来源

项目采用 `AGPL-3.0-only`。完整条款见 [LICENSE](LICENSE)。第三方来源、固定上游版本和许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目名称和图标用于识别本项目。分支或再发布不得暗示 OpenAI、Codex 或原项目维护者为其背书。
