# PagaShell 应用图标

原图：`pagashell-icon-v1.png`。macOS、Windows、Linux 使用同一份图案，导出时只缩放尺寸并保留透明通道。

## 更新平台资源

在已安装 Python 3 和 Pillow 的开发环境中运行：

```bash
python3 scripts/generate_app_icons.py
```

更新原图路径时可传入 `--source /path/to/icon.png`，图像须为至少 1024px 的正方形 PNG。生成的资源随源码维护，正常 Flutter 构建无需 Python 或 Pillow。

- macOS：`macos/Runner/Assets.xcassets/AppIcon.appiconset/`，16–1024px；沿用 Xcode 的 AppIcon 配置。
- Windows：`windows/runner/resources/app_icon.ico`，含 16、24、32、48、64、128、256px；沿用 EXE 和窗口的 `IDI_APP_ICON` 资源引用。
- Linux：`linux/runner/resources/app_icon_*.png`，16–512px。CMake 将窗口图标放入 bundle 的 `data/app_icon.png`，并将桌面入口和多尺寸图标放入 `share/applications/`、`share/icons/hicolor/`。

Linux 直接运行 bundle 时从可执行文件所在目录加载窗口图标。桌面应用列表和启动器使用应用 ID `io.github.zhongxuming.pagashell` 匹配图标；发行安装时需将 bundle 的 `share` 资源安装到对应 XDG 数据目录，并保证 `pagashell` 命令在 `PATH` 中。
