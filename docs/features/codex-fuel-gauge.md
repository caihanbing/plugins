# 油表盘插件

<!-- feature-id: codex-fuel-gauge -->
<!-- feature-title: 油表盘插件 -->
<!-- feature-aliases: Codex Fuel Gauge, 油表盘, Codex 用量油表 -->
<!-- feature-status: active -->
<!-- feature-summary: 登录后常驻显示 Codex 额度与本机 CPU、内存、网络实时状态及应用 Top 5 的菜单栏悬浮仪表台。 -->
<!-- last-verified: 2026-09-12 -->
<!-- code-basis: HEAD unborn; working-tree=dirty -->

## 快速上下文

“油表盘插件”当前实现为一个独立的 macOS 菜单栏辅助应用 `Codex Fuel Gauge`，不是注入 Codex 的内部插件。应用通过登录项在用户登录 macOS 后启动并立即显示统一悬浮仪表台；系统指标持续采样，Codex 额度通过 Codex 自带的 `app-server --stdio` 获取，Codex 启停只影响额度区域，不再影响面板可见性。

入口是 `AppDelegate` 创建的 `NSStatusItem` 和 `NSPanel`。额度和系统指标快照只保存在内存，窗口位置、首次登录项注册尝试、用户禁用标记和 Top 5 当前指标保存在 `UserDefaults`；临时签名环境的登录项 fallback 写入用户级 `~/Library/LaunchAgents/com.codexfuelgauge.app.plist`。应用不读取或复制 `~/.codex/auth.json`，也不包含服务端部署组件。构建目标为 macOS 14+，本地打包产物位于 `codex-fuel/dist/CodexFuelGauge.app`。

## 目标与边界

### 目标

- 展示当前 Codex 账户额度窗口的剩余百分比；单窗口使用汽车油表，多个窗口使用带窗口标签的并排额度卡。
- 登录后持续展示 CPU、内存、网络总览及按 CPU/内存/网络切换的应用 Top 5。
- 在 Codex 启动、退出和连接异常时同步额度区域及菜单栏状态，不改变系统仪表台生命周期。
- 兼容 App Server 返回的单额度桶、多额度桶以及 `primary`/`secondary` 窗口。
- 支持菜单栏操作、手动刷新、重新连接、登录项开关和窗口位置记忆。
- 支持 1 秒前台/5 秒隐藏系统采样、外观跟随系统、应用图标和无 bundle 进程回退显示。
- 生成本机可安装的临时签名 `.app`，不依赖完整 Xcode 工程。

### 范围内

- `SMAppService` 登录项启动（合法签名）或用户级 LaunchAgent fallback（临时签名），以及 `NSWorkspace` 对 Codex 运行状态的监听和已有进程检查。
- 使用 Codex App Server 的 JSONL stdio 连接完成初始化、额度读取和实时通知处理。
- 30 秒轮询、12 秒单次读取超时、2/5/15/30/60 秒退避重连，以及最后有效快照保留。
- 使用 Darwin 公共接口读取整机 CPU、内存和非回环网卡计数；使用 `/usr/bin/nettop` 读取应用网络增量。
- 按最外层 `.app` 聚合 Helper 进程；无法归属 bundle 的系统进程按进程名聚合。
- 单窗口主油表使用有效窗口中最低的剩余百分比；5 小时/7 天同时存在时主区域按时长升序并排显示全部窗口卡，每张卡直接显示额度桶、窗口长度和重置倒计时。
- 剩余量 `>30%` 为绿色、`11–30%` 为橙色、`≤10%` 为红色；额度无数据时显示灰色 `--`。
- 无 Dock 图标的菜单栏应用、跨 Space 的置顶可拖动面板、420pt 宽统一布局、面板位置持久化和登录项注册。

### 范围外

- 不实现 Codex 内部扩展点、MCP 插件、IDE 插件或 Codex UI 注入。
- 不读取、存储、刷新或代理 ChatGPT/Codex 凭据，不支持 API key 输入和多账户切换。
- 不提供服务器、数据库、消息队列、远程监控、自动更新、Developer ID 公证、DMG 分发或 Mac App Store 上架。
- 不计算独立 token 成本，不发送系统通知，也不提供自定义低额度阈值。
- 不提供历史曲线、磁盘/GPU/温度监控、网络连接详情或管理员权限扩展。

### 不变量

- 只展示当前用户通过本机 Codex App Server 可访问的额度，不从本地会话日志推算用量。
- 主油表值始终由当前内存快照中最小的 `remainingPercent` 决定；`remainingPercent` 会被限制在 `0…100`。
- App Server 子进程的读写在专用串行队列中执行，UI 状态更新在主 actor 上执行。
- 系统采样在独立串行队列执行，单项系统指标失败不能阻断其他指标。
- 退出 Codex 后只停止 App Server、清空额度快照并显示等待状态；悬浮面板继续可见，系统采样继续运行。

## 业务行为

- 用户登录 macOS 后应用自动启动，菜单栏图标常驻并立即显示统一仪表台；Codex 未运行时额度区域显示“等待 Codex 启动”，CPU/内存/网络继续更新。
- 应用启动时会检查已有的 `com.openai.codex` 进程；若已运行则建立 App Server 连接，但不会改变面板当前可见性。
- 额度读取成功后，菜单栏按窗口时长升序显示百分比（例如 `73% | 91%`）；单窗口悬浮窗显示油表，双窗口悬浮窗显示带 `5 小时窗口`/`7 天窗口` 标签的额度卡、套餐标签、连接状态、系统总览和可切换的应用 Top 5。
- 点击菜单栏可以显示/隐藏油表、刷新或重连 Codex；隐藏面板后系统采样降为每 5 秒，Codex 启动不会强制重新显示。
- Codex 终止通知到达后，应用取消待执行的额度重连、停止 App Server、清空额度快照并回到“等待 Codex 启动”，面板保持可见。
- 首次启动会尝试注册为登录项；合法签名使用 `SMAppService.mainApp`，状态为 `notFound` 的临时签名环境写入用户级 LaunchAgent；如果状态为 `requiresApproval`，菜单栏提供打开系统登录项设置的入口。环境变量 `CODEX_FUEL_GAUGE_DISABLE_LOGIN_ITEM=1` 仅用于冒烟测试时跳过自动注册。
- Codex 可执行文件优先从 bundle identifier 对应应用的 `Contents/Resources/codex` 定位，其次尝试固定的 ChatGPT 应用路径、用户 `Applications` 路径、`/opt/homebrew/bin/codex` 和 `/usr/local/bin/codex`。
- 系统指标采样前台每秒、隐藏每 5 秒；网络 Top 5 使用 `/usr/bin/nettop -P -L 1 -d -x -n -s <interval> -J bytes_in,bytes_out`，每个子进程输出一个包含当前采样周期增量的 CSV block 后按采样间隔重启；网络排行按 PID 直接挂接该周期增量，不把 `-d` 字段当作累计计数器。

## 架构与代码地图

- `codex-fuel/Sources/CodexFuelGauge/AppDelegate.swift` — `AppDelegate`：创建 `NSApplication`、菜单栏 `NSStatusItem`、`FloatingPanelController`，按额度窗口顺序更新菜单栏百分比标题并将菜单动作转发给 `AppModel`。
- `codex-fuel/Sources/CodexFuelGauge/AppModel.swift` — `AppModel`：主 actor 状态容器，协调生命周期、连接状态、30 秒刷新、退避重连、面板可见性和登录项。
- `codex-fuel/Sources/CodexFuelGauge/SystemMetricsModels.swift` — `SystemMetricKind`、进程/应用快照、应用身份、Top 5 排序和 `nettop` CSV 解析。
- `codex-fuel/Sources/CodexFuelGauge/SystemMetricsSampler.swift` — `SystemMetricsSampler`、Darwin provider、CPU/内存/网卡读取、系统快照和网络重连。
- `codex-fuel/Sources/CodexFuelGauge/NetTopClient.swift` — `NetTopClient`、`NettopCSVBlockFramer`：管理按周期运行的 `nettop` 子进程及 CSV 分块。
- `codex-fuel/Sources/CodexFuelGauge/LaunchAgentController.swift` — `LaunchAgentController`、`LaunchAgentPlistBuilder`：在 ad-hoc 签名环境中管理用户级 RunAtLoad fallback。
- `codex-fuel/Sources/CodexFuelGauge/CodexLifecycleMonitor.swift` — `CodexLifecycleMonitor`：订阅 `NSWorkspace` 启动/退出通知，并以 bundle identifier 判断当前运行状态。
- `codex-fuel/Sources/CodexFuelGauge/CodexBinaryLocator.swift` — `CodexBinaryLocator.locate()`：根据 Codex 应用 bundle 和固定 fallback 路径寻找可执行文件。
- `codex-fuel/Sources/CodexFuelGauge/CodexAppServerClient.swift` — `CodexAppServerClient`：启动 `Process`、管理 stdin/stdout/stderr `Pipe`、发送 JSONL 请求、解析响应和报告断连。
- `codex-fuel/Sources/CodexFuelGauge/AppServerMessageParser.swift` — `AppServerMessageParser.parse(_:)`：把 JSON 行转换为初始化、额度响应、额度更新、错误或忽略事件。
- `codex-fuel/Sources/CodexFuelGauge/JSONLFramer.swift` — `JSONLFramer`：处理分片输入、换行和 CRLF，输出完整 JSON 行。
- `codex-fuel/Sources/CodexFuelGauge/RateLimitModels.swift` — `QuotaWindow`、`LimitBucket`、`RateLimitsResult`、`RateLimitSnapshot`：额度解码、窗口时长排序、单/双窗口菜单栏格式和部分更新合并。
- `codex-fuel/Sources/CodexFuelGauge/GaugeView.swift` — `GaugeRootView`、`QuotaWindowOverview`、`QuotaWindowCard`、`SystemMetricCard`、`SystemApplicationRow`、`GaugeDial`：方案 A 统一 SwiftUI 仪表台。
- `codex-fuel/Sources/CodexFuelGauge/FloatingPanelController.swift` — `FloatingPanelController`：配置 420pt 无边框置顶 `NSPanel`、跨 Space 行为、拖动和高度上限。
- `codex-fuel/Package.swift` — macOS 14+ 可执行目标及 Swift Testing 测试目标；测试目标额外链接本机 Command Line Tools 的 `Testing.framework`。
- `codex-fuel/Packaging/Info.plist` — `LSUIElement=true`、bundle identifier `com.codexfuelgauge.app` 和最低系统版本。
- `codex-fuel/scripts/test.sh`、`codex-fuel/scripts/package_app.sh`、`codex-fuel/scripts/install_local.sh` — 兼容当前 Swift/SDK 补丁版本的测试、打包和用户目录安装入口。

## API、事件与任务

### `codex app-server --stdio`

- **输入**：由 `CodexAppServerClient` 启动可执行文件并传入 `app-server --stdio`；随后发送逐行 JSON 对象。
- **初始化契约**：发送 `initialize`（请求 ID `0`，包含 `clientInfo.name=codex_fuel_gauge`、标题和版本），再发送 `initialized` 通知。
- **输出**：stdout 的每一行进入 `JSONLFramer` 和 `AppServerMessageParser`；stderr 被持续读取并丢弃，避免管道阻塞。
- **错误**：进程启动、写入、读取超时、解析失败和非正常退出均通过 `onDisconnected` 传给 `AppModel`。
- **兼容性**：使用官方 App Server 的 stdio JSONL 传输；应用不使用实验性的 WebSocket 监听。

### `account/rateLimits/read`

- **输入**：无参数 JSON-RPC 请求，初始化后发送，手动刷新和 30 秒定时器会再次发送；每次请求使用单调递增的整数 ID。
- **输出**：读取 `result.rateLimits` 兼容单桶视图，或 `result.rateLimitsByLimitId` 多桶视图；每个桶可包含 `primary`、`secondary`、`credits`、`planType` 和重置状态。
- **消费者**：`CodexAppServerClient` 转换为 `RateLimitSnapshot`，`AppModel` 替换当前内存快照并将连接状态设为 `connected`。
- **错误与超时**：请求进入 pending 集合，12 秒后仍未返回则停止当前连接并触发退避重连。

### `account/rateLimits/updated`

- **输入**：App Server 在同一 stdout 流上发送的通知，当前解析 `params.rateLimits` 单个桶。
- **输出**：通知被转换为 `LimitBucket`，并在现有快照上合并；更新中省略的窗口长度、重置时间、套餐、credits 等字段保留已有值。
- **兼容性**：未知 JSON 字段由 `Codable` 忽略；无法解码的通知转为连接错误状态。

### `CodexLifecycleMonitor.onRunningChanged`

- **主题**：`Bool`，表示是否至少存在一个 bundle identifier 为 `com.openai.codex` 的运行应用。
- **生产者**：`NSWorkspace.didLaunchApplicationNotification`、`NSWorkspace.didTerminateApplicationNotification` 和启动时的运行应用扫描。
- **消费者**：`AppModel.handleCodexRunningChanged(_:)`；`true` 启动额度连接，`false` 停止连接并清空额度，面板和系统采样保持运行。

### 后台刷新与重连任务

- **刷新**：`AppModel` 创建 30 秒重复 `Timer`；运行中调用 `client.refresh()`，快照超过 90 秒未更新时标记为 stale。
- **重连**：连接错误后使用 `DispatchWorkItem` 按 2、5、15、30、60 秒延迟重试，之后保持 60 秒上限；Codex 退出或手动重连时取消当前任务。
- **系统采样**：`SystemMetricsSampler` 在独立串行队列中按 1/5 秒采样，`NetTopClient` 异常时按 2/5/15/30/60 秒独立重启；应用睡眠唤醒后清除差值基线。
- **外部副作用**：启动/终止本地 App Server 和 `nettop` 子进程、读取 Codex 上游额度、读取 Darwin 系统计数、注册/注销 SMAppService 或写入/移除用户级 LaunchAgent；没有应用内持久化任务队列。

## 数据模型与迁移

- `QuotaWindow` 保存 `usedPercent`、`windowDurationMins` 和 Unix 秒级 `resetsAt`，计算并限制 `remainingPercent`。
- `LimitBucket` 保存桶标识、显示名称、primary/secondary 窗口、credits、套餐和限额状态；`merging(_:)` 用于处理字段不完整的实时通知。
- `RateLimitsResult` 对应一次 `account/rateLimits/read` 返回；`RateLimitSnapshot` 把多桶结果归一到内存字典，并生成可排序的 `WindowEntry` 列表。
- 持久化只使用 `UserDefaults` 的 `floatingPanelOrigin`、`didAttemptInitialLoginItemRegistration` 和 `selectedSystemMetric`；额度/系统快照、pending 请求和重连计数均不落盘。
- 当前没有数据库、迁移、索引、外键或数据回填；Codex 的认证和额度数据由外部 App Server 管理。
- `Codable` 默认忽略新增字段；缺失的可选字段显示为未知/不适用，保持对未来额度桶字段的读取兼容。

## 核心流程

1. `AppDelegate.applicationDidFinishLaunching` 设置 accessory activation policy，创建面板和菜单栏项，随后调用 `AppModel.start()`。
2. `AppModel` 注册 `CodexLifecycleMonitor`、读取登录项状态并按首次启动规则选择 `SMAppService.mainApp` 或用户级 LaunchAgent，显示面板并启动系统采样和 30 秒额度定时器。
3. 监测到 Codex 已运行或收到启动通知后，`AppModel.connect()` 调用 `CodexBinaryLocator.locate()`，设置 `connecting` 并要求 `CodexAppServerClient` 启动子进程；面板可见性不变。
4. 客户端在串行队列中发送初始化握手和 `account/rateLimits/read`；完整 JSON 行进入解析器，初始化成功更新连接状态，额度响应替换 `RateLimitSnapshot`。
5. `SystemMetricsSampler` 发布 CPU、内存、网卡总速率和应用聚合快照；SwiftUI 在方案 A 中重绘三张总览卡和所选 Top 5。
6. `AppModel` 在主 actor 上合并额度/系统状态；手动刷新或实时通知更新额度，系统采样异常只影响对应来源并显示过期/不可用状态。
7. Codex 终止后取消额度重连、停止 App Server、清空额度快照并回到等待状态；面板继续显示系统仪表台。

## 异常与边界条件

- 找不到可执行文件 — 进入 `unavailable("未找到 Codex 可执行文件")` 并按退避计划重试 — 依赖 Codex 应用 bundle 或 fallback CLI 路径存在。
- App Server 启动/写入失败 — 停止当前客户端并显示不可用或 stale 消息 — 由 `AppModel` 安排下一次连接。
- 额度读取超过 12 秒 — 清除 pending 请求、终止客户端并重连 — 当前快照保留；没有快照时油表显示 `--`。
- App Server 非正常退出 — termination handler 通过 `onDisconnected` 报告退出码 — 连接状态标记为 stale/unavailable。
- 返回无效 JSON 或不兼容额度字段 — 解析器产生错误事件 — 不更新快照，进入重连流程。
- 只有 `rateLimitsByLimitId` 或只有单桶返回 — `RateLimitSnapshot` 优先使用非空多桶字典，否则退回单桶 `rateLimits` — 无有效桶时主值为 nil。
- `usedPercent` 超出 `0…100` — 剩余百分比被限制在 `0…100` — 防止油表指针和颜色越界。
- 只有一个窗口、缺少 secondary、credits 或 reset 时间 — 额度卡只展示已存在字段，其余显示“未知”或不显示 — 不阻断主油表。
- 实时通知省略已有字段 — 桶合并逻辑保留现有窗口元数据和套餐 — 当前只更新通知携带的新值。
- 登录项状态为 `requiresApproval` — 菜单提供系统设置入口 — 需要用户在 macOS 设置中批准，代码不会绕过系统权限。
- 用户手动隐藏面板 — `panelVisible` 变为 false，当前运行期间 Codex 启动不会强制显示，系统采样降为 5 秒 — 下次应用启动时恢复默认显示。
- `nettop` 启动失败或异常退出 — 网卡总速率仍可用，网络 Top 5 显示不可用原因并按退避计划重启 — 不请求管理员权限。
- `nettop` 周期增量、重复表头、损坏行或进程退出 — 每个 CSV block 只使用当前周期增量，解析器跳过损坏行，进程样本按 PID 关联 — 不发布异常尖峰或跨周期重复累计。
- CPU、内存或网卡计数读取失败 — 保留其他指标和最后有效快照 — 超过两个预期周期没有新值时标记对应来源过期。
- 系统睡眠/唤醒 — 清除 CPU、网络和进程差值基线 — 下一次样本显示采样中，避免唤醒瞬时尖峰。

## 并发与幂等

- `CodexAppServerClient` 使用串行 GCD 队列保护 `Process`、管道、JSONL 缓冲区、请求 ID 和 pending 集合；stdout 可读回调只负责把数据重新排队。
- `NetTopClient` 使用独立串行队列保护 `Process`、输出管道、CSV 分块缓冲区和停止状态；`SystemMetricsSampler` 使用自己的串行队列合并原生样本与网络样本。
- `AppModel` 标记为 `@MainActor`；客户端回调通过 `DispatchQueue.main` 回到 UI 状态域，避免 SwiftUI 和 AppKit 状态竞争。
- 初始化请求固定使用 ID `0`；读取请求使用递增 ID，响应只移除匹配的 pending ID，避免不同读取的响应相互解析。
- 显式停止设置 `intentionallyStopping` 并清理句柄，termination handler 不重复报告断连；重新启动客户端会先停止上一实例。
- 当前没有跨进程锁、幂等键或磁盘去重；每次手动刷新和定时刷新都会产生独立读取请求。

## 安全与权限

- 信任边界是本地油表应用 → 本地 Codex 可执行文件/App Server → Codex 上游服务；应用复用 App Server 的现有认证上下文，不自行处理令牌。
- 代码不打开 `auth.json`，不保存 API key、访问令牌、额度响应、进程网络原始数据或会话内容；持久化数据仅为窗口坐标、登录项注册尝试、用户禁用标记和所选排行指标。
- 应用通过 `LSUIElement` 运行在菜单栏，不声明 Accessibility、屏幕录制、网络代理或管理员权限；合法签名使用 `SMAppService`，ad-hoc 签名使用用户级 LaunchAgent，`nettop` 由当前用户直接启动。
- `codex-fuel/Packaging/Info.plist` 使用本地临时签名；当前没有 Developer ID、公证、自动更新或供应链签名校验机制。
- `NSLog` 记录剩余百分比和连接错误文本，不记录认证材料；错误文本来自外部进程，排障时应避免把本地日志当作敏感数据安全边界。

## 配置与依赖

- **运行平台**：`codex-fuel/Package.swift` 声明 macOS 14+；应用使用 AppKit、SwiftUI、Combine、Foundation 和 ServiceManagement。
- **应用元数据**：`codex-fuel/Packaging/Info.plist` 设置 `CFBundleIdentifier=com.codexfuelgauge.app`、`CFBundleExecutable=CodexFuelGauge`、`LSUIElement=true`。
- **Codex 依赖**：需要安装并登录 Codex 桌面应用；实际可执行文件优先使用应用 bundle 的 `Contents/Resources/codex`。
- **运行常量**：系统采样 1/5 秒、额度读取超时 12 秒、额度定时刷新 30 秒、额度 stale 判断 90 秒、两类重连延迟均为 2/5/15/30/60 秒、颜色阈值 30%/10%。
- **网络依赖**：固定使用 `/usr/bin/nettop`，仅依赖其 `bytes_in`/`bytes_out` CSV 输出；缺失或失败时网络 Top 5 降级。
- **登录启动策略**：`SMAppService.Status.notFound` 时使用 `~/Library/LaunchAgents/com.codexfuelgauge.app.plist`，用户主动关闭后记录 `launchAtLoginUserDisabled`。
- **新增状态**：`selectedSystemMetric` 默认 `cpu`，可在仪表台切换 CPU/内存/网络排行。
- **测试开关**：`CODEX_FUEL_GAUGE_DISABLE_LOGIN_ITEM=1` 跳过首次自动登录项注册，仅供测试运行；不是用户配置项。
- **构建依赖**：`codex-fuel/scripts/swiftc_compat.sh` 固定使用本机 Command Line Tools 的 Swift 编译器；测试目标固定链接本机 `Testing.framework` 和宏插件路径。
- **外部服务**：无自有外部服务；额度和认证请求由 Codex App Server 代表用户处理。

## 可观测性与运维

- 连接状态在 UI 中暴露为“等待 Codex 启动”“正在连接 Codex…”“实时更新中”、stale 或 unavailable 文案。
- 系统卡片暴露 CPU/内存/网络实时状态，网络排行暴露 warming/live/stale/unavailable 文案；没有指标、分布式追踪或系统告警。
- `AppModel` 用 `NSLog` 记录额度读取和连接问题；不记录应用排行原始数据。
- 构建验证入口为 `codex-fuel/scripts/test.sh` 和 `codex-fuel/scripts/package_app.sh`；安装入口为 `codex-fuel/scripts/install_local.sh`，目标路径是用户 `Applications` 目录。
- 本功能是本地桌面应用，不涉及服务发布、数据库迁移、缓存失效、队列消费者或定时任务部署；代码变更后只需重新构建并替换本地 `.app`。
- 排障顺序：先确认登录项和面板可见性，再确认 CPU/内存卡片是否更新；网络异常时检查 `/usr/bin/nettop` 是否可运行，之后确认 Codex bundle/CLI、菜单栏连接状态并手动触发“重新连接”。

## 测试与验证

### 已执行

- `codex-fuel/scripts/test.sh` — 当前 Swift 6.4/Command Line Tools 版本已完成测试目标编译，但完整测试运行无输出持续超过 1 分钟后停止；过滤执行的 `RateLimitModelsTests`（7 项）和 `SystemDashboardPresentationTests`（4 项）均通过。
- `codex-fuel/scripts/package_app.sh` — 退出码 0；完成 production 构建、`.app` 目录生成和临时签名。
- `codex-fuel/scripts/install_local.sh` — 退出码 0；安装到 `~/Applications/CodexFuelGauge.app` 并通过 codesign 校验。
- `codesign --verify --deep --strict codex-fuel/dist/CodexFuelGauge.app` — 通过；应用签名在磁盘上有效。
- `plutil -lint codex-fuel/dist/CodexFuelGauge.app/Contents/Info.plist` — `OK`；bundle 元数据可解析。
- `zsh -n codex-fuel/scripts/test.sh codex-fuel/scripts/package_app.sh codex-fuel/scripts/install_local.sh codex-fuel/scripts/swiftc_compat.sh` — 通过；构建/安装脚本语法有效。
- `nettop -P -L 2 -d -x -n -s 1 -J bytes_in,bytes_out` — 在沙箱外退出码 0；确认普通用户可运行和实际 CSV 字段。
- 当前安装版 UI — 实测同时显示 `5 小时窗口 93%` 与 `7 天窗口 48%` 两张额度卡；额度模型验证菜单栏格式为 `73% | 91%`。

### 未执行

- 实际登录后自动启动、Codex 启停、悬浮窗拖动、跨 Space、菜单栏点击、应用图标和系统登录项批准流程 — 当前自动化测试没有 AppKit/Workspace 系统集成覆盖；双窗口仪表盘已在当前 Mac 手动验证，仍需真实重启确认。
- 不同 Codex 安装路径、未登录账户、上游网络失败和真实多账户切换 — 测试使用固定 fake 子进程和模型 fixture；剩余风险是本机安装布局或服务响应差异。
- 额度读取请求的乱序响应 — 当前没有序列号或去重测试；多次手动刷新与定时刷新并发时需要人工观察最终显示值。
- 与活动监视器对照 30 秒、睡眠/唤醒、`nettop` 进程异常退出和 60 秒自身资源预算 — 当前自动化测试没有真实系统集成覆盖。

### 用户回归准备

- **是否需要用户回归**：是
- **需更新、部署或重启的服务**：无；该功能只有本地 `CodexFuelGauge.app` 和它按需启动的 App Server 子进程，不修改 Codex 服务端，也没有需要重启的常驻服务。
- **无需操作的服务**：Codex 桌面应用本身无需重新构建或部署；本地没有数据库、队列消费者、缓存服务或相邻后端服务。
- **操作顺序**：在仓库根目录运行 `codex-fuel/scripts/package_app.sh` → 运行 `codex-fuel/scripts/install_local.sh` → 注销并重新登录 macOS（或打开已安装 app 验证面板）→ 执行指标与 Codex 启停回归；不需要迁移或服务重启。
- **前置条件**：macOS 14+、Swift 6/Command Line Tools、已安装并登录 Codex 桌面应用、系统存在 `/usr/bin/nettop`；无数据库迁移、配置中心开关、缓存清理、消息消费者或测试数据准备；正式签名环境若提示 `requiresApproval`，先在系统登录项设置批准应用；临时签名环境确认 `~/Library/LaunchAgents/com.codexfuelgauge.app.plist` 存在。
- **回归步骤与预期结果**：① 运行安装脚本并打开 `~/Applications/CodexFuelGauge.app`，确认进程持续运行且 `~/Library/LaunchAgents/com.codexfuelgauge.app.plist` 的路径指向已安装 app；② 注销/重新登录或重启 macOS，确认 LaunchAgent 自动拉起 app；③ 登录后面板立即显示 CPU/内存/网络卡片和 CPU Top 5；④ Codex 未运行时额度显示等待，系统卡片仍每秒更新；⑤ 启动 Codex，额度区域连接并显示油表，面板不重复弹出；⑥ 确认顶部菜单下拉列表不包含额度详情按钮；⑦ 切换 CPU/内存/网络 Top 5，应用名、图标、数值和排序更新，选择下次启动保留；⑧ 隐藏面板后采样降为每 5 秒，再显示时恢复每秒；⑨ 拖动面板、切换 Space 后内容和位置保持；⑩ 关闭 Codex，额度清空并回到等待状态，面板和系统指标保持；⑪ 结束/阻断 nettop，网络 Top 5 显示降级信息，网卡总速率和 CPU/内存仍可用，恢复后排行回归；⑫ 睡眠后唤醒，短暂显示采样中，随后重新出现稳定指标；⑬ 连续观察 60 秒，油表盘和 nettop 合计平均 CPU 不超过单核 3%，油表盘内存不超过 150 MB。


## 关键决策

### 使用本地 App Server，而不是解析会话日志或读取认证文件

- **决定**：通过 `codex app-server --stdio` 调用 `account/rateLimits/read` 并消费 `account/rateLimits/updated`。
- **原因**：当前代码可以复用 Codex 的认证上下文，且协议返回额度桶、窗口和重置时间；日志格式和 `auth.json` 均不适合作为应用契约。
- **取舍**：依赖 Codex 随版本提供的可执行文件和 App Server 协议；换取不复制凭据、可处理多桶额度和实时更新。
- **证据**：`CodexAppServerClient`、`AppServerMessageParser`、`RateLimitsResult` 及 fake 子进程测试。

### 用最紧张窗口驱动单窗口主油表，双窗口直接展示全部窗口

- **决定**：`RateLimitSnapshot.mainRemainingPercent` 取所有有效 primary/secondary 窗口剩余量的最小值。
- **原因**：多个限制同时存在时，用户需要直接比较短窗口和长窗口；单窗口仍由最紧张窗口驱动大油表。
- **取舍**：双窗口占用额度区域的固定高度，但不再需要额外展开区域；单桶和多桶无需分别设计主界面。
- **证据**：`RateLimitSnapshot.windows`、`mainRemainingPercent` 及多桶 fixture 测试。

### 以登录项启动仪表台，以 Workspace 事件控制额度连接

- **决定**：应用自身作为菜单栏登录项运行并在用户登录后显示面板；Codex 启停只驱动额度连接和额度区域状态。
- **原因**：系统资源监控不依赖 Codex，用户需要在 Codex 未运行时也能查看 CPU、内存和网络。
- **取舍**：应用常驻和面板默认可见；换取系统监控连续性，用户可手动隐藏面板。
- **证据**：`AppModel.start()`、`AppModel.handleCodexRunningChanged(_:)`、`CodexLifecycleMonitor`、`SMAppService.mainApp`、`LaunchAgentController` 和 `LSUIElement` 配置。

### 只持久化窗口/登录项元数据，不持久化额度快照

- **决定**：额度/系统快照和重连状态只在内存中，`UserDefaults` 保存面板坐标、首次注册尝试标记和所选 Top 5 指标。
- **原因**：额度是外部服务的短时状态，应用启动时应重新读取；窗口位置需要跨启动保持。
- **取舍**：应用重启后没有离线额度/系统历史，但不会显示可能过期的旧状态或引入本地敏感数据存储；仅记住用户的排行视角。
- **证据**：`FloatingPanelController.windowDidMove`、`AppModel.registerAtLoginOnFirstLaunch`、`AppModel.selectedSystemMetric` 和快照类型的内存使用方式。

### 使用原生系统接口和 nettop，而不是系统扩展

- **决定**：CPU、内存、网卡总量和进程 CPU/内存使用 Darwin 公共接口；应用网络排行使用 `/usr/bin/nettop` CSV。
- **原因**：当前无 App Sandbox、无管理员权限和无 Apple 特殊 entitlement；实测 `nettop` 可由普通用户运行并提供所需上下行字节。
- **取舍**：避免系统扩展和额外签名成本，但需要隔离 nettop 输出变化、异常退出和周期增量与进程采样时序差异。
- **证据**：`DarwinMetricsProvider`、`NetTopClient`、`NettopCSVParser`、`SystemMetricsSamplerTests` 及沙箱外 nettop 样本。

### 采用统一仪表台，而不是分页或宽屏分栏

- **决定**：使用方案 A：额度油表或双窗口额度卡、CPU/内存/网络总览卡和可切换 Top 5 同屏展示；额度窗口信息直接显示在主额度区域。
- **原因**：用户需要同时看到 Codex 额度和本机状态，同时限制常驻悬浮窗占用空间。
- **取舍**：信息密度高于分页方案，但面板高度受屏幕限制并在内容过多时内部滚动。
- **证据**：`GaugeRootView`、`SystemMetricCard`、`SystemApplicationRow`、`FloatingPanelController`。

## 已知问题与后续工作

### 读取请求没有响应序列判定

- **影响**：定时刷新和手动刷新可以同时 pending；如果较早请求晚于较新请求返回，当前代码按到达顺序替换快照，存在短暂旧值覆盖新值的风险。
- **当前处理**：每次请求使用唯一 ID，单个超时可触发重连；没有取消旧请求或比较服务端更新时间。
- **后续动作**：增加请求序列/服务端 `receivedAt` 判定，或在新读取发出时取消旧 pending 请求，并补充乱序响应测试。

### AppKit/系统集成自动化覆盖不足

- **影响**：窗口层级、跨 Space、Workspace 启停通知和登录项批准依赖目标 Mac，当前 Swift Testing 不能证明这些系统行为。
- **当前处理**：档案的用户回归准备提供可执行的本机验证步骤；应用状态和 `NSLog` 提供排障入口。
- **后续动作**：在真实 macOS GUI 测试环境增加启动/退出、面板位置和 `SMAppService` 集成测试。

### 构建脚本绑定本机 Command Line Tools 路径

- **影响**：`codex-fuel/Package.swift` 测试目标和 `swiftc_compat.sh` 使用固定的 `/Library/Developer/CommandLineTools` 路径，其他开发机的 Swift/SDK 安装布局可能无法直接运行测试脚本。
- **当前处理**：脚本集中设置 `SDKROOT`、模块缓存和兼容编译器，当前目标机器可构建并签名。
- **后续动作**：改为动态发现 Swift 工具链、Testing framework 和宏插件路径，并在另一台 macOS 上验证安装流程。

## 变更记录

### 2026-09-12 — 同时展示 5 小时和 7 天额度

- **状态**：已完成
- **说明**：额度窗口按时长升序排列；双窗口时仪表盘展示两张额度卡，菜单栏仅显示百分比序列；真实重启回归仍由用户确认。
- **变化**：新增窗口展示排序、中文时长/重置格式和 `73% | 91%` 菜单栏标题；单窗口保留大油表；双额度卡和 VoiceOver 标签显示窗口时长、百分比、进度及重置倒计时；应用图标改为同步缓存读取以兼容当前 Command Line Tools 缺失 SwiftUI 宏插件的环境。
- **变化补充**：移除仪表盘额度详情展开区域、顶部菜单栏“展开额度详情”菜单项及对应面板展开高度逻辑，额度信息直接保留在主额度卡中。
- **原因**：原实现将所有窗口压缩到 `mainRemainingPercent`，用户无法判断主油表百分比对应 5 小时还是 7 天窗口。
- **兼容性**：不修改 App Server 协议、额度计算、UserDefaults、系统采样、登录项或外部服务；单窗口、无额度和已有额度窗口数据保持兼容。
- **验证**：`RateLimitModelsTests` 7 项和 `SystemDashboardPresentationTests` 4 项通过；release 打包、临时签名、安装和 Info.plist 校验通过；安装版实际显示 `5 小时窗口 93%`、`7 天窗口 48%` 两张卡。

### 2026-08-25 — 修复启动崩溃与 ad-hoc 登录项失效

- **状态**：已完成
- **说明**：修复代码已在当前会话手动启动、LaunchAgent bootstrap 和已安装路径启动验证；真实重启仍待用户确认。
- **变化**：将进程名/路径采样改为传递 C buffer，移除会触发 `__stack_chk_fail` 的 `proc_pid_rusage`；当 `SMAppService.Status.notFound` 时写入用户级 `com.codexfuelgauge.app.plist`，并保留用户主动禁用状态。
- **原因**：crash report 显示应用启动约 206ms 后在 `DarwinMetricsProvider.processSamples()` 触发 `stack buffer overflow`；ad-hoc 签名使 `SMAppService.mainApp.status` 返回 `notFound`，导致登录项未注册。
- **兼容性**：合法签名仍使用 SMAppService；临时签名使用 LaunchAgent fallback，不引入管理员权限、服务端或数据库。
- **验证**：修复后 release 进程持续运行；`~/Applications/CodexFuelGauge.app` 启动后 LaunchAgent 路径正确，`launchctl bootstrap gui/501` 拉起 PID 43538 且 `last exit code=0`；无新的栈溢出/中止日志；`codex-fuel/scripts/test.sh` 编译成功。

### 2026-08-25 — 修复网络增量排行为空

- **状态**：已完成
- **说明**：`nettop -d` 的周期输出已按增量处理，网络总览与 Top 5 均可显示有效速率。
- **变化**：使用 `-L 1` 每周期获取一个 CSV block；网络样本按 block 替换并直接关联到进程差分快照，移除累计网络值回退检查和首帧等待；网络卡片的 VoiceOver 值同步显示下载/上传速率。
- **原因**：`-d` 输出的是相邻采样周期的字节增量，旧逻辑将其当累计计数器，下一周期数值变小时丢弃进程快照；`-L 0` 在 Pipe 下还可能因 stdout 缓冲迟迟不产生完整 block。
- **兼容性**：继续使用 macOS 自带 `/usr/bin/nettop`，不新增权限、外部 API、数据库或服务；无流量时仍显示 `0 B/s`，而不是空白占位符。
- **验证**：安装版 UI 实测网络卡片显示 `↓ 0 B/s / ↑ 0 B/s`，网络 Top 5 出现 `java` 并显示上下行速率；同一时刻 CPU、内存和 Codex 额度继续正常更新；`codex-fuel/scripts/test.sh`、`codex-fuel/scripts/package_app.sh` 均退出码 0。

### 2026-08-24 — 增加系统监控并改为登录即显示

- **状态**：已完成
- **说明**：代码与打包验证完成；真实 GUI、睡眠唤醒、网络故障和性能预算仍待用户回归。
- **变化**：新增 CPU/内存/网络总览、应用 Top 5、Darwin 采样器和 nettop 适配器；面板改为登录后显示，Codex 启停不再控制面板；采用方案 A 统一 UI 和 420pt 面板，并缓存排行应用图标。
- **原因**：满足本次系统资源实时展示、开机自启动和整体 UI 优化需求。
- **兼容性**：保留 Codex App Server 协议、额度模型、菜单栏应用形态、macOS 14+、临时签名和现有 UserDefaults 键；新增 `selectedSystemMetric`。
- **验证**：`codex-fuel/scripts/test.sh` 和 `codex-fuel/scripts/package_app.sh` 退出码 0 并完成编译/打包；SwiftPM 未输出可确认的测试执行摘要；签名、Info.plist、脚本语法和 nettop 普通用户运行已核验。

### 2026-08-24 — 归档当前油表盘实现

- **状态**：已完成
- **变化**：创建 `codex-fuel-gauge` 技术档案和功能索引，记录本地 App Server 读取、额度模型、Codex 生命周期、悬浮 UI、构建打包和测试边界。
- **原因**：用户要求基于当前代码、配置、测试和 Git 状态生成可追溯的功能档案。
- **兼容性**：无代码、协议或运行行为变化；该记录保留初始功能档案历史。
- **验证**：`codex-fuel/scripts/test.sh`、`codex-fuel/scripts/package_app.sh`、`codesign --verify --deep --strict codex-fuel/dist/CodexFuelGauge.app`、`plutil -lint` 和脚本 `zsh -n` 均退出成功。
