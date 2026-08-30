# Windows 原生源码目标

本目录保留 AI接入助手 Windows 11 x64 原生源码和确定性安全合同。它不复用 macOS Keychain、路径、权限或进程实现。

当前状态：源码预览。C#、XAML、SessionCore Windows 目标和只读合同曾在固定 Windows runner 上验证；本次公开镜像未重新运行 Windows CI，Windows 11 用户旅程、安装器和分发身份仍未验证。

## 源码门

```powershell
dotnet restore Windows/AIAccessAssistant.Windows.slnx
dotnet build Windows/AIAccessAssistant.Windows.slnx -c Release --no-restore -p:PlatformTarget=x64 -p:WindowsPackageType=None -p:GenerateAppxPackageOnBuild=false
dotnet run --project Windows/tests/AIAccessAssistant.Core.ContractTests -c Release --no-build
rustup target add x86_64-pc-windows-msvc
cargo check --manifest-path SessionCore/Cargo.toml --all-targets --target x86_64-pc-windows-msvc
pwsh Windows/scripts/verify-native-source-gate.ps1
```

该流程只编译和检查源码，不生成或上传安装包。

## 安全边界

- 普通启动不读取凭据、不启动 Codex、不联网、不切换、不执行收费任务。
- 中转凭据限应用自有 Windows Credential Manager 命名空间。
- 配置变更要求脱敏预览、显式确认、命名互斥锁、同目录持久暂存和可验证备份。
- 助手不自动关闭用户进程，不自动重试歧义写入，不提权或修改 ACL。
- macOS 构建和证据不能替代 Windows 11 x64 运行证据。
