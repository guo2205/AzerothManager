# 艾泽拉斯 · 插件管家 0.4

原生 SwiftUI 中文 macOS 魔兽世界插件管理器，支持国服时光服和正式服。插件库显示本地已安装插件，自动检查新版；在线安装默认显示 CurseForge 热门插件。GitHub 安装入口已移除。

## 使用流程

1. 解压 `AzerothManager-v0.4.app.zip`，启动应用。在「设置与关于」保存自己的 CurseForge API Key。密钥只保存在本机登录钥匙串，不写入源码、偏好设置或来源记录。
2. 选择游戏目录或现有的 `Interface/AddOns`，核对客户端用途。国服时光服默认匹配官方分支 `WoW Wrath Titan Reforged`，正式服匹配 `WoW Retail`。也可手动选择其他客户端分支。
3. 插件库列出名称、文件夹、本地版本、作者、最新版本和状态。启动、重新扫描、安装完成后自动检查，也可手动点击「检查更新」。无需先通过本管理器安装插件。
4. 「有新版本」会显示「更新」按钮。点击后重新获取最新适配正式版，自动下载、校验、备份整个 AddOns，再整体替换插件包，完成后刷新状态。正常流程无第二次确认或版本选择。请先退出游戏。
5. 「已是最新」不显示更新按钮；本地版本比服务器较新时不主动降级；未知来源、缺少适配版本、分发限制、来源冲突、网络失败分别显示，不会冒充最新。
6. 在线页自动展示所选客户端的 CurseForge 热门插件，每页 20 个，支持搜索、翻页。点击「安装」自动安装最新适配正式版，不要求手选历史文件。
7. 可继续手动导入 ZIP、卸载插件、备份和恢复。导入/卸载/恢复仍会提示确认；在线安装与更新由按钮直接执行。所有修改前自动备份。

## 自动识别与版本判断

- 优先使用本机安装记录、CurseForge 精确代码指纹和 TOC 的 `X-Curse-Project-ID`。指纹基于 TOC/XML 引用代码与 Bindings.xml，按 CurseForge 的 MurmurHash2 协议计算；只发送数字指纹到官方 API，不上传源码、游戏设置或本地路径。
- 指纹能识别原先手动安装的插件；没有指纹匹配、没有项目 ID 的私有或修改版显示「未识别来源」。目前没有手动关联来源功能，不按名字猜测并覆盖。
- 版本按安装文件 ID、分支和发布时间比较，不对任意版本字符串强行排序。「已是最新」基于匹配文件或安装记录。项目 ID 可确定但版本无法识别时显示「本地版本未识别」，可点击更新以安装该项目的最新正式版；这可能覆盖本地定制内容。
- 一次安装/更新可能包含多个插件文件夹，会一起替换并记录。检查后本地文件发生变化会中止更新，需重新检查；不会静默覆盖新产生的修改。安装记录和代码指纹有冲突时不提供自动更新。
- 获取文件列表仅使用 API 最近 50 个匹配文件中的正式 ZIP，跳过 Beta/Alpha；客户端分支由官方 API 返回。来源相同的插件复用查询。
- 作者禁止第三方分发或 API 不提供下载链接时，应用不会绕过限制。在线页仍可查看作者页面。依赖暂需单独安装；不提供批量更新、无人值守后台定时更新或来源全覆盖保证。

## 安全与备份

只使用官方 HTTPS API 和允许的 forgecdn.net 文件地址。认证请求不跟随重定向；下载 CDN 不接收 API Key。下载上限 256 MiB，验证声明大小和 API 提供的 SHA-1/MD5 摘要，再交给安全 ZIP 读取器。API 请求使用临时会话，不持久缓存目录数据。

ZIP 支持 Stored/Deflate，拒绝路径穿越、绝对路径、符号链接、重复路径、大小写/Unicode 冲突、加密、ZIP64、CRC 不符和超限归档。不执行 Lua/XML。安装按文件夹整体替换，避免旧文件残留；使用同卷暂存和重命名提交，异常会尝试回滚。

备份位于 `~/Library/Application Support/AzerothManager/Backups`，包含完整 AddOns 和来源记录，不包含 WTF/SavedVariables。恢复前会再备份当前目录；恢复会整体替换 AddOns。备份暂不自动清理。操作期间请停止其他管理器和外部文件修改。

来源记录位于 `.azeroth-curseforge.json`，只保存来源/文件 ID、分支、客户端、文件夹和内容指纹。手动覆盖、卸载会清理冲突记录；备份恢复会带回记录。旧版 GitHub 记录仅保留兼容处理，不再有 GitHub 浏览、下载或检查入口。

游戏运行检测只是按应用名称判断，请自行确认退出。API 的客户端标记不代表游戏内兼容认证；修改版、国服定制版可能无法匹配。版本、依赖、接口声明来自作者 metadata。

## 编译运行

- macOS 14+，Xcode 15+，Swift 5.9+。实际验证环境 Xcode 26.6 / Apple Silicon。
- 打开 `AzerothManager.xcodeproj`，选择 **AzerothManager → My Mac**，按 **⌘R**。保留工程附带的本地 Swift Package。
- 使用本机临时签名，不需要付费开发者账号；应用未做 Developer ID 发行签名或 Apple 公证。未启用 App Sandbox。

在工程根目录执行：

```sh
swift test
xcodebuild -project AzerothManager.xcodeproj -scheme AzerothManager \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData 'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
open DerivedData/Build/Products/Release/AzerothManager.app
```

Swift Package 测试独立于应用 scheme。默认不访问真实游戏目录、不读取真实 API Key；联网测试默认跳过。详情见 `VALIDATION.md`。

## 演示与限制

随附 `Demo/World of Warcraft` 和 `Demo/HelloAzeroth-2.0.zip` 可试验导入、卸载、备份恢复。演示插件没有 CurseForge 来源，应显示「未识别来源」；演示接口号仅作占位，不应安装到真实客户端。

通用二进制包含 Apple Silicon / Intel，Intel 未在实机验证。尚未验证断电、磁盘耗尽、并发外部写入的所有组合；当前没有自动依赖安装、自动清理弃用目录或设置云同步。

接口依据：[CurseForge 官方 REST API](https://docs.curseforge.com/rest-api/)。
