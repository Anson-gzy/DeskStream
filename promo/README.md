# 演示视频

真实录屏剪成的一镜到底（约 22 秒，1920×1248 60fps），配中文功能说明卡片和一条贯穿全片的画布小地图。录屏文件（`n1.mov`–`n4.mov`，`screencapture -v -C -V <秒>` 录的）不进仓库。

- `director.swift`：从 stdin 读脚本驱动鼠标、双指滑动和 ⌃⌥Space，打印每个动作的时间点。合成的事件 flags 必须清空，否则 ⌃⌥ 会粘住，下一次点击变成右键。
- `edit.py`：分镜表 `SHOTS`（片段、起止、变速、镜头关键帧），逐帧裁切推拉，接片尾卡，输出 `events.txt`
- `hud.py`：叠加层。开头的 ⌃⌥Space 键帽，按下后让位给画布小地图（桌面卡片、取景框、右端虚线新桌面），全片同一张说明卡片（标题加一句说明），每段滑到当时画面空着的地方（`SPOTS`），趁画面本来就在动时挪，别占掉静止的停顿；片尾小地图升到画面中间放大，桌面无限循环滚动。小地图按 (片段, 原片时间) 取状态，变速自动跟上
- `measure.py`：相位相关测每帧画布横移，写 `shift.json`，小地图的滑动曲线照它走；换了录屏要重跑
- `score.py`：按 `events.txt` 用 onetake 的 `sfx_palette` 合成音效
- 四指下滑合成不出来，片里没有
- `cut2.py`：第二支，剪用户自己用 Cap 录的一段（1664×1080 60fps，`python3 cut2.py src.mp4 out.mp4`，在 `promo/` 下跑）。`SEGS` 分段变速（汉宁窗平滑），底部一张玻璃卡片：左边触控板按 `GESTURES` 画手指（四指下滑、双指左右/上下、捏合、点按、甩），右边按 `NOTES` 换标题和说明；点击处在画面上画一圈涟漪。片尾是 App 图标、名字和「四指下滑 · ⌃⌥Space」（PingFang 没有 ⌃⌥，键名用 SF 写）。不配音效
- 录之前把个人 App 隐藏（隐藏的 App 不进画布），三个桌面各开两三个没有个人信息的系统 App（Finder 的 /System/Applications、Tips、Calculator、Clock、Font Book、Stocks、Dictionary）；System Settings 和 Chess 会露出账户名，别用
