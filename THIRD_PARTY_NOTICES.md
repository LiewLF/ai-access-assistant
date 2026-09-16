# Third-party notices

AI接入助手整体采用 `AGPL-3.0-only`。

## CodexPlusPlus

`SessionCore` 的 Provider 可见标签同步、rollout 发现、Codex `threads` 分页和 SQLite 元数据修复基于以下上游改造：

- 项目：BigPizzaV3/CodexPlusPlus
- 版本：`v1.2.41`
- 提交：`3dafffcafb2566a1e8bce4b35671656d6adb3eda`
- 源码：<https://github.com/BigPizzaV3/CodexPlusPlus>
- 许可证：`AGPL-3.0-only`

上游版权归 BigPizzaV3 和 CodexPlusPlus 贡献者所有。改造范围和文件级说明见 `SessionCore/THIRD_PARTY_NOTICES.md`。

## SessionCore Rust 依赖

`SessionCore/Cargo.lock` 锁定完整直接与传递依赖版本。主要直接依赖：

| 组件 | 锁定版本 | 许可证 |
|---|---:|---|
| aes-gcm | 0.10.3 | Apache-2.0 OR MIT |
| base64 | 0.22.1 | MIT OR Apache-2.0 |
| libc | 0.2.186 | MIT OR Apache-2.0 |
| rusqlite | 0.32.1 | MIT |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.151 | MIT OR Apache-2.0 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 |
| thiserror | 2.0.19 | MIT OR Apache-2.0 |
| uuid | 1.24.0 | Apache-2.0 OR MIT |
| zeroize | 1.9.0 | Apache-2.0 OR MIT |

`rusqlite` 使用 `bundled` 特性构建 SQLite；SQLite 核心处于 public domain。精确版本以 `SessionCore/Cargo.lock` 为准，各组件版权与许可证仍归原作者所有。

本 source-only 连续源码快照（非 tag、非 Release） 不分发二进制。未来公开二进制前，必须生成并人工核对完整传递依赖版权与许可证材料。
