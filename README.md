# codex-quota-bar

仅支持 Apple Silicon（M 系列芯片）；构建流程固定生成原生 `arm64` 应用，不提供 Intel 或 Rosetta 版本。

轻量的 macOS 菜单栏应用，用于查看 Codex 剩余额度并提供喝水提醒。

## 功能

- 菜单栏只显示当前模型供应商的额度信息；下拉菜单仍提供已配置供应商的额度详情。重置倒计时满一天按天和小时显示，不足一天时精确到小时和分钟。
- 可在 OpenAI 官方、DeepSeek 官方、阿里百炼 Token Plan、apiopencc 和 Felixxxxx 之间切换；切换完成后自动重启正在运行的 Codex。
- 阿里百炼 Token Plan 一周额度每 5 分钟自动刷新。
- 未配置百炼时自动隐藏百炼额度；仅配置 OpenAI 时自动隐藏模型供应商切换入口。
- 每小时从 GitHub 检查更新；安装失败时自动回滚并跳过该版本。
- 可开启喝水提醒，并选择 60、90 或 120 分钟间隔。
- 喝水时显示 30 秒置顶倒计时。
- 跟随 ChatGPT/Codex 自动启动。
- 可用 `codex-quota-bar` 或 `codex-bar` 命令启动或重启应用。
- 菜单中可打开 Codex 用量页面和 Tibo 的 X 主页。

## 安装与更新

需要 macOS 13 或更高版本、已登录的 ChatGPT/Codex，以及 Xcode Command Line Tools。

在终端运行：

```bash
/usr/bin/curl -fsSL https://raw.githubusercontent.com/sekiyaoshen-blip/codex-quota-bar/main/install | /bin/bash
```

应用会安装到 `~/Library/Application Support/codex-quota-bar/`，不会在 `/Applications` 中留下应用图标。重复运行同一命令即可更新；安装后新开终端即可使用 `codex-quota-bar` 或 `codex-bar`。

## 使用

点击菜单栏中的额度信息即可查看详情、设置喝水提醒或退出应用。

模型切换复用本机 `~/.codex/skills/model-switch/scripts/codex-switch.sh`，需先配置相应供应商密钥。百炼额度读取还需要已安装 `bl` CLI，并完成百炼控制台登录；菜单栏不会显示供应商密钥。

## 手动构建

```bash
git clone https://github.com/sekiyaoshen-blip/codex-quota-bar.git
cd codex-quota-bar
./scripts/build.sh
```

构建结果位于 `dist/codex-quota-bar.app` 和 `dist/codex-quota-bar.zip`。

## 卸载

```bash
./scripts/autostart-off.sh
```

然后删除 `~/Library/Application Support/codex-quota-bar/`。

## License

[MIT](LICENSE)
