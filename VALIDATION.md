# 验证记录 · 2026-10-23

## v0.3 CurseForge

- Xcode 26.6 Release 通用构建通过，版本 0.3.0；Apple Silicon / Intel 双架构，本机临时签名。
- `swift test` 共 28 项测试方法：27 通过、1 项 GitHub 联网测试按默认设置跳过，0 失败。
- 新增 7 项 CurseForge 测试：请求认证与搜索转义、分页、客户端分支/正式版本过滤、401/403/404/429/500/302、损坏 JSON、下载无密钥、摘要及长度不符、作者禁止分发与空下载链接、CDN 地址限制、来源记录在覆盖/卸载/恢复中的变化、不同分支和旧日期拒绝更新。
- UI 实际验证：使用用户的密钥保存至本机钥匙串，官方 version-types 请求成功；包含 WoW Wrath Titan Reforged 分支。搜索 BigWigs 返回 134 项，选择 Titan 分支后读取匹配正式版本。
- UI 实际下载 BigWigs v427.7（4.6 MB），API 分发许可、下载 URL、长度与摘要检查、ZIP 安全解压及安装预览全部完成，识别 12 个插件文件夹；随后取消。没有改动真实游戏 AddOns。安装/卸载/备份/恢复在临时目录通过核心测试。
- 尚未验证：真实游戏兼容性、Intel 实机运行、CF 启动检查的完整 GUI 回归、所有 CDN 重定向组合、磁盘耗尽/断电及并发外部写入。未实现无人值守安装、全库自动来源匹配或依赖自动安装。
- API Key 未进入源码、交付 ZIP 或仓库。公开源码测试只使用固定假密钥。

## v0.2 GitHub 来源

- Release 通用应用完成 Xcode 26.6 编译，Apple Silicon / Intel 双架构。版本 0.2.0。本机签名校验通过。
- 最终离线回归：21 项测试方法，20 项通过、1 项联网测试按默认设置跳过、0 失败。
- 新增测试覆盖 GitHub 地址验证、发布筛选和排序、限流与 404、无效响应、下载长度、SHA-256、恶意下载地址、取消请求、来源记录随手动覆盖/卸载/恢复变化、同版本附件重新上传、非标准版本标签。
- 单独开启真实联网测试通过：从 BigWigsMods/BigWigs 获取 v427.7 / BigWigs-v427.7.zip，下载与校验成功，在随机临时 AddOns 目录安装 12 个插件文件夹，并验证扫描和来源内容指纹。未修改真实游戏目录。
- UI 冒烟：v0.2 成功启动，显示现有 125 个插件；在线插件页成功读取真实 BigWigs 发布、更新说明和 ZIP 附件，并显示 SHA-256 状态。没有在真实目录执行 GUI 安装。
- 测试发现并修复 macOS /var 与 /private/var 路径表示差异导致的指纹误报；改用相对枚举路径。
- 自动检查默认关闭；未做启动开关的完整 GUI 回归、全部 CDN 重定向情形、真实游戏兼容性或 Intel 实机运行验证。
- 发布包仅本机临时签名，未做 Developer ID 签名或 Apple 公证。

## 验证命令

工程目录下运行 `swift test`。联网测试另行开启：

```sh
AZEROTH_LIVE_GITHUB=1 swift test --filter GitHubSourceTests.testLiveGitHubDownloadAndStagedInstall
```

构建通用应用：

```sh
xcodebuild -project AzerothManager.xcodeproj -scheme AzerothManager \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData 'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

## 剩余限制

安装、卸载、备份、恢复和来源记录在临时目录通过核心测试；尚未完整执行 GUI 安装确认、备份恢复、取消下载的全部组合。磁盘耗尽、断电、目录改名失败及并发外部写入仍需额外验证。

GitHub 最近 30 条发布窗口并不覆盖所有历史版本；同名附件发生替换会提示，原附件直接删除或改名需用户人工核对。时光服兼容性由用户依据作者说明选择，管理器不会自动认证。CurseForge 已在 v0.3 接入；无人值守安装未实现。
