# Codex Quota Bar / Codex 额度栏

一个轻量的原生 macOS 菜单栏应用，常驻显示 Codex 的 5 小时额度和一周额度使用量。

`5h 45% · 周 7%`

## 功能

- 每 1 分钟自动刷新 Codex 额度。
- 菜单栏显示 5 小时和一周窗口的已用百分比。
- 下拉菜单显示剩余百分比、重置时间与最近更新时间。
- 支持手动刷新、打开 Codex 用量页面和断线自动重连。
- 原生 AppKit 实现，无第三方运行时依赖，不显示 Dock 图标。
- 不读取、复制或保存登录凭据；通过本机 Codex App Server 的只读接口获取额度。

## 系统要求

- macOS 13 或更高版本。
- 已安装 Codex CLI，并已使用 ChatGPT 账号登录。
- Apple Swift 编译工具；安装 Xcode Command Line Tools 即可。

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
3. 双击启动。首次连接可能因 Codex 扫描本机插件而等待 20～40 秒。
4. 点击菜单栏中的额度信息可查看详情或退出。

如果 macOS 阻止首次打开，请在 Finder 中右键应用，选择“打开”，再确认一次。

## 实现原理

应用启动本机 `codex app-server --stdio`，完成 JSON-RPC 初始化后调用：

```text
account/rateLimits/read
```

应用保持该本机进程连接，并每分钟发起一次只读刷新。Codex 进程异常退出时，应用会自动重连。

相关官方文档：[Codex App Server](https://learn.chatgpt.com/docs/app-server)

## 隐私

- 不包含遥测或第三方分析。
- 不保存 Codex 返回的额度数据。
- 不直接访问或导出 Codex 的登录令牌。
- “打开 Codex 用量页面”仅在用户点击后使用默认浏览器打开官方页面。

## License

[MIT](LICENSE)

---

English: A tiny native macOS menu bar app that displays Codex five-hour and weekly quota usage, refreshed every minute. Build it with `./scripts/build.sh`.
