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
- **图标拖拽跟手**：拿起图标有放大、阴影与轻微倾斜。拖到**间隙**时其余图标实时让位
  （`DragSemantics.insertionSlot` 只在跨格／0.10s 节流窗口发布，松手点强制同步，
  预览与 `reorderDraggedTile` 的落点逐项相同）；拖到**图标 artwork** 上时网格保持冻结，
  合并目标原地高亮，不会在手下「逃跑」。
- **拖拽建文件夹**：把一个图标拖到另一个图标中心，松手自动合成文件夹；文件夹可打开、
  重命名、解散、移出成员。拖到图标**间隙**＝纯重排，拖到图标**中心**＝合并为文件夹
  （合并目标在其槽位画白色圆环提示；判定用拖拽开始时的布局快照）。
  命中统一走 `GridMetrics.index(at:)`，四边独立边距下也不会算到隔壁格子。
  单帧位移超过 36pt 的指针跳变不预览让位（物理上不是真实鼠标），但松手仍按终点重排；
  `LAUNCHOS_NO_LIVE_REFLOW=1` 可整体回退到「松手才重排」。
- **文件夹打开（macOS 15）**：从被点击的文件夹图标位置放大展开，背后壁纸与网格做系统材质
  虚化，面板略高于屏幕中心、多页用圆点页码；点面板外空白处或 Esc 收起，图标仍可拖回网格。
  **头部只有关闭按钮和文件夹名**：不显示 App 数量，也没有铅笔按钮 —— 名字本身就是重命名入口，
  **点一次**名称即可编辑（回车或右侧「完成」提交，Esc 取消；悬停时名字会亮起一层浅底提示可点）。
  **点图标才打开 App、也只有图标会被「选中」**：文件夹内点击与悬停命中都只认图标 artwork，
  点标签、格子四角、行列间隙既不启动也不点亮高亮（几何真源 `FolderGridMetrics.iconIndex /
  hoverIndex / artworkLocalRect`）。v1.6 之前整格 `.contentShape(Rectangle())` + `.onHover`
  还留在 cell 上，导致鼠标进格子范围就亮起选中块；实测旧命中面积 `224×146`、新命中
  `112×112`，误触发区域占整格 **61.6%**。现在 `FolderAppCell` 用 `onContinuousHover` 调
  同一个 `hoverIndex`，并用 `SelectionHighlightSurface` 渲染与主网格 / 搜索结果一致的高亮。
  **文件夹内部可以拖图标改顺序**：拖到另一个格子里松手即重排（拖拽时其他成员实时让位），
  配合滚轮／方向键／圆点切页还能把 App 拖到文件夹的另一页；拖出面板仍是放回主网格。
  **翻页与主界面完全一致（macOS 15）**：多页文件夹**横向滑动换页**，用的是主分页器同一套
  判定规则（`PagingRules`：拨动合并窗口、短挥阈值都按 `scrollSpeed` 缩放，一次手势最多一页）
  与同一条临界阻尼曲线（`Motion.page`）；滚轮、←/→、PageUp/PageDown、⌘←/⌘→、圆点都能翻页，
  文件夹打开时这些键不再翻被遮住的主分页器。**只有圆点，没有左右箭头** —— macOS 15 的文件夹
  从来不画箭头，圆点用的是主界面同一个 `PagingDots` 组件。`LauncherModel.folderPage` 是页码唯一真源。
  **全站共用一组液态玻璃参数**：搜索框、搜索结果、文件夹面板、网格里那个缩小的文件夹图标、
  **选中 / 悬停 App 时的高亮**，以及打开文件夹或搜索时铺满全屏的背景雾层，读的都是同一组
  「开关 / 风格 / 着色 0–75% / 圆角 6–36pt / 压暗 0–60%」，改一个滑块同步变；圆角是面板半径，
  搜索框按 58% 等比推导（24pt → 14pt），文件夹图标与高亮按各自尺寸等比缩放
  （出厂 24pt 恰好回到原来的 0.27 × 图标尺寸），着色映射到高亮填充与描边浓度，
  压暗映射成文件夹图标内层暗度。
  **全屏雾层由两个窗口共用一层**：主窗口（level 19）与屏幕顶部菜单栏遮盖窗口（level 26）
  都从 `BackdropFog.make(settings:state:)` 取同一个纯值，经 `BackdropFogSurface` 唯一渲染。
  以前主窗口叠 `ultraThinMaterial` + 黑压暗、顶部只画干净的壁纸模糊，打开文件夹时会出现
  一条明显的上下色带；现在 macOS 26 两边都是真玻璃雾，旧系统两边都退回材质，关玻璃两边
  都只剩压暗，拖 App 出面板时两边同时减到 10%。`--backdrop-fog-probe` 用两个窗口各自的
  layer 树作证（顶部 `backdrop 0→3 / portal 0→9`，关玻璃两树都归零），
  `LAUNCHOS_NO_FOG_UNIFY=1` 是单变量回退开关。
  **v1.6.2：两侧不再透出图标色斑**。上面统一的是雾的「参数」，但两个窗口的
  `glassEffect` 采样的**底图**仍不同：顶部窗口底下只有壁纸，主窗口底下还有整排
  App 图标，玻璃会把图标糊成彩色斑块（真机截图实测最上方彩度 2.9、两侧 8–15，
  亮度差约 17）。现在打开文件夹且未拖出时，主窗口雾层下会多画一块 `FogPlate`
  —— 与顶部窗口完全同源的 `BackgroundView(animate: false)`，把网格从玻璃采样里
  摘掉，整屏与屏幕最上方合成同一片干净灰雾；拖 App 出面板时 `plate` 立即置 nil，
  网格恢复可见以便放回。  仍是同一组五个 `glass*` 值、没有第六个设置键，
  `LAUNCHOS_NO_FOG_PLATE=1` 是单变量回退开关。
  **v1.6.3：消掉屏幕最上方那条深色带**。v1.6.2 只让主窗口画 `FogPlate`，
  菜单栏窗口的玻璃仍采到自己窗口（包含其后已被压暗的主窗口顶部），二次压暗
  —— 真机截图顶部 0–24px 亮度 71.4、下方 94–98，差 23 且一刀切。现在
  `MenuBarCover` 也用 `BackdropFogSurface(plateSource: .cover)` 画**同一份不透明
  plate**，两窗口层序统一为 `plate → glass → scrim`，玻璃采样目标一致；layer 树实测
  `coverLayers 100→125`、`plateRenders main=1 cover=1`。`coversGrid` 仍只对主窗口为
  true（只有它有网格）。`LAUNCHOS_NO_COVER_PLATE=1` 精确回到 v1.6.2 的硬色带，
  与 `LAUNCHOS_NO_FOG_PLATE=1` 相互独立，仍是五个 `glass*` 键。
  高亮是**纯值派生、不是 `glassEffect`** —— 主网格在光栅化页里，真玻璃会被完全扁平掉且
  实测 jank 涨到 9.75% / p95 17.98ms；`LAUNCHOS_NO_SELECTION_GLASS=1` 是单变量回退开关。
  设置页三个预览台与真机共用同一组值。
  真实玻璃画在页的 `background`（`drawingGroup()` 之外）：`glassEffect` 若放进光栅化页里
  会被完全扁平掉（实测 `CABackdropLayer=0`），而关掉光栅化又会让翻页 jank 从 1.8% 涨到 4.8%。
  页外的场景（拖拽视觉、隐藏 App、设置里的图标预览）由图标自己画同样的玻璃。
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
  背景模糊度与暗度可调；液态玻璃只有**一组全局参数**（开关、风格、着色、圆角、压暗），
  搜索、文件夹、文件夹小图标与选中 / 悬停高亮共用，设置页内含三个同步的实时预览台。
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

`--folder-icon-glass-probe` 保持**网格可见**（不打开文件夹、不进搜索），A/B 切换同一个开关：
输出 `/tmp/launchos-folder-icon-glass.log`，含页背景玻璃层的
`CABackdropLayer` / `SDFPortalLayer` 计数差、开与关各 1 秒帧采样、圆角映射与参数透传。
实测玻璃开 `backdrop 9 / portal 18`、关 `0 / 0`，两版静止 p95 都是 6.50ms；
`LAUNCHOS_FOLDER_ICON_NOPLATE=1` 是单变量对照／回退开关（关掉后玻璃层归零，探针按设计 FAIL），
`LAUNCHOS_FOLDER_ICON_NOGLASS=1` 则让小图标整体回到原材质。4 轮交替翻页 A/B：
玻璃开 1.80% / 6.50ms，关 2.00% / 6.51ms，无渲染回归。

`--folder-interaction-probe` 是文件夹／拖拽交互的回归入口，输出
`/tmp/launchos-folder-interaction.log`（需配 `LAUNCHOS_STATE_DIR` 隔离 state）。
全部走真入口，且**带真实四边边距**（`0.098 / 0.18 / 0.098 / 0.18`），防止历史上
「零边距 state 全绿、真机却不能用」的假阳性：

- **A 组**：`FolderGridMetrics.iconIndex` 只认图标 artwork，标签 / 格子四角 / 行列间隙 /
  尾部空格子一律 `nil`；`slot(at:)` 落点换算并 clamp 到当前页成员数。
  `A9–A12` 断言**视图层实际调用**的 `hoverIndex(atLocal:slot:count:)`（cell 本地坐标），
  `A13` 给出命中面积占比（实测 `coverage=0.384`，旧整格 `1.000`），`A14` 断言 9 个格子的
  hover 与 tap 共用同一几何，`A15` 断言视图定位用的 `artworkLocalRect` 就是图标方块而非整格。
  这补上了 v1.4 的盲区：当时只测纯函数，整格 `.contentShape` + `.onHover` 一直假绿。
  屏幕上的 hover 观感仍写 `NOTE` 标注需目测，不加恒真断言。
- **B / C / D 组**：从 `beginFolderDrag → updateFolderDrag → endFolderDrag` 这条真链路做
  面板内同页重排、跨页重排（拖的时候用滚轮／方向键切到文件夹第 2 页）、以及拖出面板回主网格。
- **E / F 组**：真 `NSEvent` 滚轮事件走 `handleFolderScroll`（一次一页、同向 burst 合一、
  反向立即响应、上下界 clamp、单页文件夹不动），`handleKey` 的 ←/→ 与 ⌘→ 只翻文件夹页、
  不动主分页器；`folderShouldConsumeScroll` 各状态分支。
- **G / H 组**：主网格让位预览的插入槽位、预览映射与松手重排逐项相等、合并目标出现时冻结、
  慢速拖拽过程中预览确实逐格推进；关闭文件夹后页码归零、滚轮交还主分页器。
  `LAUNCHOS_NO_LIVE_REFLOW=1` 时 G1 按设计 FAIL —— 这是探针本身的证伪对照。
- **I 组**：头部重命名的数据通路 —— `renamingFolderID` 置位（点名字的唯一副作用）、
  `renameFolder` 去空白、面板保持打开、文件夹页码与成员不变、空名字被拒绝、原名可往返。
  头部本身的像素（没有数量文字、没有铅笔按钮、单击即编辑）无法从 AppKit 侧断言，
  探针只写 `NOTE` 一行如实标注，绝不用恒真断言刷绿。

A 组还固化了一条与滑动分页直接相关的不变量：**每页宽度必须正好等于面板宽度**
（`A8 page width equals panel width`，实测 `grid=760 panel=760`）。页宽与视口不等时，
滑一页会停在两页之间或露出邻居的边。

帧率探针有三个单变量开关：`LAUNCHOS_DRAG_FPS=1` 用真实 120Hz 指针流（默认 2pt/帧）
代替翻页驱动，`LAUNCHOS_DRAG_FAST=1` 是「每帧跨一格」的极端压力负载，
`LAUNCHOS_FOLDER_FPS=1` 则打开一个真实多页文件夹并翻它的页 —— v1.5 的滑动分页会同时渲染
最多三页 3×3，代价必须实测：17 成员文件夹两轮实测 jank 0.7% / 0.9%、p95 均 6.50ms，
与主分页器（0.8% / 1.3%）持平，没有因为多渲染一页而变贵。
4 轮交替 A/B 实测：翻页 old 2.20% / 6.51ms vs new 1.95% / 6.50ms；
真实速度拖拽 让位开 1.10% / 6.50ms vs 关 1.00% / 6.47ms；极端负载 0.90% / 6.47ms vs
0.55% / 6.51ms。未加节流与高速保护前，极端负载曾到 42.4% / 18.99ms，故保留
0.10s 发布节流与 36pt 单帧位移上限。

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
G 组固定**那一组**全局玻璃参数（v1.5 起不再有两组）：一个滑块必须同时推动搜索、面板与图标
（`G3`，正是旧版「互不串扰」断言的反向）；`G4` 默认圆角等于 `DesignTokens.panelRadius` 且
搜索框按 58% 推导出 14pt；`G5` 真实 JSON 往返；`G6` 断言**已退役的十个旧键绝不会被重新写回**
state（否则下次启动迁移又会读到旧值）；`G7` 损坏枚举与越界值 clamp；
`G8` v1.4 文件同时含两组且取值不同时按文件夹组合并、`G9` 只有搜索组时按搜索组合并、
`G10` 一个玻璃键都没有时用出厂值。
H 组固定「缩小版文件夹图标」：与大面板五个参数逐项相同、默认圆角仍等于原图标的
`size × 0.235`、圆角缩放有上下界且单调、尺寸只影响几何、**只改着色也必须同时到达三处表面**
（`H5`）、`LAUNCHOS_FOLDER_ICON_NOGLASS` 回退开关被遵守。
**I 组（v1.6）固定第四表面「选中 / 悬停高亮」**：`I1` 出厂参数逐一复现主网格原来的
`0.27 × 图标尺寸 / 填充 13% / 描边 82% / 标签底 16%`；`I2` 只改着色时高亮与三处玻璃
**一起**变（一个滑块推四处）；`I3` 圆角 6/24/36pt 单调且有上下界；`I4` 关玻璃后高亮仍在
但无光晕无放大；`I5` `LAUNCHOS_NO_SELECTION_GLASS=1` 回退被遵守；`I6` 三处调用点用同一
Settings 构造出的值完全相等，没有第二套公式。
**J 组（v1.6.1）固定「一层雾、两个窗口」**：`J1` 顶部菜单栏窗口与主窗口由同一个
`BackdropFog.state` 映射出完全相等的 fog；`J2` 只改压暗时文件夹 / 顶部 / 搜索三处雾层
一起变（搜索的实底压暗按 45% 稀释）；`J3` 三个状态共用同一材质；`J4` 关玻璃只去材质、
保留压暗；`J5` 拖出面板时压暗与玻璃 tint 同时降到 10%；`J6` 没有面板时两边都不画雾；
`J7` `LAUNCHOS_NO_FOG_UNIFY=1` 回退被遵守；`J8` 编码后仍只有 v1.5 那五个 `glass*` 键，
雾层没有偷偷引入第二组设置。

### 全屏雾层（双窗口 layer 取证）

```bash
LAUNCHOS_STATE_DIR=/tmp/los-state LAUNCHOS_SYNC_DIR=/tmp/los-sync \
  build/Gridora.app/Contents/MacOS/LaunchOS --backdrop-fog-probe
```

输出 `/tmp/launchos-backdrop-fog.log`。必须走**真入口** `model.openFolderID`，
然后分别 dump 主窗口与菜单栏遮盖窗口的 layer 树 —— 纯值断言曾经让整格 hover 假绿，
所以 `B4` 断言顶部窗口**自己**的 `CABackdropLayer` 真的出现（实测 `backdrop 0→3`、
`portal 0→9`），`B8` 关玻璃后两棵树都归零，`B2` 同时核对遮盖窗口 level 26 存在且可见。
`B5` 用视图自己调用的 `BackdropFog.state` 证明两窗口参数相等，`B6/B7` 覆盖拖出面板与
搜索两个状态，`B10` 关闭文件夹后顶部雾层随之停用，`B11–B16` 是 v1.6.2 的干净背板取证、
`B17–B19` 是 v1.6.3 的两窗口同构取证（见下方 K 组）。
带 `LAUNCHOS_NO_FOG_UNIFY=1` 复跑时 `B4` 按设计断言顶部窗口 `backdrop=0`（旧行为），
是探针本身的证伪对照。

**K 组（v1.6.2）固定「干净背板」**：`K1` 两个窗口拿到同一份 `FogPlate`、
`K2` 拖出面板时 `plate=nil` 让网格露出、`K3` 搜索与关闭态都不画背板、
`K4` 关玻璃只去材质不影响背板、`K5` `LAUNCHOS_NO_FOG_PLATE=1` 回退被遵守、
`K6` 编码后不出现 `plate` / `fog` 新键。`--backdrop-fog-probe` 的 `B11–B16` 重新用
真入口打开真实文件夹：`B11` 靠 `FogPlateView.onAppear` 计数证明背板**真的渲染过**
（`plateRenders=1`），`B12/B13` 证明两窗口同值且参数来自 `model.fogPlate`，
`B14/B15` 覆盖拖出 / 搜索 / 关闭态，`B16` 核对回退开关。只测纯值就判绿是
v1.4 整格 hover 假绿的教训，这里必须有视图层证据。

**B17–B19 / K7–K8（v1.6.3）固定「两窗口同构」**：`FogPlateView.onAppear` 按窗口分别计数，
正常 `plateRenders main=1 cover=1`；`LAUNCHOS_NO_COVER_PLATE=1` 时 cover=0 而 main=1
（layer 树 `coverLayers 125→100`，精确回到 v1.6.2）；`LAUNCHOS_NO_FOG_PLATE=1` 时两者
都为 0（回到 v1.6.1）。`K7` 断言 cover 渲染不改变 `BackdropFog` 纯值，`K8` 断言编码后
不出现 `cover` / `source` 新键。打开文件夹时多一份全屏 `BackgroundView` 的代价，
必须用 `LAUNCHOS_NO_COVER_PLATE=1` 做单变量 FPS A/B，不能假设。

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
