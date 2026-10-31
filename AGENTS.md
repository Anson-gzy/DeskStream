---
description: desk-stream、Desk Stream、Pane 改版、trypane、窗口管理器、多桌面竖流、鼠标操作：macOS 窗口管理 App，每个桌面一条竖向窗口流（窗口少一排一个、多了一排两个），桌面左右排开，画布界面照 Pane 原版
---
# desk-stream

macOS 窗口管理 App。画布上的桌面就是 macOS 的桌面（Space），顺序跟调度中心一致，全屏 App 各占一个桌面（全屏 Space 的窗口按它的 `fs_wid` 认，Safari 网页视频全屏的窗口是 AXDialog，不能按 subrole 筛）；每个桌面是一条竖向的行流，窗口按真实比例画，不多于 2 个时一排一个、更多时一排两个，缩略图在每次打开画布时各截一张（不用实时 SCStream：macOS 会在被持续捕获的窗口标题栏上挂一个捕获图标），背景是当前壁纸。App 从不移动、缩放、隐藏或最小化窗口：⌃⌥Space 或四指下滑打开全屏画布。滑到最右边停在最后一个桌面正中，再往右轻轻一划，整排桌面连同右边一截虚化的空桌面一起被拉出来，稍微用点力就新建 macOS 桌面：新桌面就从露出的位置接着手势的速度用弹簧滑到正中停住，虚影和它交叉淡入淡出（期间锁住原生滚动，免得剩下的惯性抢着滚；调度中心等画布基本停稳才开）（按调度中心里 WindowManager 暴露的 Add Desktop 辅助功能按钮，不动鼠标，画布不关）；空桌面的标签悬停出现 ×，同样经调度中心删掉那个桌面。屏幕外桌面的标签贴在屏幕边上，但不出这个桌面窗口的左右边（窗口只剩一截时标签停在窗口边上跟着出去），滑过去时慢慢回到桌面正中；点标签进总览。拖标签给桌面排序：画布先换好顺序，再在画布底下开调度中心，用 HID 层的鼠标事件把缩略图拖到新位置，同步真实顺序（约 4 秒，用户看不出来：画布盖着调度中心，每发一个事件就把光标瞬移回原位）。别的办法在 macOS 27.2、SIP 开着时都不行：调度中心的桌面按钮没有移动动作，发给 WindowManager 的事件不理，挪别的进程的窗口（含 yabai 的 compat ID 绕法）没反应。点一个窗口就把它原样提到最前并聚焦（跨 Space 会切过去），点没有窗口的空桌面就切到那个桌面。

## 结构

- `web/`：画布界面（原生 HTML/CSS/JS，无构建）。视觉照 trypane.app 原版：窗口、玻璃标签、红绿灯、卡片。浏览器直接打开是演示模式（示例卡片、渐变背景，不放 trypane 的壁纸、截图和图标：仓库是公开的），在 App 里由 Swift 推真实窗口和壁纸。
- `mac/`：Swift App。`DeskCore` 是纯布局逻辑：桌面、行、新窗口归位与持久化（有单元测试），`DeskStream` 是 App（辅助功能 API 管窗口、ScreenCaptureKit 截缩略图、Carbon 全局热键、全屏面板里的 WKWebView）。
- `docs/bridge.md`：Swift 与网页之间的协议和布局规则，两边都以它为准。

## 运行与验证

- 画布按 120fps 渲染：WebKit 默认把页面限在 60fps，`Overlay.swift` 关掉了内部特性 `PreferPageRenderingUpdatesNear60FPSEnabled`。滑动帧率用 rAF 间隔量，别看肉眼。
- 动画：相机平移用初速度为零的阻尼弹簧（`easeOutSpring`）。窗口飞入飞出照 Mission Control：整个桌面的窗口同时在真实位置和卡片之间直线飞，临界阻尼弹簧不过冲（`easeMC`、`lineFrames`、`flyDesk`）。飞行用的副本没有阴影和标签，飞到六成时就把卡片露在副本下面淡入阴影和标签，否则停下后一换就是可见的一顿。拖桌面时别的桌面让位、松手归位都由 JS 逐帧推（`slides`），标签和桌面用同一个 x。
- 滑动用原生 overflow 滚动，滚轮监听只能是 passive：WKWebView 里有一个非 passive 的 wheel 监听（哪怕只是可能 preventDefault）就会让滚动回到主线程，滑动不跟手、没有惯性和回弹。`cam.tx` 跟着 `scrollLeft` 走。
- 两端回弹是页面自己做的（`#stage` 设了 `overscroll-behavior-x: none`）：系统回弹只拉滚动内容，滚动内容外面的新桌面虚影跟不上。拉的时候挪 `#cols` 和 `#heads`，别挪 `#track`：挪 `#track` 会缩小可滑范围，滚动位置被夹回去，正好抵消。手感照 use-gesture 的 rubberband（系数 0.55）和 motion 的 inertia 撞边界换弹簧：手指按着时一点不漏地跟手，松手用欠阻尼弹簧弹回。手指按下、松开、惯性开始结束这些阶段 wheel 事件里没有，由 `Overlay.swift` 的本地滚轮监听在阶段变化时调 `deskStream.wheel`；浏览器里 90ms 没事件当松手。回弹没停时手指按下会接住弹簧接着拉，但只接往头外拉的那一边：弹簧过冲到另一边时接住会被当成往没头的方向拉，往回划整排被拉着走、滑不动。锁住期间手动滚的部分系统惯性被挡掉，松手由 `glideFrom` 按最近 100ms 的速度自己滑（指数减速，撞头照样弹）。
- 壁纸：`NSWorkspace.desktopImageURL` 常常是旧的，改为截 WindowManager 的 Wallpaper 窗口。
- 调度中心：Spaces Bar 里的「Exit To <名字>」按钮按 minX 排就是桌面顺序，它的 AX 位置是缩略图中心。拖动排序只认 `.cghidEventTap` 的事件（发给 WindowManager 进程的不理），调度中心开着时光标藏不住，改为每发一个事件就 `CGWarpMouseCursorPosition` 回原位（调度中心照样按事件坐标认拖动）；悬停展开桌面栏要一直发 mouseMoved（约 0.8 秒），停下等的话光标一回原位桌面栏就收起。拖动时用 `CGAssociateMouseAndMouseCursorPosition(0)` 挡住用户的鼠标。
- 系统设置 Desktop & Dock → Mission Control 里的「Automatically rearrange Spaces based on most recent use」（`com.apple.dock mru-spaces`，默认开）要关掉：开着时 App 每次靠激活窗口或探针窗口切桌面，系统都先把目标桌面挪到当前桌面旁边再切（Dock 日志里 `moved(X, after 当前)` 后约 0.3 秒 `becameCurrent`），桌面顺序和编号随之改变，画布、调度中心、四指横滑看到的就不是原来的顺序。查：`/usr/bin/log show --last 1h --predicate 'process == "Dock" AND eventMessage CONTAINS "space-change deltas"'`
- 新建桌面只认横向为主的手势：在最后一个桌面上下翻时滚轮事件也带一点 deltaX，不按主方向过滤会累计到 80 新建桌面
- 四指下滑：`Gestures.swift` 照 LaunchOS 用只听不拦的会话 tap 收手势事件（类型 29），从触点数手指、算位移。系统的 App Exposé 也绑在四指下滑上，要在 System Settings → Trackpad → More Gestures 里关掉它才不会一起出来。
- 面板带 `.stationary`：不带时系统切 Space 的滑动会画在画布上面、调度中心也会盖住画布。跨桌面去窗口或去空桌面时画布保持不透明，等 `activeSpaceDidChange` 后才淡出，不和系统滑动叠成重影。
- 网页演示：在 `web/` 起静态服务（`python3 -m http.server 4174 --bind 127.0.0.1`），浏览器打开。
- App：`mac/project.yml` 是唯一源头，xcodeproj 由 xcodegen 生成且不进仓库。图标 `AppIcon.appiconset` 由 `mac/make_icon.py` 画出来，改图标改脚本再重跑。

```bash
cd mac && xcodegen generate --quiet && xcodebuild -project DeskStream.xcodeproj -scheme DeskStream -configuration Debug -derivedDataPath build -collect-test-diagnostics never build test -quiet
```

- 签名用 Apple Development 证书（DEVELOPMENT_TEAM 是证书 OU 里的 68VQ9CZA2A，不是证书名括号里的 65XN27M632），ad-hoc 签名会让辅助功能和录屏权限每次重编都失效。
- 发布：公开仓库 GitHub `Anson-gzy/DeskStream`，README 英文为主（`README.md`），中文 `README.zh-CN.md`，两份一起改。Release 附 `DeskStream.zip`（Release 配置、universal、ad-hoc 重签、未公证：开发证书名里带个人邮箱，不能发出去）。
- 首次运行要在 System Settings → Privacy & Security 里给 Accessibility 和 Screen Recording。
- 安装：`ditto build/Build/Products/Debug/DeskStream.app /Applications/DeskStream.app`（在 `mac/` 下跑），同一证书签名，权限沿用。
