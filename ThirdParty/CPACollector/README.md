# CPA 取数上游

固定源码和精确归档身份见 `upstreams.json`。归档 SHA-256 用于确认重建采用同一上游输入；不扫描用户数据。两个 MIT 许可证随源码保留。

补丁使用零上下文 unified diff，必须先核对固定归档身份，不可用于其他版本；已逐文件回放比对为与已构建源码完全相同。

在对应干净源码根目录分别用 `patch -p1 < cpa-response-metadata.patch`、`patch -p1 < quota-response-metadata.patch` 应用补丁，然后沿用上游 Go 构建：CPA 为 `go build -mod=readonly -trimpath -buildvcs=false ./cmd/server`，插件为 `go build -mod=readonly -trimpath -buildvcs=false -buildmode=c-shared .`。实际已通过的构建使用 Go 1.26.8、GOMAXPROCS=2 和 -p=2；完整日志仍在私有开发证据目录。

补丁只将响应 model/service_tier 和六个 Token 字段是否真实出现的标记 经过现有 usage 和插件 ABI 传入 SQLite nullable 列。请求字段保留；不改计价，不把 unknown/auto 转成标准价。应用直接读取 raw usage_events，不消费插件 cost_usd。

运行时必须保留官方 CLI 自己生成的请求字段及原生请求头，配置 `codex.disable-codex-cloaking: true`；禁止手写 ultra 到其他 effort 的转换。请求只能进入经用户选择的本机采集线路，认证原件不交给 CPA 刷新。

使用 `Scripts/build-cpa-collector.py` 从已验证归档重建，参数指定 Go、两个归档、输出目录及缓存目录。脚本不下载、不认证；每次输出独立构建回执和日志，首个失败即停。

`build.sh` 通过 `AI_ACCESS_CPA_RUNTIME` 读取该输出，核对固定源码、当前补丁和二进制身份后嵌入资源并签名。开启 `commercial-mode: true` 直接复用上游禁止请求正文日志的开关。应用只在用户启用后启动本机采集，以不含 refresh token 的凭据副本认证，停止后清除副本。预检请求与正式启用后的覆盖区间分开。
