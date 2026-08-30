# 对应源码说明

本仓库公开 AI接入助手 `0.12.0 (178)` 的 source-only preview。内置 `SessionCore` 版本为 `0.11.0`，整体许可证为 `AGPL-3.0-only`。

## 本次公开内容

- macOS SwiftUI 产品源码：`Sources/`
- Rust 会话辅助组件：`SessionCore/`
- Windows 11 x64 原生源码目标：`Windows/`
- 图标、空生产更新公钥配置和跨平台合同
- 最小本机构建脚本、隐私说明、许可证与第三方声明

私有 Git 历史、私有 PR、Actions 历史、内部发布回执、安装备份、打包 attempt、DMG、App、ZIP 和其他二进制不在本仓库。

## 从源码构建

```bash
./Scripts/bootstrap-rust-toolchain.sh
AI_ACCESS_TARGET_ARCH=arm64 ./build.sh
```

构建要求 macOS 15 或更高版本、Apple Silicon、Apple Command Line Tools 或 Xcode。Rust 工具链由 `SessionCore/rust-toolchain.toml` 固定，Rust 依赖由 `SessionCore/Cargo.lock` 锁定。Swift 编译输入由 `Scripts/swift-source-manifest.tsv` 中 `build.sh` 标签固定。

输出是本机 ad-hoc 签名的 `build/AI接入助手.app`。构建脚本不生成 DMG、不安装、不上传，也不提供 Gatekeeper 绕过命令。

## 分发状态

本预览没有公开二进制。`macos_public_release_ready=false`：Developer ID Application、hardened runtime、secure timestamp、公证、stapling、Gatekeeper 和独立真实机器验收尚未完成。

`Configuration/TrustedUpdatePublicKeys.json` 当前为空；没有生产更新信任链，不提供自动更新承诺。

Windows 目录是源码目标。Windows 11 x64 用户运行、安装器和公开分发身份仍未验证，macOS 源码或本机构建不能替代这些证据。

若未来公开二进制，必须同时提供精确对应、可构建的完整源码和第三方许可证材料，并重新验证上述分发门。
