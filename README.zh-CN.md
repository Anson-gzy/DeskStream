# Desk Stream

[English](README.md) | 简体中文

把所有 macOS 桌面摊在一张画布上。桌面从左往右排，顺序和调度中心一致；每个桌面里的窗口竖着排成一条。点一个窗口就切过去，窗口原样不动。

Desk Stream 从不移动、缩放、隐藏或最小化你的窗口，它只负责展示和带你过去。

## 功能

- **随时打开**：按 `⌃ ⌥ Space`，或四指下滑
- **一眼看完所有桌面**：每个 macOS 桌面（Space）是一列，全屏 App 单独占一列；每次打开画布都重新截缩略图，背景是你自己的壁纸
- **去一个窗口**：点它，Desk Stream 切到它所在的桌面并把它提到最前；点空桌面就切到那个桌面
- **像翻网页一样滑**：在一个桌面里上下滑，或左右滑到下一个桌面，带系统的惯性和边缘回弹
- **新建桌面**：滑到最后一个桌面后再往右推一下，新的 macOS 桌面就滑进来
- **删除桌面**：鼠标悬停在空桌面的标签上，点 ×
- **调整桌面顺序**：拖动桌面标签。画布立刻换好顺序，真实顺序在后台经调度中心同步（约 4 秒）
- **键盘**：`⌃ ⌥ ↑ ↓` 在行之间移动，`⌃ ⌥ ← →` 在桌面之间移动，`Esc` 关闭画布

## 系统要求

- macOS 15 或更高版本（在 macOS 27.2 上开发和测试）
- 四指手势需要触控板（快捷键不需要）

## 安装

1. 从 [Releases](../../releases/latest) 下载 `DeskStream.zip`，解压后把 `DeskStream.app` 拖进 `/Applications`
2. App 是 ad-hoc 签名，**没有公证**，第一次打开会被 macOS 拦下。先打开一次，再到 System Settings → Privacy & Security 点 **Open Anyway**。如果提示 App 已损坏，运行 `xattr -dr com.apple.quarantine /Applications/DeskStream.app` 后再打开
3. 在 System Settings → Privacy & Security 里给它两个权限：
   - **Accessibility**：列出窗口、把窗口提到最前
   - **Screen Recording**：截窗口缩略图和壁纸

Desk Stream 在菜单栏里（没有 Dock 图标），从菜单栏图标打开画布或退出。

### 建议的系统设置

- **关掉四指下滑的 App Exposé**：System Settings → Trackpad → More Gestures → App Exposé，否则两个会一起出来
- **关掉「Automatically rearrange Spaces based on most recent use」**：System Settings → Desktop & Dock → Mission Control。开着时，macOS 会把你切过去的桌面挪到当前桌面旁边，画布上的顺序会一直变

## 从源码构建

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
cd mac
xcodegen generate
xcodebuild -project DeskStream.xcodeproj -scheme DeskStream -configuration Debug -derivedDataPath build build test
ditto build/Build/Products/Debug/DeskStream.app /Applications/DeskStream.app
```

先把 `mac/project.yml` 里的 `DEVELOPMENT_TEAM` 改成你自己的 Team ID。要用正式证书签名：ad-hoc 签名每次重新编译后，macOS 都会忘掉 Accessibility 和 Screen Recording 权限。

### 在浏览器里试画布

画布是 `web/` 里的纯 HTML、CSS 和 JavaScript。用浏览器打开时是演示模式，里面是示例窗口：

```bash
cd web && python3 -m http.server 4174 --bind 127.0.0.1
```

然后打开 <http://127.0.0.1:4174>。

## 原理

- `web/` 是画布，显示在一个全屏 `WKWebView` 面板里；Swift 和网页之间的协议见 `docs/bridge.md`
- `mac/DeskStream` 是 App：用辅助功能 API 管窗口，ScreenCaptureKit 截缩略图，Carbon 注册全局快捷键，只听不拦的事件 tap 识别四指下滑
- `mac/DeskCore` 是布局逻辑和它的单元测试
- macOS 没有管理桌面的公开 API。Desk Stream 用 SkyLight 私有接口读取桌面，通过调度中心暴露给辅助功能的按钮新建、删除和调整桌面顺序，以后的 macOS 更新随时可能让其中某一项失效

## 致谢

画布的外观参考了 [Pane](https://trypane.app)。Desk Stream 是独立项目，和 Pane 没有关系。

字体：[Inter](https://github.com/rsms/inter) 和 [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)，采用 SIL Open Font License（见 `web/assets/fonts/OFL.txt`）。

## 许可证

[MIT](LICENSE)
