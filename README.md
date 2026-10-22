# 艾泽拉斯 · 插件管家 0.2

原生 SwiftUI 中文 macOS 应用。优先提供国服时光服的本地管理工作流，同时支持正式服目录。**时光服是用途标记，不是自动识别或兼容性认证。** 已支持 GitHub 正式发布 ZIP 的下载与更新检查；CurseForge 及全站插件搜索、无人值守自动安装尚未实现。

## 已编译应用

交付包同时附带 `AzerothManager-v0.2.app.zip`，解压后双击应用即可在本机试用。源码使用 Xcode 26.6 实际编译通过，20 项离线核心测试通过，并完成真实 GitHub 下载与临时目录安装测试；详情见 `VALIDATION.md`。通用二进制支持 Apple Silicon / Intel，Intel 尚未做硬件运行验证。

应用为本机临时签名，没有正式发行签名或公证。

## GitHub 下载和更新（v0.2）

1. 在「在线插件」输入作者公开仓库，如 `owner/repo` 或其 HTTPS 仓库首页地址，点击「读取发布」。不是全站插件搜索；必须知道作者仓库地址。
2. 从最近 30 条发布中的正式版本选择客户端对应的 ZIP 附件。跳过草稿和预发布，不使用自动生成的源码 ZIP。
3. 点击「下载、检查并预览安装」。下载大小受 256 MiB 限制；服务器提供 SHA-256 时会校验，否则明确标注无远端摘要。ZIP 继续经过原有安全读取器。
4. 确认来源、文件名、目标目录及覆盖列表后，先备份再安装。来源并不保证客户端兼容；时光服必须由用户按作者说明选择。
5. 通过 GitHub 安装的插件会记录仓库、发布 ID、附件 ID、版本标签、客户端和文件内容指纹。在「已记录的 GitHub 来源」点击「检查更新」或开启「启动时自动检查」。自动检查默认关闭，不会静默下载或安装。
6. 发现更新后点击「查看发布 / 更新」，再次选择适用附件并确认。判断使用发布时间和 ID，同一发布下同名附件重新上传也会提示；不会按版本字符串排序猜测更新。

来源记录保存在目标 AddOns 根目录的 `.azeroth-sources.json`，随完整目录备份与恢复。手动 ZIP 覆盖、卸载任一属于同一发布包的文件夹时，会移除该包的整条跟踪记录，避免误认版本。手动导入、原先已有的插件不会自动绑定仓库。来源 JSON 损坏会明确报错并中止修改。

检查更新会计算已跟踪插件的文件指纹；本地修改或文件缺失会提示人工核对。用户显式确认安装仍可覆盖本地修改，覆盖前保留完整备份。同一仓库可提供多个客户端附件，管理器不推断或自动切换附件；改名或拆分的插件文件夹不会自动删除旧目录，需人工核对。

网络请求匿名访问公开 GitHub API，没有内置密钥，不需要提供 GitHub 密码。遵循 HTTPS，仅允许 GitHub 和其文件 CDN 重定向。GitHub 额度限制、仓库不可用、摘要失败和下载不完整会显示错误。下载与读取发布时可取消。当前为加载状态提示，不提供实时百分比。GitHub 访问速度取决于用户网络。

真实联网冒烟测试（只操作临时目录）：

```sh
AZEROTH_LIVE_GITHUB=1 swift test --filter GitHubSourceTests.testLiveGitHubDownloadAndStagedInstall
```

接口依据：[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)、[Release Assets API](https://docs.github.com/en/rest/releases/assets)。

## 环境与编译

- macOS 14 Sonoma 或更高，Apple Silicon / Intel。
- Xcode 15 或更高，包含 macOS SDK、Swift 5.9+。不需要第三方依赖或开发者付费账号。
- 打开 `AzerothManager.xcodeproj`，选择 **AzerothManager → My Mac**，按 **⌘R**。
- 工程使用本目录的 Swift Package `ManagerCore`，请保留完整目录结构。第一次打开等待本地包解析完成。
- 默认本机临时签名（`CODE_SIGN_IDENTITY = -`），未启用 App Sandbox，以便管理用户选择的游戏目录；未制作发行签名、公证、DMG 或 App Store 包。
- 如果本机签名设置不同，可在 Signing & Capabilities 中改为 Sign to Run Locally，或选择自己的 Team。

命令行编译（先切换到本工程根目录）：

```sh
xcodebuild -project AzerothManager.xcodeproj -scheme AzerothManager \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
open DerivedData/Build/Products/Debug/AzerothManager.app
```

本机可运行构建建议使用 Xcode 的 ⌘R；上面的无签名构建主要用于验证编译。

核心测试独立于 GUI，从工程根目录运行：

```sh
swift test
```

Xcode 应用 scheme 没有挂载测试目标；测试位于 Swift Package 中。可以单独在 Xcode 打开 `Package.swift` 运行包测试，或使用上面的命令。

## 先用演示目录试运行

1. 启动应用，点击「选择游戏目录」，选择随附的 `Demo/World of Warcraft`。
2. 从候选目录中选择 `TimeDemo/Interface/AddOns`，标记「国服时光服」。`TimeDemo` 只是演示名称，不是国服真实目录名。
3. 列表应显示「艾泽拉斯，你好」，版本 1.0.0。
4. 导入 `Demo/HelloAzeroth-2.0.zip`，确认将覆盖 HelloAzeroth；安装后版本应变为 2.0.0。
5. 在「备份与恢复」恢复安装前快照，应回到 1.0.0。
6. 选择插件，卸载，检查列表，再恢复快照。
7. 选择 `_retail_/Interface/AddOns` 并标记「正式服」，验证目录切换。

演示文件接口号 `000000` 是占位值，仅用于本地流程检查；不应安装进真实客户端。

## 管理真实游戏

先退出游戏，并停止其他插件管理器。应用会按运行应用名称尝试检测魔兽世界，但不能保证识别所有启动方式，因此仍应手动确认游戏退出。

可以选择游戏根目录、客户端目录或现有的 `Interface/AddOns`。扫描候选范围为所选目录及其下一层目录；特殊目录布局请直接选择 `Interface/AddOns`。如果 AddOns 不存在，请先运行游戏一次或手动创建。不根据 `_classic_` 等目录名武断认定时光服；请按战网实际启动路径确认。应用记住上次选择的路径与用途标记。

插件列表支持中文名称、文件夹、版本、作者、说明、接口版本与依赖。TOC 读取 UTF-8（含 BOM）和 GB18030；优先中文 `Title-zhCN` / `Notes-zhCN`。TOC 必须与文件夹同名，或以「文件夹名_」开头。正式服优先 `_Mainline.toc`；时光服优先通用 `.toc`，否则按名称选择。多个专用 TOC 的判断是有限启发式，所选和其他 TOC 文件名会显示在详情；**不宣称正确识别所有时光服专用格式，也不保证插件适配**。一个无法解码的 TOC 会让本次扫描报错，避免静默漏报。

导入支持插件目录直接打包、多个插件及常见外层目录包装。按完整文件夹替换，旧版残留文件会移除。不扫描或执行 Lua/XML；不会更改游戏内启用状态。依赖仅展示，卸载不会自动连带处理依赖。对缺少匹配 TOC 的目录不作为插件安装；嵌套于某插件内的库作为其内容一起复制。

## ZIP 安全边界

自带受限 ZIP 读取器，使用系统 zlib 解压，不调用 shell、不执行插件内容。

- 支持 Stored / Deflate、UTF-8 文件名、单卷普通 ZIP。
- 拒绝绝对路径、`..` / `.`、反斜杠、冒号、控制字符、空路径段、符号链接及其他 Unix 特殊文件。
- 拒绝大小写/Unicode 规范化冲突、重复条目、文件与父目录冲突、重叠的文件记录、本地与中央文件名/方法不一致、CRC 不符。
- 不支持加密、ZIP64、多卷或传统非 UTF-8 中文文件名；请重新以 UTF-8 ZIP 打包。
- 压缩包 ≤256 MiB，解压总量 ≤1 GiB，单文件 ≤128 MiB，最多 20,000 条，路径 ≤32 层，插件搜索 ≤8 层。
- 解压先进入随机临时目录，确认后才修改 AddOns。取消或失败会清理临时目录。安装前会再次检查链接。
- 拒绝目标路径及插件树中的符号链接。不支持链接式插件布局。

这些检查不等同于恶意插件检测。来自可信渠道的插件仍需要在游戏内确认其行为和兼容性。第一版使用内存缓冲单文件解压，接近限制的包可能占用数百 MB 内存；文件操作在后台执行。

## 备份、事务与异常恢复

默认备份位置：

`~/Library/Application Support/AzerothManager/Backups/<UUID>/`

每份包含 `snapshot.json` 和完整 `AddOns`。手动备份、安装前、卸载前、恢复前都会保存快照；备份失败即停止修改。只在当前目标目录下展示其对应快照。

**不包含 WTF、SavedVariables、账号资料或游戏文件。** 恢复时整体替换 AddOns，快照后新增的插件会移除；WTF 保持现状。设置恢复需要用户另行管理。备份不自动清理，可在 Finder 中删除确定不需要的整个 UUID 文件夹。

变更先在 Interface 下建立 `.Azeroth-next-<UUID>` 的完整副本，完成后把现有 AddOns 改名为 `.Azeroth-old-<UUID>`，再把新副本改名为 AddOns；提交失败会尝试回滚。操作可能需要「当前插件两份副本 + 一个完整备份」的额外磁盘空间，不提前承诺剩余容量足够；磁盘错误会报错并停止。

两次目录改名不是断电安全的单一事务；应用崩溃、系统断电或外部程序同时写入仍可能留下中间状态。第一版不做自动崩溃恢复。若 AddOns 缺失：退出游戏和管理器，在 Interface 中检查 `.Azeroth-old-*`，确认时间和内容后手动重命名为 AddOns；或从备份目录完整复制 AddOns 回原处。`.Azeroth-next-*` 是尚未提交的副本。**先保留全部相关文件再处理，不要混合多个快照。** 常规成功操作后旧副本会被清理；清理失败可能留有隐藏目录。

## 工程结构

- `App/AzerothManagerApp.swift`：SwiftUI 深色中文 UI、目录选择、确认对话框与串行后台操作。
- `Sources/ManagerCore`：TOC、扫描、安全 ZIP、安装预览、快照与事务。
- `Sources/ZipInflate`：系统 zlib 的小型 C 封装，严格检查输入/输出长度。
- `Tests/ManagerCoreTests`：元数据、目录、链接、ZIP、安装、卸载、恢复、失败回滚与更新占位测试。
- `Demo`：独立演示目录及真实 Deflate ZIP。
- `VALIDATION.md`：交付时实际验证情况。

GitHub 实现位于 `Sources/ManagerCore/GitHubSource.swift`。原 `UpdateProvider` / `UnavailableUpdateProvider` 保留为未接入平台的扩展占位，不用于 GitHub 工作流。CurseForge 仍需获批后另行接入。
