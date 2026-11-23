# Filetor Pro 开发与验证

这是由 Doithoo 持续维护的 Filetor Pro，基于 David Praznik 的 Filetor。保留上游原生 SwiftUI / AppKit 实现。更新使用原生 Sparkle 组件，更新说明采用纯文本，没有加入 WebView 或常驻后台服务。代码及产品版本发布在自己的 `Doithoo/Filetor-Pro` 仓库，没有向上游提交 PR。

## 使用重点

- **文件夹就地展开**：切换到列表视图，点击文件夹左侧小三角。右方向键展开，已展开时进入第一项；左方向键折叠，或选中上层文件夹。View 菜单支持展开所选文件夹和全部折叠。筛选、搜索和标签查询结果保持平面列表。
- **独立窗口**：`⌘N` 新建窗口，各窗口的目录、标签页、选择和撤销记录独立；文件夹右键菜单可在新窗口打开。
- **标签页**：`⌘T` 新建、`⌘W` 关闭、`⇧⌘T` 恢复；`⇧⌘[` / `⇧⌘]` 切换。拖动标签页调整顺序。标签栏始终显示，每个窗格只保留一个固定在标签栏右侧的“＋”；路径栏不再重复显示新建按钮。
- **恢复状态**：保存每个窗口的双栏状态、目录、标签页、排序、视图、隐藏文件选项和展开目录。首次打开时恢复上次工作区；关闭标签页后重新打开会恢复其状态。
- **Finder 标签**：保留原生标签功能；更改前重新读取磁盘标签，避免旧缓存覆盖外部更改。
- **条件搜索**：`⌘F` 打开本地搜索，按名称、类型、扩展名、修改时间和大小组合筛选；可选择当前文件夹或包括子文件夹。结果上方可编辑或清除条件。现有侧栏保存搜索仍通过 Spotlight 运行，此次新增的组合条件暂不保存为侧栏项目。
- **鼠标路径导航**：工具栏 **Go To**（前往）按钮弹出原生导航面板，包含当前目录子文件夹、侧栏收藏和最近访问。点击名称直接打开，点右侧箭头继续浏览，返回与上级按钮只改变面板中的浏览位置。路径栏各级目录的小箭头提供同样的子目录浏览，打开时使用对应窗格。`⇧⌘G`、路径输入、中文/空格/相对路径和 Tab 补全继续可用；输入文件路径会进入父目录并选中文件。
- **可编辑地址栏**：点击路径栏空白区域，直接选中完整绝对路径；可复制、粘贴和修改。输入匹配文件夹或文件，方向键选择、Tab 补全、回车或点击候选确认，Esc 或点击外部取消。中文输入组合期间不拦截输入法按键；无效路径保留原位置并显示错误。每个窗格右侧放大镜打开对应目录的条件搜索。保留原有面包屑点击和目录下拉。移除铅笔图标；长路径占满窄窗格时，搜索按钮左侧仍保留空白点击区及悬停提示。
- **导航偏好迁移**：升级时在工具栏前进/后退附近加入一次 Go To，保留全部原有条目的 ID、相对顺序和标签设置。以后通过自定义工具栏移动或移除会被保留。最近访问保存最多 20 项，可在 Recent 页清除；仅展开候选不记录访问。
- **显示偏好**：设置按用途分类；列表行高和图标视图大小单独调节。首次升级按旧的紧凑模式迁移行高；隐藏扩展名后重命名保留实际后缀。缩略图默认关闭，空格对普通文件夹使用内置预览，ZIP、常见代码/文本、Markdown、JSON 和 plist 同样使用内置预览；其他格式使用系统 Quick Look。

## 本地构建与回归

在仓库根目录运行：

```sh
python3 scripts/build.py --test
python3 scripts/test-updater.py
python3 scripts/build.py
open ".build/pro/Filetor Pro.app"
```

构建结果在 `.build/pro/Filetor Pro.app`。测试使用临时文件夹，包含文件操作、展开模型、递归文件监听、窗口隔离及原生 AppKit 按钮/键盘交互；界面截图在 `.build/pro/folder-expansion.png`。测试不会修改原版 Filetor 的设置或操作实际用户文档。

该脚本针对本机 Command Line Tools 和 macOS 26+，默认使用已安装的 26.5 SDK，以避开本机 27.x CLT 缺少 SwiftUI 编译插件的问题；可通过 `SDKROOT` 指定 SDK。需要支持默认 MainActor 隔离的 Swift 编译器。已有 Homebrew 静态 libwebp 时会链接它；否则使用系统可用的图像格式。应用图标来自仓库内的 `Resources/FiletorPro.icns`，保留原作者署名；构建不依赖已安装的应用。

Filetor Pro 使用固定 Bundle ID `com.doithoo.Filetor.personal`，设置和原版隔离。更新源固定为自己的 `Doithoo/Filetor-Pro` Release，不检查上游发布。首次构建会下载 SHA-256 固定的 Sparkle 2.10.1，后续使用已校验的本地缓存。0.6.2 起应用采用固定本机证书签名，更新包及更新清单另有 Ed25519 签名。本机构建不代表完成了其他 macOS 版本、Intel 或网络卷兼容性验证。

## Xcode 开发环境

本机已安装并初始化 Xcode 27.2（27B52），系统开发工具目录为
`/Applications/Xcode.app/Contents/Developer`。可直接打开 `Filetor.xcodeproj`，
选择 `Filetor` scheme 和 My Mac。Swift Package Manager 锁定 Sparkle 2.10.1
及 libwebp 1.6.0；Sparkle 的 JSON 工程精确版本字段使用 `version`。

无开发者团队的本机构建验证命令：

```sh
xcodebuild -project Filetor.xcodeproj -scheme Filetor -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-validation \
  -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
```

首次检出可先执行 `xcodebuild -resolvePackageDependencies -project Filetor.xcodeproj`。
Xcode 的 Debug 构建与已安装应用使用相同 Bundle ID；运行时会读取现有偏好，
日常自动验证继续使用独立设置和临时文件的 `scripts/build.py --test`。
发布脚本暂保留 26.5 SDK 基线；安装 Xcode 本身不代表升级应用版本或替换现有安装。

2026-11-23 验证：Xcode 27.2 / macOS 27.2 SDK 的原生 Debug 工程构建和
签名检查通过；Xcode 编译器配合发布脚本的 26.5 SDK，最终完整运行通过
131 项基础回归及 29 项真实窗口检查。过程中 UI 测试曾在预览、弹出面板
和地址栏焦点检查出现间歇性失败；27.2 SDK 尚未完成稳定的全套 UI 验证，
不据此切换正式发布的 SDK。原生构建仍有 Swift 6 并发迁移警告，项目继续
使用 Swift 5 语言模式。

## 项目目录与清理

| 路径 | 用途 |
| --- | --- |
| `Filetor/` | Swift 源码、应用配置和可编辑图标资源 |
| `Filetor.xcodeproj/` | Xcode 项目、共享工作区与依赖锁文件 |
| `Resources/` | 命令行构建所需的打包资源及来源说明 |
| `Tests/` | Swift 回归测试与更新测试应用 |
| `scripts/` | 当前构建、测试、签名与发布工具 |
| `docs/` | 开发、发布说明；`releases/` 保留历次版本记录 |
| `.build/pro/` | 当前应用构建、编译缓存及回归截图，可重新生成 |
| `.build/dependencies/` | 校验过的依赖缓存，删除后下次构建重新下载 |
| `.build/reports/` | 本地验证报告，不提交 Git |
| `.build/releases/` | 签名发布包、清单与校验记录，单独保留 |

根目录保留入口文档、许可证及项目配置。源码暂时保持现有布局：命令行构建会读取 `Filetor/` 下的 Swift 文件；将来按功能拆分子目录时，需要同时调整源码发现逻辑并验证 Xcode 与命令行构建。

日常整理遵循以下规则：

- 临时日志、截图和排查脚本放在 `.build/`；正式文档截图放在 `docs/images/`，仅保留文档实际引用的版本，需要时再创建目录。历史截图可从 Git 历史找回。
- 更新集成测试成功后自动清除临时应用、压缩包和测试目录，将八项结果及日志保存在 `.build/reports/updater.json`。失败或中断时保留临时目录并输出路径，方便排查；需要保留成功运行的诊断文件时使用 `python3 scripts/test-updater.py --keep-fixtures`。测试应用本身仍会注销并移除。
- 不运行构建或测试时，可删除 `.build/pro/` 和 Python 的 `__pycache__/` 来清理可再生产物；后续构建会重新生成。通常保留当前编译缓存，避免下一次构建变慢。不要直接把整个 `.build/` 当作缓存删除，其中可能仍有待发布的签名包或失败测试证据。
- 工具栏等偏好备份、安装回滚资料、仓库迁移备份存放在仓库外的 `~/Library/Application Support/Filetor Pro/Development Archives/`，按日期归档并附路径索引；不放进源码目录、不提交 Git。发布私钥继续由登录钥匙串管理。
- 保留许可证、原作者署名、图标源文件、`Package.resolved` 和历史发布说明。这些都是项目资料，不是构建垃圾。

当前入口统一为 `build.py`、`test-updater.py` 和 `release.py`，不再保留旧的 personal 构建别名。仅整理文档、开发脚本或本机产物时不递增应用版本，也不重新安装应用；产品行为变化才进入正常发布流程。

## 权限与签名

0.6.2 起安装包使用固定的本机证书身份，发布脚本与 Xcode 工程统一固定证书指纹，禁止发布流程退回临时签名。首次从旧签名迁移需要移除系统设置中旧的完整磁盘访问条目，再通过 Reveal Current App 定位当前安装包重新添加一次。授权由 macOS 管理，不能通过复制偏好设置继承，也不修改 TCC 数据库。固定身份的跨版本验证与实际授权保留验证分别记录，不将签名测试当作已验证权限。

权限提示区分授权探测失败和具体目录仍被拒绝；从系统设置返回时刷新状态并重试失败的废纸篓。实际应用进程会在 `~/Library/Application Support/Filetor Pro/Diagnostics/folder-access.json` 保存最小诊断，不保存任何废纸篓文件名或内容。发布与证书说明见 [UPDATES.md](UPDATES.md)。

## 自动更新

设置中的 **Check for updates…** 会检查自己的仓库，发现新版后可直接下载、安装并重启。**Automatically check for and install updates** 一个开关同时控制自动检查和后台下载，下载完成后退出应用即可安装。旧版按原“自动检查”开关迁移，原来关闭的保持关闭；手动检查入口始终保留。文件操作仍在运行时不会直接重启。工具栏、侧栏、列宽及工作区保存在同一设置身份下，更新不会重置。

修改代码并提交 Git 并不等于发布了安装包。后续完成改进后需要使用标准版本号（如 `0.3.1`、`0.4.0`）并递增 build，构建、签名并发布一个递增版本，应用才会检测到新版。已提供 [发布脚本与操作说明](UPDATES.md)，无需手动拖拽替换应用，也无需提交上游 PR。

## 已改进的可靠性

- 检查目录自身、后代路径和符号链接别名，阻止递归自复制；树形多选自动去掉已被选中父目录包含的项目。
- 复制先写临时目录，成功后再放到目标名称；取消或失败清理未完成的暂存结果。
- 替换操作先保存旧目标，新副本提交后才移除移动源。旧目标优先放入废纸篓；不支持废纸篓时保留 `.filetor-backup-*` 同目录备份。移动源先原子改名再清理；清理失败会报告 `.filetor-moved-*` 剩余文件的位置，完整数据仍在目标目录。
- 批量重命名通过临时名称处理交换和大小写变更，任一阶段失败会尝试恢复原名；恢复失败时报告可找回文件的路径。
- 复制、移动和撤销/重做通过全应用队列协调。取消等待中的重名确认会释放任务，不再挂起。
- 复制、移动、创建、移入废纸篓和图像优化的撤销保存每项进度；部分失败可重试，重做不会直接覆盖后来出现的同名文件。
- 压缩跨子目录选择时保留共同父目录下的相对路径；重复文件检查不会将读取错误误作文件结束。
- 文件夹比较说明仅比较可见常规文件的大小、时间，不宣称已经验证内容相同；双向同步对相近时间但大小不同的项目默认跳过，等待手动决定。

## 轻量化与体验

空格、工具栏和右键菜单共用 `SystemQuickLook` 路由，`BuiltinPreviewKind` 决定使用内置窗口还是系统预览。`BuiltinPreviewController` 管理普通文件夹、ZIP、代码/文本、Markdown、JSON 和 plist；未覆盖的文件继续使用 `QLPreviewPanel`，混合多选的系统文件使用 `QLPreviewView`。保留选择跟随、跨窗口接管、空格/Esc 关闭及关闭工作区释放预览。应用包和符号链接不作为可展开目录。信息侧栏仍仅显示缩略图和元数据。

`FolderPreviewReader` 使用最多 2 个后台操作逐层读取；单目录最多 3,000 项，整个预览树最多 10,000 项，截断时明确提示，不把读取子集当作完整列表。只统计当前层项目，不递归计算文件夹大小。展开时加载子目录，关闭或切换后取消操作并丢弃过期结果。隐藏项目开关只影响本次预览；刷新重新加载当前树。空目录、读取失败、磁盘不可用均有独立反馈。当前没有自动监听目录变动，使用刷新按钮更新；内置预览仅用于 Filetor Pro，不替换 Finder 的系统扩展，ZIP、代码和 Markdown 的内置预览从 0.8.0 提供。

目录及展开内容后台读取，切换路径后丢弃过期结果。只有可见标签页订阅递归文件事件；隐藏或关闭标签页时取消搜索、展开及目录大小任务。多个窗口显示同一目录时共享监听。列视图读取也转到后台，图标和列视图增加常用文件右键操作。

搜索增加短暂输入防抖，并在达到 5,000 条结果时明确提示缩小范围。应用包按文件打开，不再当作普通目录误入。

条件搜索在当前目录与递归扫描中共用匹配规则；列视图执行搜索时使用平面结果列表。文件夹导航在后台读取、排序，输入防抖 120 毫秒；下拉列表通过懒加载视图滚动查看全部子目录，关闭或切换后取消过期请求。包作为文件处理，浏览模式遵循窗格的隐藏文件设置。系统缩略图共享队列，最多 4 个请求并发；缓存上限 256 项 / 32 MB，身份包含路径、修改时间、文件大小及显示尺寸，视图移除时取消请求。

信息面板开关固定在工具栏最右侧，使用 `sidebar.right` 图标和开态高亮，预留宽度后再计算可移动项目的溢出。与设置及菜单共用 `app.showInfo`。原有 `info` 条目保留 ID 和位置，改为 Get Info（显示简介），要求选中文件或文件夹，复用 `app.getInfo` 打开 Finder 的独立简介窗口；不再控制信息面板。

侧栏 Favorites 末尾固定提供 Trash，打开当前窗格并保留前进/后退历史；外接磁盘的废纸篓通过右键菜单单独打开，不汇总为虚拟目录。选中文件后可用 Move Out… 选择移出位置，不读取 Finder 私有的原位置元数据，清空入口位于废纸篓横条及侧栏右键菜单，确认框标明磁盘与路径，回车默认取消。清空包含隐藏项目，不受筛选或选择影响；确认准备后新加入的顶层项目不在本次操作中，已选文件夹的内容则随文件夹删除。选中项目的立即删除入口覆盖列表、图标和列视图。macOS 拒绝读取时，列表、图标和列视图均显示完整磁盘访问权限说明及设置入口。

工具栏使用透明、不接管点击的 AppKit 视图注册原生 toolTip，覆盖普通按钮、禁用状态、前进后退、视图模式及搜索控件。开关提示随状态更新，不改变工具栏项目、顺序或文字标签偏好。新增 12 项检查验证原生鼠标点击、活动窗格隔离、导航返回、提示更新和设置保留，使用临时目录代替用户实际废纸篓。

清空和废纸篓内的选中删除复用全窗口写操作队列，提供顶层项目进度和停止操作；停止在下一项开始前生效，正在删除的文件夹可能需要完成当前操作。删除前重新核对废纸篓及项目身份，跳过已替换项目与重定向路径；失败按项目报告，部分文件夹内容可能已删除，不能撤销。符号链接只删除链接本身。新增 20 项临时文件测试覆盖删除边界、符号链接、确认取消、原生确认按钮、排队取消、部分失败及最终空目录，不清空用户实际废纸篓。

ZIP 预览只读取中央目录，支持普通 ZIP 和单卷 ZIP64，按层级显示名称、未压缩大小、类型、修改时间，悬停显示压缩大小；加密条目有标记，不请求密码或读取条目内容。中央目录读取上限 16 MB / 10,000 条记录，树上限 20,000 节点 / 64 层；达到上限明确提示。异常路径仅作为显示文本，重复记录保留，不解压到磁盘，不验证内容 CRC。多卷 ZIP 或加密目录会显示不支持/读取错误。

文本读取后台队列最多并发 2 项，打开文件时拒绝符号链接、设备和 FIFO。读取上限 1 MB，展示上限 160,000 个字符 / 10,000 行；切换或关闭取消并丢弃旧结果。UTF-8 及带 BOM 的 UTF-16/32 可用；不猜测其他编码。代码高亮是轻量词法高亮，非编译器级语法分析。JSON 校验后按原始 token 缩进，保留大整数、转义和键顺序；无效 JSON 显示原文与提示。二进制 plist 转成 XML，不提供原始二进制视图。

Markdown 用原生富文本呈现常见标题、列表、引用、代码块、粗体/斜体和行内代码，Source 可查看原始内容；不执行 HTML、不加载远程/本地图片、不激活链接，复杂表格和扩展语法可能保留文本形式。使用原生文本查找栏和复制；查找输入中的空格不会关闭预览。此阶段提供 Filetor Pro 内置能力，不改变 Finder，也不宣称覆盖 Looq 的所有格式。

## 当前边界

此版本优先完成本地文件浏览和安全操作，未引入 QSpace 的完整功能集合。展开功能只用于列表视图；图标、列视图的键盘、多选和拖放能力尚未与列表视图完全一致。

撤销记录仍仅在当前进程内保留，不提供崩溃后事务日志恢复。遇到没有废纸篓的卷时不要手动删除 `.filetor-backup-*` 或 `.filetor-undo-*` 文件，直到确认不再需要恢复。删除前核对与实际文件系统删除之间仍存在外部程序修改路径的竞争窗口；当前并非事务式或基于文件描述符的递归删除。外部程序同时修改文件、SMB/云盘特殊行为和进程被强制终止不在本地回归测试的保证范围内。

网络卷若不提供可靠的文件事件，可用 `⌥⌘R` 手动刷新。比较与同步仍是有限范围的辅助工具，未扩展成内容校验备份系统。

## 本机验证记录

- 2026-11-23：0.6.2 安装后由用户重新绑定一次完整磁盘访问。实际 GUI 进程确认权限探测与本机废纸篓枚举均成功。随后更改安装包内容并用同一证书重签，替换应用、重启，再恢复公开发布的正式包、重启；两次均无需重新授权，两个检查仍通过。最终安装包与公开发布包一致，工具栏/偏好保留。本次受控测试改变了代码目录哈希但保留证书指定要求，仅证明当前 Mac 上此更新方式的权限连续性。
- 签名专项 5 项检查及 Sparkle 更新集成 8 项检查通过，覆盖旧临时签名到固定证书迁移、固定证书更新和篡改拒绝。最小权限报告及替换验证记录仅保存在本机，不提交用户路径或数据。

- 278 项回归检查，覆盖文件操作、界面、更新设置迁移、跨窗口共享、原工具栏保留和后台写操作重启保护；包含文件夹/ZIP/文本进入内置预览、图片等保留系统预览、选择跟随、多选顺序、列视图子项、预览不改变文件选择、跨窗口交接和关闭释放检查。新增行高迁移、隐藏扩展名重命名、中文组合搜索、路径补全与导航选择、缩略图并发/取消/缓存失效及真实图像生成检查；鼠标导航检查覆盖工具栏迁移、逐层浏览、最近访问、取消、双栏隔离，并向原生窗口发送鼠标事件验证实际按钮和下拉操作。
- 另有 31 项真实 `WindowGroup` 导航检查，完整加载主窗口，覆盖鼠标打开、关闭后重开、侧栏显示、工具栏溢出和菜单备用入口，并确认系统工具栏保持隐藏；另覆盖右侧信息面板按钮连续开关、状态保存、显示简介入口独立、窄窗口溢出和空工具栏。地址栏检查覆盖完整路径选中、中文组合输入、Tab 补全、鼠标和键盘选择候选、无效路径、文件定位、窗格切换、外部点击取消及对应窗格搜索应用。`scripts/build.py --test` 和发布流程自动执行；单独运行可使用 `.build/pro/FiletorRegression --navigation-scene`。主窗口使用 SwiftUI 工具栏可见性控制，禁止通过反复设置 `window.toolbar = nil` 隐藏工具栏，以免原生弹出面板在打开时被销毁。
- 历史系统预览兼容性已检查 Looq 的文件夹、压缩包和代码预览扩展。0.7.0 起普通文件夹改走内置预览，不依赖这些扩展；0.8.0 同样内置 ZIP、代码/文本、Markdown、JSON 和 plist，未覆盖的格式继续依赖系统所选扩展。
- 更新专项测试在临时应用中实际执行下载、校验、替换和重启，验证偏好保留、旧名称/旧可执行文件升级到 Filetor Pro，以及自动后台下载后退出安装；另验证篡改更新包、篡改清单、无新版本和服务器失败分支。
- 优化构建完成，`codesign --verify --deep --strict` 通过。
- 体验确认后，Filetor Pro 已替换安装到 `/Applications/Filetor Pro.app`，保留 `com.doithoo.Filetor.personal` 身份和新的工作区状态；原版自定义工具栏（项目、顺序、文字标签）、侧栏、信息面板及文件列表列配置已迁入 Filetor Pro。Dock 原有位置指向 Filetor Pro；原版已移入废纸篓，`~/Applications` 中不再保留第二份安装。
- WebP 静态链接，运行时不依赖 Homebrew 动态库；Sparkle 框架随应用打包。
- 已检查展开列表截图。完整应用的跨进程 UI 自动化未运行（当前没有辅助功能自动化权限）；功能测试使用应用自身的 AppKit 控件进行。没有进行网络盘、长时间运行或内存压力基准测试。


## Archive actions (0.9.1)

`ArchiveMenuAction` is the common menu model used by the AppKit list and SwiftUI icon/column context menus. It exposes only native ZIP compression and supported extraction. `OpenWithApplications` uses Launch Services associations, filters stale installations, deduplicates canonical application paths, intersects handlers across multi-selection and prioritizes the default handler. No archive application names are hard-coded and no application preferences or default associations are changed. The manual Other picker is always available. Product-specific Keka Services integration was removed in 0.9.1.

`ArchiveOperations` uses macOS system tools without bundled archive engines. It distinguishes compressed TAR archives from raw GZIP/BZIP2 streams. ZIP creation and extraction run in a private staging directory under the captured destination and publish only on success using a non-overwriting move. Compound archive suffixes are removed from result directory names. Cancellation stops the active subprocess and removes the unfinished staging directory; completed batch results are retained. Standard input is closed so password prompts cannot stall the operation. System bsdtar's traversal and symlink protections remain enabled. Raw XZ, encrypted and multipart archives remain external-tool operations.

`startArchiveOperation` captures the originating pane/location and uses `TransferScheduler` across windows. The existing tasks UI shows indeterminate activity instead of a guessed byte percentage. The updater's existing active-operation guard also covers these jobs.

Run archive-focused regression checks with `python3 scripts/build.py --test --archive-actions-only`. Tests include Chinese names, multiple source folders, leading dashes, compound formats, raw streams, collisions, corrupt/encrypted archives, cancellation, metadata, traversal/symlink boundaries, shared menu availability, default application ordering, multi-selection compatibility and removal of stale application candidates. Live Launch Services discovery is checked separately for representative archive extensions without launching external applications.
