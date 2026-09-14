# Codex Fuel Gauge

一个原生 macOS 菜单栏辅助应用：用户登录 macOS 后自动显示统一悬浮仪表台，实时展示 Codex 额度和本机资源状态。

## 功能

- 使用 Codex 官方 App Server 的 `account/rateLimits/read` 和 `account/rateLimits/updated`。
- 汽车油表风格额度卡，始终置顶、跨 Space、可拖动并记忆位置。
- 实时展示 CPU、内存、网络上下行，并按 CPU/内存/网络查看应用 Top 5。
- 登录后自动启动；Codex 未运行时额度区域等待，系统资源区域继续更新。
- 多额度桶和 primary/secondary 窗口标签；单窗口使用大油表，5 小时/7 天同时存在时并排显示两个额度卡。
- 菜单栏额度标题按短窗口到长窗口显示百分比，例如 `73% | 91%`。
- 菜单栏快速显示/隐藏、刷新、重连、登录项管理和退出。
- 不读取、复制或保存 `~/.codex/auth.json`。

## 系统要求

- macOS 14 或更高版本。
- 已安装并登录 Codex 桌面应用。
- Swift 6 工具链；不要求安装完整 Xcode。

## 构建与安装

```sh
./scripts/test.sh
./scripts/package_app.sh
./scripts/install_local.sh
```

项目脚本会把 Swift/Clang 模块缓存放在 `.build/`，并兼容当前 macOS Command Line Tools 中编译器与 SDK 的补丁版本差异。

安装结果位于 `~/Applications/CodexFuelGauge.app`。首次运行后，应用会尝试注册为登录项；临时签名环境会自动写入用户级 `~/Library/LaunchAgents/com.codexfuelgauge.app.plist`，正式签名环境优先使用 `SMAppService`。如果 macOS 要求批准，可从菜单栏选择“在系统设置中批准登录项…”。

若希望手动运行未安装的构建产物：

```sh
open dist/CodexFuelGauge.app
```

## 数据刷新

应用与 Codex 自带的 `codex app-server --stdio` 进程通信，收到实时通知时立即更新，同时每 30 秒主动刷新一次。系统资源面板可见时每秒采样，隐藏时每 5 秒采样；应用网络排行由系统自带 `/usr/bin/nettop` 提供。Codex 断线时额度保留最后一次数据并退避重连，Codex 退出后面板不隐藏。
