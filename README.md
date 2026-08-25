# codex-quota-bar

轻量的 macOS 菜单栏应用，用于查看 Codex 剩余额度并提供喝水提醒。

## 功能

- 显示 Codex 剩余额度、重置时间和剩余重置次数，每分钟自动刷新。
- 每 24 小时从 GitHub 检查更新；安装失败时自动回滚并跳过该版本。
- 可开启喝水提醒，并选择 60、90 或 120 分钟间隔。
- 喝水时显示 30 秒置顶倒计时。
- 跟随 ChatGPT/Codex 自动启动。
- 菜单中可打开 Codex 用量页面和 Tibo 的 X 主页。

## 安装与更新

需要 macOS 13 或更高版本、已登录的 ChatGPT/Codex，以及 Xcode Command Line Tools。

在终端运行：

```bash
(workdir="$(/usr/bin/mktemp -d)" && trap '/bin/rm -rf "$workdir"' EXIT && /usr/bin/curl --fail --location --show-error --connect-timeout 15 --max-time 120 --retry 2 https://codeload.github.com/sekiyaoshen-blip/codex-quota-bar/tar.gz/refs/heads/main --output "$workdir/source.tar.gz" && /bin/mkdir "$workdir/codex-quota-bar" && /usr/bin/tar -xzf "$workdir/source.tar.gz" --strip-components=1 -C "$workdir/codex-quota-bar" && "$workdir/codex-quota-bar/scripts/install.sh")
```

应用会安装到 `~/Library/Application Support/codex-quota-bar/`，不会在 `/Applications` 中留下应用图标。重复运行同一命令即可更新。

## 使用

点击菜单栏中的额度信息即可查看详情、设置喝水提醒或退出应用。

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
