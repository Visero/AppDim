# AppDim · 菜单栏窗口变暗小工具

一个免费、本地运行、无需账号、无需付费的 macOS 菜单栏工具：在状态栏里勾选任意正在运行的 App，
给它的窗口盖一层可调透明度的半透明黑罩，夜间护眼。替代 2022 年停更、遮挡后容易丢遮罩的 AppDimmer。

<img src="icon/AppDim.iconset/icon_512x512@2x.png" width="64" height="64" alt="icon">

## 下载安装

**[👉 下载 AppDim-1.1.0.zip](https://github.com/Visero/AppDim/releases/download/v1.1.0/AppDim-1.1.0.zip)**

历史版本见 [Releases](https://github.com/Visero/AppDim/releases)。

1. 下载并解压，把 `AppDim.app` 拖进「应用程序 / Applications」。
2. 首次打开：因为未做 Apple 公证，右键（按住 Control 点按）App 图标 → **打开** → 再点「打开」，只需这一次。
3. 菜单栏出现一个半圆小图标即运行成功，程序不占 Dock。

> 适用于 Apple Silicon（arm64）macOS 13 及以上；Intel Mac 可用源码自行编译（见文末）。

## 功能

- **任意 App 勾选**：菜单栏菜单动态列出所有正在运行的 App，勾选即变暗、取消即恢复，选择自动记住。
- **常驻变暗**：勾选的 App 一直变暗，不依赖它是不是前台窗口。
- **不盖上层窗口**：遮罩只垫在目标窗口正下方，别的窗口叠上来时保持正常亮度。
- **跟随窗口**：拖动、缩放目标窗口，遮罩实时跟随。
- **点击穿透**：遮罩不拦截鼠标，正常点选、输入、滚动。
- **暗度可调**：15%–60% 滑杆，实时生效。
- **全局快捷键**：默认 `⇧⌘D` 一键开关变暗总览，菜单里点「录制快捷键」可改成任意组合键，Esc 取消，可一键恢复默认。
- **开机自启**、总开关、退出一应俱全。
- 不需要「辅助功能 / 辅助触控」权限：窗口位置通过系统窗口列表读取，不上传任何数据。

## 菜单说明

| 菜单项 | 作用 |
|---|---|
| 启用窗口变暗 | 总开关 |
| 运行中的 App（勾选变暗） | 列出当前所有运行中的 App，逐个勾选开启/关闭 |
| 暗度滑杆 | 15%–60%，默认 35%，越右越暗 |
| 录制快捷键：⇧⌘D | 点按后按下新组合键即完成自定义；Esc 取消 |
| 恢复默认 ⇧⌘D | 回到默认全局快捷键 |
| 开机自动启动 | 登录 macOS 后台自启 |
| 退出 AppDim | 完全关闭 |

## 从源码编译

需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/Visero/AppDim.git
cd AppDim
./build.sh
# 产物：AppDim.app
```

`build.sh` 用 `swiftc -O` 编译，仅依赖系统 Cocoa / ServiceManagement 框架，ad-hoc 签名后可直接运行。

## 目录结构

```
AppDim/
├── src/main.swift        # 全部逻辑（菜单栏、遮罩、窗口跟随、持久化）
├── Info.plist
├── build.sh              # 编译 + 组装 + ad-hoc 签名
├── icon/
│   ├── make_icon.swift   # 图标生成源码
│   ├── AppDim.icns
│   └── AppDim.iconset/
└── README.md
```

## 隐私

纯本地运行，不联网、不采集、不上传任何信息。

## License

[MIT](LICENSE)
