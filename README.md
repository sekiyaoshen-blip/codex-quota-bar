# Codex Quota Bar / Codex 额度栏

一个轻量的原生 macOS 菜单栏应用，按当前账号实际提供的额度窗口显示 Codex 剩余量。

`周 99% · ↻2`

## 功能

- 每 1 分钟自动刷新 Codex 额度。
- 菜单栏按 Codex 实际返回的窗口时长显示剩余百分比（`100% - 已用百分比`）；没有 5 小时窗口时不会显示虚假的 `5h` 项。
- 菜单栏以紧凑的 `↻次数` 显示剩余可用重置次数。
- 下拉菜单显示剩余百分比、已用百分比、重置时间与最近更新时间。
- 支持打开 Codex 用量页面和断线自动重连。
- 下拉菜单提供“打开 Tibo 的 X 主页”，仅在点击后使用默认浏览器打开 `https://x.com/thsottiaux`。
- 原生 AppKit 实现，无第三方运行时依赖，不显示 Dock 图标。
- 可选安装用户级 LaunchAgent：打开官方 ChatGPT/Codex 后，额度栏会在 30 秒内自动启动。
- 可手动开启或关闭喝水提醒，并选择每 60、90 或 120 分钟提醒一次。
- 60/120 分钟提醒始终安排在整点，90 分钟提醒安排在整点或半点；提醒时显示持续置顶的 30 秒倒计时弹窗，结束后自动关闭并恢复此前使用的应用。
- 喝水提醒不申请“辅助功能”等额外系统权限，也不会锁定系统键盘或鼠标。
- 不启动额外的 Codex App Server，不访问 `~/.codex` 下的 SQLite 状态库，因此不会与 ChatGPT Desktop 或 Software Proxy 的启停发生数据库冲突。
- 每次刷新只在内存中读取现有登录令牌并请求官方 `chatgpt.com` 用量接口；不修改、复制、保存或输出令牌。

## 系统要求

- macOS 13 或更高版本。
- 已使用官方 ChatGPT/Codex 登录，并存在 `~/.codex/auth.json`。
- Apple Swift 编译工具；安装 Xcode Command Line Tools 即可。

## 一行命令：下载、构建、安装并启动

在“终端”中粘贴下面这一整行：

```bash
(workdir="$(/usr/bin/mktemp -d)" && trap '/bin/rm -rf "$workdir"' EXIT && /usr/bin/git clone --depth 1 https://github.com/sekiyaoshen-blip/codex-quota-bar.git "$workdir/codex-quota-bar" && "$workdir/codex-quota-bar/scripts/install.sh")
```

该命令会从 GitHub 浅克隆项目、构建应用、替换 `/Applications/Codex 额度栏.app`、配置跟随 ChatGPT/Codex 自动启动并立即启动。确认启动成功后，临时源码和构建中间文件会自动删除，只保留已安装应用和运行所需配置。

## 让 Codex 自动安装

将下面整段 Prompt 复制给 Codex，即可让它从本项目地址完成检查、构建、安装和验证：

```text
请帮我从 https://github.com/sekiyaoshen-blip/codex-quota-bar 自动安装“Codex 额度栏”。请先检查这台 Mac 是 Intel 还是 Apple Silicon，并确认 macOS 版本、官方 ChatGPT/Codex 登录状态和 Swift/Xcode Command Line Tools 是否满足项目要求；然后检查 README 中“一行命令：下载、构建、安装并启动”的命令和 scripts/install.sh，确认没有超出安装所需范围的操作后执行该命令。它应一次完成临时浅克隆、构建、替换 /Applications/Codex 额度栏.app、配置跟随 ChatGPT/Codex 自动启动并立即启动；确认启动成功后删除临时源码和构建中间文件。安装和验证命令不得打印、复制或检查 auth.json 中的令牌内容。完成后验证菜单栏能显示当前账号提供的剩余额度和剩余重置次数、LaunchAgent 已注册、应用只有一个实例、喝水提醒子菜单可手动开关并可选择 60/90/120 分钟，且没有启动额外的 codex app-server 或持有 ~/.codex 下的 SQLite 文件。喝水提醒应只使用无需额外权限的持续置顶 30 秒倒计时弹窗，不得申请辅助功能权限或锁定系统键盘鼠标。不要关闭 Gatekeeper；如果遇到必须由我完成的系统授权或安全确认，请清楚说明并停在确认步骤。最后告诉我处理器架构、安装路径、构建与签名结果、启动结果、清理结果和上述验证结果。
```

## 一键构建、安装并启动

```bash
./scripts/install.sh
```

该脚本会构建应用、替换 `/Applications/Codex 额度栏.app`、配置跟随 ChatGPT/Codex 自动启动，并立即启动额度栏。也可以传入其他绝对安装路径：

```bash
./scripts/install.sh "$HOME/Applications/Codex 额度栏.app"
```

## 构建

```bash
git clone https://github.com/sekiyaoshen-blip/codex-quota-bar.git
cd codex-quota-bar
./scripts/build.sh
```

构建结果：

- `dist/Codex 额度栏.app`
- `dist/CodexQuotaBar.zip`

脚本会为当前 Mac 的处理器架构生成原生应用，并进行 ad-hoc 签名与完整性校验。

## 使用

1. 运行 `./scripts/build.sh`。
2. 将 `dist/Codex 额度栏.app` 拖入“应用程序”。
3. 双击启动。正常网络下通常会在几秒内显示额度。
4. 点击菜单栏中的额度信息可查看详情、打开 Tibo 的 X 主页或退出。

如果 macOS 阻止首次打开，请在 Finder 中右键应用，选择“打开”，再确认一次。

## 跟随 ChatGPT/Codex 自动启动（可选）

将应用放入“应用程序”后运行：

```bash
./scripts/install-autostart.sh "/Applications/Codex 额度栏.app"
```

安装器会创建当前用户专用的 LaunchAgent，每 30 秒检查一次官方 ChatGPT/Codex 主程序。主程序运行且额度栏尚未运行时，额度栏会自动打开；重复检查不会创建多个实例。检测只匹配主可执行文件，不会把退出后残留的 Crashpad、Renderer、键盘监控、CLI 或 Software Proxy 辅助进程当成主程序。

如果应用安装在其他位置，把实际 `.app` 路径作为唯一参数传入。该功能只负责跟随启动；退出 ChatGPT/Codex 时不会强制关闭额度栏。

关闭并移除跟随启动配置：

```bash
./scripts/uninstall-autostart.sh
```

卸载脚本不会删除“Codex 额度栏.app”。

## 喝水提醒

点击菜单栏中的额度信息，打开“喝水提醒”子菜单：

1. 选择“开启喝水提醒”或“关闭喝水提醒”。
2. 选择每 60、90 或 120 分钟提醒一次。
3. 菜单会显示下一次提醒时间；60/120 分钟模式从下一个整点开始，90 分钟模式从下一个整点或半点开始，后续继续按所选间隔执行。

提醒时会出现保持在活动前台的 30 秒倒计时弹窗。倒计时结束后弹窗自动关闭，并恢复此前正在使用的应用。该功能不申请辅助功能权限，因此不会进行系统级键盘或鼠标锁定。

## 实现原理

应用每分钟读取一次 `~/.codex/auth.json` 中现有的 ChatGPT OAuth access token 与 account ID，并通过系统 HTTPS 网络栈请求：

```text
https://chatgpt.com/backend-api/wham/usage
```

令牌只存在于当次请求的内存中。应用使用临时、无缓存、无 Cookie 的网络会话，只解析额度窗口和剩余重置次数，不读取接口返回的邮箱、用户 ID 等其他账号字段。

若进程环境包含标准 `HTTP_PROXY`/`HTTPS_PROXY`，应用会使用该代理；否则会检查正在运行的官方 ChatGPT/Codex 主进程是否带有 `--proxy-server` 参数，以兼容 `ChatGPT(VPN).app`。没有代理配置时使用 macOS 正常网络设置。

此用量接口是 ChatGPT/Codex 当前使用的内部接口，并非稳定的公开开发者 API；如果官方以后调整路径或响应格式，应用会显示读取错误，需要随版本更新。

## 隐私

- 不包含遥测或第三方分析。
- 不保存 Codex 返回的额度数据。
- 只使用 `~/.codex/auth.json` 中的 access token 与 account ID，不使用 refresh token 或 ID token。
- 登录信息仅用于向 `https://chatgpt.com/backend-api/wham/usage` 发起 HTTPS 请求，不修改、不复制到其他文件、不写日志、不上传到第三方。
- 不启动 `codex app-server`，不读取或持有 `state_*.sqlite`、`logs_*.sqlite` 等本地数据库。
- 可选跟随启动功能只检查本机进程命令中的官方 ChatGPT/Codex 主可执行路径，不读取这些进程的数据或数据库。
- “打开 Codex 用量页面”仅在用户点击后使用默认浏览器打开官方页面。
- “打开 Tibo 的 X 主页”仅在用户点击后使用默认浏览器打开公开主页；应用不会后台读取、抓取或保存 X 内容。

## License

[MIT](LICENSE)

---

English: A tiny native macOS menu bar app that displays the quota windows currently provided by Codex, refreshed every minute without starting an additional Codex App Server. Build it with `./scripts/build.sh`.
