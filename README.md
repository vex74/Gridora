# Gridora

> 产品显示名为 **Gridora**：`Resources/Info.plist` 的两个 name 键，以及 `.app` 文件名
> （Finder / Dock 显示的是文件名，实测本地化 `InfoPlist.strings` 不会覆盖它）。
> bundle id、包内可执行名、Swift target、状态目录、日志前缀与 iCloud 快照文件名仍为
> `LaunchOS` —— 这些是持久化技术标识，改名会让真机 `state.json` 与现有云端布局失联。
> 界面里所有可见名称统一从 `Support/AppBrand.swift` 读取；Dock 固定项已在改名时
> 一次性迁移到 `~/Desktop/Gridora.app`（旧 plist 已备份）。

一个用 SwiftUI + AppKit 写的 macOS 启动台（Launchpad）复刻品，原生、全屏、无边框，
保留 Launchpad 的拖拽手感与分页逻辑，并补上原版缺失的几个人性化功能。

```
./build.sh                     # 生成 build/Gridora.app
./build.sh release --install   # 构建 + 一键替换交付（推荐）
open ~/Desktop/Gridora.app    # 双击桌面图标直接打开启动台
```

## 交付 / 更新（桌面图标）

Dock 里固定的 Gridora 图标指向 `~/Desktop/Gridora.app`，**这个路径必须始终是一个完整、
已签名的 .app**。以后只需一条命令，桌面图标与 `/Applications/Gridora.app` 会一起更新：

```bash
./build.sh release --install        # 构建并安装
./Scripts/install.sh               # 已构建好时，只做安装
./Scripts/install.sh /path/to/Gridora.app   # 安装指定的新包
LAUNCHOS_REFRESH_DOCK=1 ./Scripts/install.sh  # 顺便重启 Dock 刷新固定图标
LAUNCHOS_FORCE_INSTALL=1 ./Scripts/install.sh # 即使版本相同也强制替换
```

`Scripts/install.sh` 做四件事：旧包**移到** `/tmp/Gridora-install-<时间戳>/` 备份（绝不就地
覆盖 —— 覆盖会残留旧资源破坏代码签名）、用 `ditto` 把新包复制到全新路径、清 xattr 后 adhoc
重签并验签、刷新 LaunchServices 与 Spotlight 索引；最后断言桌面包存在、可执行、图标齐全、
二进制 SHA 与源包一致。**绝不修改 Dock 偏好与 `state.json`。** 手工把新包拖到桌面覆盖虽然也能
替换，但建议走脚本，避免 Finder 合并目录留下旧资源。
`~/Desktop` 会被 Finder 反复附加 `FinderInfo/fpfs#P/macl`，`codesign --verify --deep --strict`
偶发 `resource fork... not allowed`；Gatekeeper 实际走的非 strict `--deep` 始终通过，不要据此判包坏。

## 功能

### 原版复刻

- **全屏启动台**：覆盖菜单栏与 Dock 的无边框窗口，Esc 或热键退出。
- **图标拖拽跟手**：拿起图标有放大、阴影与轻微倾斜；拖动时其余图标 iOS 式实时让位。
- **拖拽建文件夹**：把一个图标拖到另一个图标中心，松手自动合成文件夹；文件夹可打开、
  重命名、解散、移出成员。拖到图标**间隙**＝纯重排，拖到图标**中心**＝合并为文件夹
  （合并目标在其槽位画白色圆环提示；判定用拖拽开始时的布局快照，目标不会在手下「逃跑」）。
  命中统一走 `GridMetrics.index(at:)`，四边独立边距下也不会算到隔壁格子。
- **文件夹打开（macOS 15）**：从被点击的文件夹图标位置放大展开，背后壁纸与网格做系统材质
  虚化，面板略高于屏幕中心、多页用圆点页码；点面板外空白处或 Esc 收起，图标仍可拖回网格。
  面板本体在 macOS 26+ 使用系统液态玻璃（旧系统退回半透明材质），与搜索玻璃**分开调节**：
  开关、风格、着色（0–75%）、圆角（8–36pt）、背板压暗（0–60%）都在「设置 ▸ 外观」，
  关掉后回到原来的近黑实底，白字仍可读。
- **自然滚动翻页**：触控板双指左右滑、鼠标滚轮都可翻页，带橡皮筋与回弹吸附。
- **拖到屏幕边缘翻页**：拖动图标停在左右边缘 0.4 秒自动翻到相邻页。
- **键盘**：方向键在网格中定位，Return / 空格打开；Home/End、PageUp/PageDown、
  ⌘1…⌘9 翻页。⌘← / ⌘→ 默认翻页，四项快捷键（显示启动台 / 前一页 / 后一页 / 打开搜索）
  都能在「设置 ▸ 通用 ▸ 快捷键」里录制；**显示启动台可以设成 F3 这样的单独按键，不需要组合键**。
- **搜索**：默认 ⌘F（设置 ▸ 通用 ▸ 快捷键可录制组合键），支持中文名、拼音全拼与首字母
  （如 `wx` → 微信），↑↓←→ 选择、Return 打开；「在网格上直接输入字母打开搜索」默认关闭，
  可在设置里开启。关闭后首字不再注入到尚未创建的输入框，中文输入法不会丢字。
  查询按所有 Unicode 空白分词（含全角空格 U+3000），单字符 ASCII 的子串命中降权，
  避免拼音前缀匹配被无关英文 App 压下去。
- **右键菜单**：打开、在访达中显示、**移动到文件夹**（子菜单列出全部现有文件夹，可跨页，
  也能在文件夹内部把成员移到另一个文件夹；来源只剩 1 个 App 时按 macOS 15 自动解散）、
  移到上一页 / 下一页、重命名 / 解散文件夹、隐藏。
- **点击空白回桌面**：点图标才打开 App，点空白处直接收起启动台（与 Launchpad 一致）。

### 增强功能

- **纵向滚动模式**：设置里可切换横向分页 / 纵向滚动，滚轮与滑动手势自动跟随。
- **隐藏不常用 App**：右键隐藏；或按闲置天数自动收进隐藏区。隐藏的 App 不出现在网格
  和搜索里，随时从「已隐藏的 App」恢复（恢复后会被保护，不再自动隐藏）。
- **自定义网格**：每行 4–9 个、每页 3–7 行、图标大小 78%–140%、可隐藏文字标签，
  改动即时生效并自动保存；「App 区域边距」四边独立（0–18% 按较短边换算）。
  图标 pt 读数按当前格子的可用高度实时换算，百分比才是滑块值。
- **外观**：低彩度近黑冷调的程序化背景（不读取桌面文件、不弹权限框）；可选模糊桌面壁纸；
  背景模糊度与暗度可调；搜索态与文件夹面板的液态玻璃各自独立可调（开关、风格、着色、
  圆角、压暗），设置页内含与真实表面共用同一材质的实时预览，改任一参数不会牵动另一处。
- **滚动手感**：滚动速度 0.4×–2.0×、反转方向开关、鼠标滚轮「行数」可调（1–8 格翻一页）。
- **分组式设置面板**：左侧 通用 / 外观 / 布局 / 应用位置 / 已隐藏 App / 同步 / 关于
  七个分类，浅色分组卡片、右下「完成」按钮；分类记忆上次浏览位置。设置页白底＋系统蓝
  是有意约定（主界面与官网才是近黑冷调），控件统一具备悬停／按下／键盘焦点反馈。
- **开机自动启动**：设置里一键开关（SMAppService，macOS 14+ 生效）。
- **应用位置扩展**：设置里可添加 / 移除自定义 App 文件夹（例如外置硬盘目录），
  保存后自动重扫描。
- **Dock 常显**：启动台窗口层级位于 Dock（kCGDockWindowLevel=20）之下，打开启动台、
  从启动台启动 App 时 Dock 始终可见可交互；网格自动为 Dock 留出底部内边距，
  菜单栏则由一层点击穿透的盖条视觉隐藏（无法用 presentationOptions，该接口在本机
  macOS 26.2 会死锁主线程）。
- **多屏**：每次唤起时按鼠标所在屏幕铺满。
- **失焦自动收起**：切到别的 App 时自动隐藏。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 显示 / 隐藏启动台 | ⌃⌥Space（备用 ⌃⌥L、F4） |
| 关闭 / 回桌面 | Esc |
| 搜索 | ⌘F（默认，设置里可改；网格字母直达默认关闭） |
| 打开选中项 | Return / 空格 |
| 网格内移动选择 | ↑ ↓ ← → / Tab |
| 上一页 / 下一页 | PageUp / PageDown，⌘⇧← / ⌘⇧→ |
| 第一页 / 最后一页 | Home / End |
| 跳到第 N 页 | ⌘1 … ⌘9 |
| 设置 | ⌘, |
| 已隐藏的 App | ⌘⇧H |
| 重新扫描应用 | ⌘R |

## 数据

- 状态文件：`~/Library/Application Support/com.vex.launchos/state.json`
  （页面布局、文件夹、隐藏列表、使用次数、设置）。
- 使用独立目录，避免和系统里同名的 LaunchOS 互相覆盖。
- 删除该目录即可恢复首次启动状态；设置面板里也有「重置全部设置」。

应用扫描 `/Applications`、`/System/Applications`、`/System/Applications/Utilities`、
`~/Applications` 及其子目录，加上设置「应用位置」里添加的自定义文件夹，
跳过 `LSUIElement` / `LSBackgroundOnly` 的后台程序。

## 开发

- 纯 SPM 工程，无 Xcode 工程文件：`swift build` 即可编译。
- `./build.sh [debug|release]` 组装 `.app`、写入 `Info.plist`、拷贝图标并做 ad-hoc 签名。
- 图标：`swift Scripts/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`。

### 调试参数

```bash
open build/Gridora.app --args --self-test     # 交互引擎自检，结果写到 /tmp/launchos-debug.log
open build/Gridora.app --args --demo-search   # 打开搜索示例
open build/Gridora.app --args --demo-settings # 打开设置面板
open build/Gridora.app --args --demo-hidden   # 隐藏 5 个 App 并打开隐藏区
open build/Gridora.app --args --demo-folder   # 合并前两个图标为文件夹
open build/Gridora.app --args --demo-drag     # 停留在拖拽中间态便于截图
open build/Gridora.app --args --demo-vertical # 切到纵向滚动模式
open build/Gridora.app --args --panel-visibility-probe  # 量设置面板/顶栏可见性与网格宽度断言
```

`--self-test` 会打印拖拽前后的索引、文件夹合并、搜索过滤、翻页、滚轮增量、
图标命中测试与隐藏数量；加 `LAUNCHOS_DEBUG=1` 可让窗口生命周期日志写入
`/tmp/launchos-life.log`。

`--merge-probe` 是文件夹交互的回归入口（需配 `LAUNCHOS_STATE_DIR` 隔离 state）。除了双向
合并 / 拖出 / 满页级联 / 重排（A–H），还固定了两组回归用例：

- **I 组**：把 `gridInsets` 临时设成非零四边边距再跑合并。历史上 `probeCell` 自己算格子时
  漏减 insets，零边距用例全绿、真实布局却完全无法合并 —— I 组专门防这个假阳性。
- **J 组**：右键「移动到文件夹」的网格移入、文件夹间移动、来源解散与重复移入拒绝。

`--folder-glass-probe` 从 `model.openFolderID` 这个真入口打开一个真实文件夹，A/B 切换
文件夹玻璃开关：输出 `/tmp/launchos-folder-glass.log`，含渲染树的
`CABackdropLayer` / `SDFPortalLayer` 计数差、开与关各 1 秒的帧采样、参数透传与关闭路径。
只有玻璃层数量真实下降才算 PASS，避免「写了布尔值却没换材质」的假阳性。

## 布局同步（iCloud Drive）

设置 → 同步 → 「同步图标摆放位置」。默认在
`~/Library/Mobile Documents/com~apple~CloudDocs/LaunchOS/LaunchOS-layout.json`
保存一份布局快照，由 iCloud Drive 负责在 Mac 之间传输；也可改用任意云盘目录。

- 只同步 `pages / hidden / manualHidden / pinned`（图标顺序、分页、文件夹、隐藏列表）；
  外观、壁纸、滚动速度、usage 属于本机设置，不上云。
- App 是 ad-hoc 签名、无 iCloud entitlement，因此走「iCloud Drive 文件」而不是 CloudKit
  容器：不需要开发者账号、不需要登录态 API，也不改 bundle 签名方式。
- 读写一律经 `NSFileCoordinator`（写用 `.forReplacing` 原子替换），避免多 Mac 并发写
  产生冲突副本或丢改动。
- 开启「优化 Mac 储存空间」时，云端文件可能只剩 `.LaunchOS-layout.json.icloud` 占位符。
  此时显示「正在从 iCloud 下载」并**暂停所有上传**，防止本机旧布局覆盖云端；下载落地后
  按 `updatedAt` 自动决定采用云端还是本机。
- 上传失败会标记并在下一个 12 秒轮询自动重试；设置页直接显示 iCloud Drive 是否连接。
- 「立即上传本机布局」= 强制以本机为准；「从同步文件恢复」= 强制采用云端文件。
- 「更改同步文件夹…」和「在访达中显示同步文件夹」都走 `Support/FilePanels.swift`：
  前者把 `NSOpenPanel` 抬到 `statusWindow+2`、激活 `.accessory` App 并置 `isPicking`，
  否则面板会被启动台盖住且随 `quitOnHide` 一起退出；后者在访达中选中快照文件。
- **所有选择器必须用 `panel.begin { … }`，禁止 `runModal()`**：实测 `runModal()` 会把
  `prepare()` 设好的 level 27 压回 level 8，低于主窗口 19 和菜单栏遮盖层 26，面板虽然
  visible/key 却被自己 App 的窗口盖住 —— 按钮看起来「点了没反应」。`begin()` 保留
  armed level 且不阻塞主线程，让 `NSApp.activate` 有机会完成。

诊断（默认关闭、写完日志自退，必须配隔离目录）：

```bash
mkdir -p /tmp/los-state /tmp/los-sync
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --icloud-sync-probe
# 面板配置（不覆盖真实按钮路径）
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --sync-folder-probe
# 真实按钮入口：驱动 LayoutSync.chooseFolder() 本身
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --picker-path-probe
```

`--icloud-sync-probe` 输出 `/tmp/launchos-icloud-sync.log`，断言 A 协调写、B 占位不覆盖、
C 下载恢复、D 跨 Mac 拉取、E 默认目录识别为真实 iCloud Drive 路径。
`--sync-folder-probe` 输出 `/tmp/launchos-sync-folder.log`，只验面板**配置**（level、
目录模式、`isPicking`），它用 `begin()` 造的对照面板，**不能证明按钮可用**。
`--picker-path-probe` 输出 `/tmp/launchos-picker-path.log`，驱动真实 `chooseFolder()`
并断言 `duringLevel > 主窗口/遮盖层`、非阻塞、`isPicking` 武装与释放；无 GUI 会话时
`panelKey=false` 属环境限制（已验证可用的壁纸选择器同样如此），不作为硬判据。

## App 区域边距（四边独立）

设置 → 布局 → 「App 区域边距」有**上 / 下 / 左 / 右**四个独立滑块，每档数值按页面较短边的
比例换算成 pt 显示。四边分别影响 `GridMetrics` 的网格起点与格子尺寸：

- `top` / `left` 移动网格原点，`bottom` / `right` 只压缩远端可用空间；
- 绘制（`center(of:)`）与命中（`iconIndex` / `contains`）统一走 `GridMetrics.insets`，
  不会出现「看得见点不到」的错位；
- 数据结构 `Settings.gridInsets`（`GridInsets`，四边 fraction）是**唯一真源**。
  旧字段 `gridInset` 保留为兼容镜像，始终等于四边平均值，让旧版本打开新 `state.json`
  仍能得到合理边距；
- 老 `state.json` 只有 `gridInset` 时，解码会自动扇出到四边，渲染结果与旧算法
  `size - 2*inset` 逐点一致（探针 A2 实测 `cellW=257.74 / cellH=149.23` 完全相等）。

诊断：

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --edge-inset-probe
```

输出 `/tmp/launchos-edge-inset.log`，断言 A 老配置扇出、A2 升级后几何不变、B 四边独立
（用 `center - cell/2` 反推**网格原点**，格子中心会随格宽/格高变化，不能用来区分 top/bottom）、
C 非对称四边的命中与边界、D 持久化往返。

### 外观层（纯函数断言）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --appearance-probe
```

输出 `/tmp/launchos-appearance.log`：A 预览快照随 5 个玻璃参数变化且同参数稳定、
B0 先用旧品紫／紫证明检测器能抓到违规、B1 背景冷色彩度 ≤ 0.45、B2 仅一个低权重暖色、
C 滑块范围与界面文案一致、D Reduce Motion 降级、E 焦点圈与浮层圆角 token、F 七个分类。
G 组固定文件夹玻璃的 5 个独立参数：快照随每个值变化、与搜索参数互不串扰、默认圆角等于
`DesignTokens.panelRadius`，并用真实 JSON 往返验证持久化、越界 clamp、损坏枚举回落和
老 state 缺键时的默认升级。

`Views/DesignTokens.swift` 是颜色／圆角／字号／发丝线的唯一真源：主界面近黑冷调
`#0B0D11` ＋唯一信号橙 `#FF5C35`（约 10%），设置页白底＋系统蓝是既定例外。
`Views/AppearancePreview.swift` 的预览胶囊直接复用 `SearchGlassPanel`，不另写材质；
`Views/SettingsButtonStyle.swift` 统一悬停／按下反馈，动效时长统一走 `Motion.quick`，
Reduce Motion 下全量降级。新增颜色先加进 `DesignTokens`，组件内不再写第二份色值。

### 搜索快捷键与命中（纯函数断言）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --search-hotkey-probe
```

输出 `/tmp/launchos-search-hotkey.log`：A 默认 ⌘F、A2 自定义组合 Codable 往返、B 老 state
升级（字母直达默认关）、B2 损坏组合回退、C Unicode 空白分词（含全角空格 U+3000）、
D 单字符命中排序（用改动**前**的评分链作负例，证明检测器会 FAIL）、E 真 `handleKey` 的
热键／开关／搜索态稳定性、F 与全局快捷键的冲突检测。

`Model/KeyChord.swift` 是所有组合的唯一真源（`SearchHotKey` 只是兼容别名），
`Support/HotKeyRecorder.swift` 负责录制，录制期间 key monitor 主动让路。菜单「搜索 App」
**不设 `keyEquivalent`**：否则 AppKit 会在 key monitor 看到自定义组合之前先吞掉按键。
四个角色互相排斥，损坏 / 冲突的 state 值会按优先级回退到默认或备用组合。

### 自定义快捷键（真入口断言）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --launcher-hotkey-probe
```

设置 ▸ 通用 ▸ 快捷键可录制**显示启动台**、**前一页**、**后一页**、**打开搜索**四项：
点「更改…」后直接按一个按键（Esc 取消），ⓧ 恢复单项默认，底部可一次恢复全部。
**显示启动台支持单独按键，不需要组合键**：F3 等 F1–F15 功能键、字母、数字、空格都可以；
其余三项仍需 ⌘ / ⌃ / ⌥ / ⇧ 修饰键或 F1–F15 功能键。Esc、纯修饰键、非法键码、系统保留组合
（⌘Q / ⌘Tab / 菜单 keyEquivalent）与四项之间互相冲突的组合都会被拒绝，并给出原因。
单键会全局占用该按键：进程常驻时，其他 App 与启动台自己的搜索框都无法再输入这个字符。
改动即刻生效，无需重启：Settings 写入 → `LauncherModel.onHotKeysChanged` →
`AppDelegate.applyLauncherHotKey()` → Carbon `RegisterEventHotKey` 先注销旧键再注册新键，
状态栏菜单标题同步更新。

默认启动键仍是 `⌃⌥Space`，且在**未自定义**时保留旧版内置的 `⌃⌥L` / `F4` 备用组合，
所以老 `state.json` 升级后按键习惯完全不变；一旦录制自定义键，备用组合自动释放。

**关闭启动台后仍可随时按键唤起**：`quitOnHide` 默认改为 `false`（设置 ▸ 通用 ▸
「关闭启动台时彻底退出进程」可显式改回）。Carbon `EventHotKey` 属于注册它的进程，
旧的「隐藏即退出」会让 F3 在关闭后彻底失效；现在进程以 `.accessory` 常驻，
没有 Dock 图标、运行点或菜单栏接管，点 Dock 图标仍走已有的
`applicationShouldHandleReopen` 开/关切换。老 `state.json` 没有
`residencyChoiceVersion` 标记时，其出厂 `quitOnHide: true` 会被一次性升级为常驻
（不视为用户的显式选择）；写入过新键的 state 完全尊重用户设置。

输出 `/tmp/launchos-launcher-hotkey.log`：A 默认四键 / 裸 F3 / 单键标签映射 / 非法键码与
纯修饰键拒绝、B 老 state 升级 / 自定义与裸键往返 / 损坏与 null 回退 / 角色冲突解决、
C **真入口** Carbon 注册（默认 3 组合 → 自定义 F3 → 裸 A / 裸 Space 单键，均断言
`status=0`、`active=1` → 恢复默认）、D 真 `handleKey` 的自定义翻页键替换硬编码、单键不再被
网格当作字母或空格、搜索键不回归、E 录制规则、F 录制器武装／释放、G 四项与裸键 Codable 往返。

### 常驻与 macOS 15 打开／关闭动画（真入口断言）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --residency-probe
```

**动画**：出厂 `OpenAnimationMode.fade` 沿用 macOS 15 Launchpad —— 主窗口与菜单栏遮盖层
只做 alpha 淡入（0.24s easeOut）／淡出（0.20s easeIn），图标网格不缩放、不位移，
content layer 保持 identity。`LauncherView` 里原有的 `scaleEffect(1.025)` / `offset(y: 10)`
已删除：纯淡出时它们会让所有图标在第一帧可见地跳一下。SwiftUI 树仍只变化一次，
中间帧全由 CoreAnimation 合成，冷启动 44–166 ms 长帧的根因没有被重新引入。
旧中心扩散保留为 `LAUNCHOS_OPEN_ANIM=scale` 单变量 A/B 对照与回退开关，
`legacy` / `none` 不变；Reduce Motion 下两个时长都降到 0.001s。

输出 `/tmp/launchos-residency.log`：A 出厂默认 / 老 state 一次性升级 / 显式设置保真 /
Codable 往返、B `ResidencyPolicy` 四条决策、C 启动时 Carbon 真注册、D fade 默认与时长 /
content layer 恒等 + 旧 scale 对照可检出、E **真入口** `hideLauncher()` 后进程仍存活、
窗口隐藏且热键仍注册、F 调用真 `GlobalHotKey.handler` 后窗口重新淡入且 layer 仍恒等、
G/H 再次隐藏后 `applicationShouldHandleReopen` 能把它再打开。

### 品牌显示名（纯函数断言）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --brand-probe
```

输出 `/tmp/launchos-brand.log`：A 两个 name 键与版权行都是 Gridora、B 可执行名 / bundle id /
iCloud 快照名仍是原值、C 菜单与关于页与状态栏文字全部来自 `AppBrand` 且无旧名、
D 恢复面板提示与备份默认文件名、E0 用旧字符串证明检测器会 FAIL、
F 硬断言 `FileManager.displayName(atPath:)` 与 bundle 文件名都是 Gridora
（Finder / Dock 实际显示的名字跟文件名走）。

`Resources/Info.plist` 是界面文案真源，`Support/AppBrand.swift` 把它派生成所有可见字符串。
**以后改名要同时改三处**：Info.plist 的 `CFBundleName` / `CFBundleDisplayName`、
`build.sh` 与 `Scripts/install.sh` 里的 `.app` 文件名、Dock 固定项的 `_CFURLString` 与 `file-label`；
**不要全局替换 `LaunchOS`**（bundle id、可执行名、state 目录、云端快照都得留着）。

## 结构

```
Sources/LaunchOS/
  App/        Main.swift, AppDelegate.swift, GlobalHotKey.swift
  Model/      Models.swift, LauncherModel.swift, AppScanner.swift, StateStore.swift,
              KeyChord.swift, SearchHotKey.swift (兼容别名), ResidencyPolicy.swift
  Views/      LauncherView / PagerView / TileView / 四个浮层 / 组件 /
              DesignTokens / AppearancePreview / SettingsButtonStyle / SearchGlass
  Support/    DebugHarness / AppearanceProbe / BrandProbe / SearchHotKeyProbe /
              LauncherHotKeyProbe / ResidencyProbe / AppBrand / HotKeyRecorder /
              FrameProbe / FilePanels / WindowReveal
```

- 所有指针交互（点击、拖拽重排、滑动翻页、边缘翻页）都由 `PagerView` 上的单个
  `DragGesture` 驱动，图标本身只负责悬停与右键菜单，避免手势冲突。
- 网格布局每次按窗口尺寸和列/行数重新计算，`reflowed` 保证页面容量与翻页一致。
