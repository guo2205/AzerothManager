import Foundation

public struct NewBeeResolvedPlugin: Identifiable, Sendable {
    public var id: String { plugin.id }
    public let plugin: NewBeeShare.Plugin
    public let file: NewBeePluginFile?
    public let failure: String?
}
public struct NewBeeInstallChoices: Sendable {
    public let pluginIDs: Set<String>
    public let source: ConfigurationRole?
    public let roles: [ConfigurationRole]
    public let common: Bool; public let roleSettings: Bool; public let materials: Bool; public let fonts: Bool
    public let folderOwners: [String: String]
    public init(pluginIDs: Set<String>, source: ConfigurationRole?, roles: [ConfigurationRole], common: Bool, roleSettings: Bool, materials: Bool, fonts: Bool, folderOwners: [String: String] = [:]) {
        self.pluginIDs = pluginIDs; self.source = source; self.roles = roles
        self.common = common; self.roleSettings = roleSettings; self.materials = materials; self.fonts = fonts
        self.folderOwners = folderOwners
    }
}
public struct NewBeeLocalPlugin: Sendable {
    public let archive: URL; public let folders: [String]
    public let label: String
    public let id: String
    public init(archive: URL, folders: [String], label: String = "插件", id: String = "") { self.archive = archive; self.folders = folders; self.label = label; self.id = id }
}
public enum NewBeePayload {
    /// Builds a scoped payload from downloaded data. No source game folders are deleted here.
    public static func preview(share: NewBeeShare, choices: NewBeeInstallChoices, plugins: [NewBeeLocalPlugin], common: URL?, role: URL?, materials: URL?, fonts: URL?, client: URL, flavor: Flavor) throws -> ConfigurationPreview {
        guard share.accessible, share.gameVersion == NewBeeClient.gameVersion(flavor), plugins.count == choices.pluginIDs.count,
              Set(plugins.map(\.id)) == choices.pluginIDs else { throw ManagerError("分享权限、客户端或所选插件清单不匹配") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("AzerothSharePayload-" + UUID().uuidString)
        let payload = work.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let validationTarget = work.appendingPathComponent("validation/Interface/AddOns")
        try fm.createDirectory(at: validationTarget, withIntermediateDirectories: true)
        let library = Library()
        var installedFolders = Set<String>()
        let expectedFolders = Set(plugins.flatMap(\.folders).map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        for (folder, owner) in choices.folderOwners {
            guard plugins.contains(where: { $0.id == owner && $0.folders.contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == folder }) }) else { throw ManagerError("目录发布来源选择已失效，请重新选择") }
        }
        for plugin in plugins {
            try Task.checkCancellation()
            let imported = try library.prepare(plugin.archive, target: validationTarget, flavor: flavor, newBeeCompatibility: true)
            defer { library.discard(imported) }
            for name in plugin.folders { try ConfigurationFiles.validateComponent(name) }
            let expected = Set(plugin.folders.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
            let actual = Set(imported.folders.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() })
            guard !expected.isEmpty, expected == actual else { throw ManagerError("插件归档目录与官方清单不一致：\(plugin.label)；缺少 \(expected.subtracting(actual).sorted().joined(separator: ", "))；新增 \(actual.subtracting(expected).sorted().joined(separator: ", "))") }
            for folder in imported.folders {
                let key = folder.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                if let owner = choices.folderOwners[key], owner != plugin.id { continue }
                guard installedFolders.insert(key).inserted else { throw ManagerError("所选插件含交叠目录，不能确定覆盖顺序：" + folder.lastPathComponent) }
                let destination = payload.appendingPathComponent("Interface/AddOns/" + folder.lastPathComponent)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: folder, to: destination)
            }
        }
        guard installedFolders == expectedFolders else { throw ManagerError("所选目录发布来源未完整覆盖插件清单") }
        func unpack(_ archive: URL) throws -> URL {
            let dir = work.appendingPathComponent(UUID().uuidString)
            try SafeZIP.extract(archive, into: dir)
            return dir
        }
        func copySettings(from source: URL, to destination: URL, sourceRole: ConfigurationRole, targets: [ConfigurationRole]) throws {
            try FileSafety.checkTree(source)
            guard let enumerator = fm.enumerator(atPath: source.path) else { throw ManagerError("无法读取配置归档") }
            for case let relative as String in enumerator {
                try Task.checkCancellation()
                let file = source.appendingPathComponent(relative)
                if (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { continue }
                let parts = relative.split(separator: "/").map(String.init)
                guard parts.count <= 3, parts.count == 1 || parts.first == "SavedVariables",
                      ["lua", "wtf", "old", "txt", "md5", "bak"].contains(file.pathExtension.lowercased()) else { throw ManagerError("配置归档包含未知文件布局：" + relative) }
                let target = destination.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if file.pathExtension.lowercased() == "lua" {
                    let data = try LuaProfileMapping.copyIdentityKeys(Data(contentsOf: file), source: sourceRole, targets: targets)
                    try data.write(to: target, options: .withoutOverwriting)
                } else { try fm.copyItem(at: file, to: target) }
            }
        }
        if choices.common || choices.roleSettings {
            guard let source = choices.source, !choices.roles.isEmpty else { throw ManagerError("请选择来源角色和本地目标角色") }
            let commonTree = try common.map(unpack)
            var roleTree = try role.map(unpack)
            if let tree = roleTree {
                let children = try fm.contentsOfDirectory(at: tree, includingPropertiesForKeys: [.isDirectoryKey])
                // 官方角色包可用来源角色名包装；仅接受完全匹配的单目录，避免猜测或展开其它角色。
                if children.count == 1, let child = children.first, child.lastPathComponent == source.name,
                   (try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { roleTree = child }
            }
            if choices.common {
                guard let commonTree else { throw ManagerError("此分享没有可下载的账号公共配置") }
                for (account, targets) in Dictionary(grouping: choices.roles, by: \.account) {
                    try copySettings(from: commonTree, to: payload.appendingPathComponent("WTF/Account/" + account), sourceRole: source, targets: targets)
                }
            }
            if choices.roleSettings {
                guard let roleTree else { throw ManagerError("此来源角色没有可下载配置") }
                for target in choices.roles { try copySettings(from: roleTree, to: payload.appendingPathComponent(target.relativePath), sourceRole: source, targets: [target]) }
            }
        }
        if choices.materials {
            guard let materials else { throw ManagerError("材质归档未下载") }
            let tree = try unpack(materials)
            let expected = Set(share.materials.map(\.name))
            guard !expected.isEmpty, !expected.contains(where: { ["addons", "wtf", "fonts"].contains($0.lowercased()) }) else { throw ManagerError("材质清单包含禁止目录") }
            for name in expected { try ConfigurationFiles.validateComponent(name) }
            let children = try fm.contentsOfDirectory(at: tree, includingPropertiesForKeys: [.isDirectoryKey])
            guard Set(children.map(\.lastPathComponent)) == expected else { throw ManagerError("材质目录与分享清单不一致") }
            for folder in children {
                guard (try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ManagerError("材质必须按目录安装") }
                let destination = payload.appendingPathComponent("Interface/" + folder.lastPathComponent)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: folder, to: destination)
            }
        }
        if choices.fonts {
            guard let fonts else { throw ManagerError("字体资源未下载") }
            try FileSafety.checkTree(fonts)
            let files = try fm.contentsOfDirectory(at: fonts, includingPropertiesForKeys: [.isRegularFileKey])
            guard !files.isEmpty else { throw ManagerError("字体资源为空") }
            for file in files {
                try ConfigurationFiles.validateComponent(file.lastPathComponent)
                guard (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      ["ttf", "otf", "slug", "slugo"].contains(file.pathExtension.lowercased()) else { throw ManagerError("字体资源包含不支持的文件") }
            }
            try fm.copyItem(at: fonts, to: payload.appendingPathComponent("Fonts"))
        }
        return try ConfigurationLibrary().preview(payload: payload, client: client, roles: choices.roles, accountWide: choices.common)
    }
}

extension NewBeeClient {
    public func resolvePlugins(in share: NewBeeShare, flavor: Flavor, progress: @Sendable (String) async -> Void) async throws -> [NewBeeResolvedPlugin] {
        var result: [NewBeeResolvedPlugin] = []
        for (index, plugin) in share.plugins.enumerated() {
            try Task.checkCancellation()
            await progress("读取插件 \(index + 1)/\(share.plugins.count)：\(plugin.name)")
            do { result.append(NewBeeResolvedPlugin(plugin: plugin, file: try await pluginFile(plugin, flavor: flavor), failure: nil)) }
            catch {
                try Task.checkCancellation()
                result.append(NewBeeResolvedPlugin(plugin: plugin, file: nil, failure: error.localizedDescription))
            }
        }
        return result
    }
    public func prepare(share expectedShare: NewBeeShare, resolved: [NewBeeResolvedPlugin], choices: NewBeeInstallChoices, client: URL, flavor: Flavor, progress: @Sendable (String) async -> Void) async throws -> ConfigurationPreview {
        let share = try await self.share(code: expectedShare.shareCode, flavor: flavor)
        guard share == expectedShare else { throw ManagerError("分享清单已更新，请重新读取后选择") }
        let fm = FileManager.default, work = FileManager.default.temporaryDirectory.appendingPathComponent("AzerothShareDownload-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var downloaded: Int64 = 0
        func accountBytes(_ count: Int) throws {
            downloaded += Int64(count)
            guard downloaded <= 4 * 1024 * 1024 * 1024 else { throw ManagerError("配置分享下载总量超过 4 GB 限制") }
        }
        func save(_ data: Data) throws -> URL {
            try accountBytes(data.count)
            let file = work.appendingPathComponent(UUID().uuidString + ".zip")
            try data.write(to: file, options: .atomic); return file
        }
        var plugins: [NewBeeLocalPlugin] = []
        guard choices.pluginIDs.isSubset(of: Set(resolved.map(\.id))) else { throw ManagerError("所选插件不属于当前分享") }
        let selected = resolved.filter { choices.pluginIDs.contains($0.id) }
        for (index, plugin) in selected.enumerated() {
            try Task.checkCancellation()
            await progress("下载并核对插件 \(index + 1)/\(selected.count)：\(plugin.plugin.name)")
            guard let expected = plugin.file, let id = Int(plugin.id) else { throw ManagerError("所选插件尚不可下载：" + plugin.plugin.name) }
            let current = try await pluginFile(plugin.plugin, flavor: flavor)
            guard current == expected else { throw ManagerError("插件文件已更新，请重新读取：" + plugin.plugin.name) }
            let archive = try save(await downloadResource(current.downloadURL(pluginID: id).absoluteString))
            plugins.append(NewBeeLocalPlugin(archive: archive, folders: current.file_folders, label: plugin.plugin.name, id: plugin.id))
        }
        var common: URL?, role: URL?, material: URL?, fontFolder: URL?
        if choices.common || choices.roleSettings {
            guard let source = choices.source, let account = share.accounts.first(where: { $0.account == source.account }),
                  let realm = account.server.first(where: { $0.serverName == source.realm }), let sourceRole = realm.roleList.first(where: { $0.name == source.name }) else { throw ManagerError("来源角色不属于此分享") }
            if choices.common {
                guard let path = account.commonConfig, !path.isEmpty else { throw ManagerError("此分享没有公共配置下载地址") }
                await progress("下载账号公共配置…"); common = try save(await downloadResource(path))
            }
            if choices.roleSettings {
                guard let path = sourceRole.zip, !path.isEmpty else { throw ManagerError("此分享没有角色配置下载地址") }
                await progress("下载角色配置…"); role = try save(await downloadResource(path))
            }
        }
        if choices.materials {
            guard let path = share.materialZIP, !path.isEmpty else { throw ManagerError("此分享没有材质下载地址") }
            await progress("下载界面材质…"); material = try save(await downloadResource(path))
        }
        if choices.fonts {
            let folder = work.appendingPathComponent("fonts")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let index = share.fontIndex, !index.isEmpty {
                let files = try await indexFiles(index)
                var keys = Set<String>()
                for (number, file) in files.enumerated() {
                    try ConfigurationFiles.validateComponent(file.relPath)
                    guard keys.insert(file.relPath.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                          ["ttf", "otf", "slug", "slugo"].contains((file.relPath as NSString).pathExtension.lowercased()) else { throw ManagerError("字体索引存在重名或不支持的文件") }
                    await progress("下载字体 \(number + 1)/\(files.count)：\(file.relPath)")
                    let destination = folder.appendingPathComponent(file.relPath)
                    fm.createFile(atPath: destination.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: destination)
                    do {
                        for chunk in file.chunks {
                            let data = try await downloadResource(chunk.url)
                            try accountBytes(data.count)
                            guard data.count == chunk.size else { throw ManagerError("字体分片长度不匹配") }
                            try handle.write(contentsOf: data)
                        }
                        try handle.close()
                    } catch { try? handle.close(); throw error }
                    guard ((try fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.intValue == file.totalSize else { throw ManagerError("字体文件长度不匹配") }
                }
                guard try await indexFiles(index) == files else { throw ManagerError("字体索引在下载期间改变，请重新读取") }
            } else if let path = share.fontZIP, !path.isEmpty {
                let archive = try save(await downloadResource(path)), extracted = work.appendingPathComponent("font-extracted")
                try SafeZIP.extract(archive, into: extracted)
                for item in try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil) { try fm.copyItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent)) }
            } else { throw ManagerError("此分享没有可下载的字体资源") }
            fontFolder = folder
        }
        guard try await self.share(code: share.shareCode, flavor: flavor) == share else { throw ManagerError("分享在下载期间更新，请重新读取") }
        await progress("安全解压、映射角色并生成安装预览…")
        try Task.checkCancellation()
        return try NewBeePayload.preview(share: share, choices: choices, plugins: plugins, common: common, role: role, materials: material, fonts: fontFolder, client: client, flavor: flavor)
    }
}
