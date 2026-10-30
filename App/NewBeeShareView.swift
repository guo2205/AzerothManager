import SwiftUI
import AppKit
import ManagerCore

@MainActor final class NewBeeShareController: ObservableObject {
    let manager: ManagerModel
    let client = NewBeeClient()
    let configurations = ConfigurationLibrary()
    @Published var code = "867253"
    @Published var authenticated = false
    @Published var share: NewBeeShare?
    @Published var plugins: [NewBeeResolvedPlugin] = []
    @Published var selectedPlugins = Set<String>()
    @Published var folderOwners: [String: String] = [:]
    @Published var localRoles: [ConfigurationRole] = []
    @Published var selectedRoles = Set<String>()
    @Published var sourceID = ""
    @Published var common = true
    @Published var roleSettings = true
    @Published var materials = true
    @Published var fonts = false
    @Published var fontFiles: [NewBeeIndexFile] = []
    @Published var preview: ConfigurationPreview?
    @Published var backups: [ConfigurationSnapshot] = []
    @Published var showLogin = false
    @Published var login: NewBeeLogin?
    @Published var loginFailure: String?
    @Published var result = "登录新手盒子后读取分享；本地账号和角色仅用于本机映射。"
    init(manager: ManagerModel) { self.manager = manager }
    var gameClient: URL? { manager.target?.deletingLastPathComponent().deletingLastPathComponent() }
    var sources: [ConfigurationRole] {
        share?.accounts.flatMap { account in account.server.flatMap { realm in realm.roleList.compactMap { try? ConfigurationRole(account: account.account, realm: realm.serverName, name: $0.name) } } } ?? []
    }
    func progress(_ text: String) { manager.status = text }
    func discardPreview() { if let preview { configurations.discard(preview) }; preview = nil }
    func clearShare() {
        discardPreview(); share = nil; plugins = []; selectedPlugins = []; fontFiles = []; sourceID = ""; folderOwners = [:]
    }
    func reloadLocal() {
        guard let root = gameClient else { localRoles = []; selectedRoles = []; backups = []; return }
        let configurations = configurations
        Task {
            let value = await Task.detached { Result { (try ConfigurationFiles.roles(in: root), try configurations.snapshots(for: root)) } }.value
            guard self.gameClient == root else { return }
            switch value {
            case .success(let data):
                self.localRoles = data.0; self.backups = data.1
                self.selectedRoles.formIntersection(Set(data.0.map(\.id)))
            case .failure(let error): self.result = "本地目录读取未完成：" + error.localizedDescription
            }
        }
    }
    func startLogin() {
        guard !manager.busy else { return }
        clearShare(); authenticated = false; login = nil; loginFailure = nil; showLogin = true
        let api = client
        manager.runNetwork("正在获取新手盒子官方登录二维码…", operation: {
            do {
                let value = try await api.beginLogin()
                guard NSImage(data: value.image) != nil else { throw ManagerError("官方二维码图像无法识别") }
                await MainActor.run { self.login = value }
                try await api.waitForLogin()
                return true
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    await MainActor.run { self.showLogin = false }; throw CancellationError()
                }
                await MainActor.run { self.loginFailure = error.localizedDescription }
                return false
            }
        }) { success in
            self.authenticated = success
            if success {
                self.login = nil; self.showLogin = false
                self.result = "登录成功，临时会话仅保留在本次应用运行中。"
                self.readShare()
            }
        }
    }
    func closeLogin() {
        if manager.busy { manager.networkTask?.cancel() }
        login = nil; showLogin = false
        if !authenticated { Task { await client.logout() } }
    }
    func logout() {
        guard !manager.busy else { return }
        clearShare(); authenticated = false; login = nil
        Task { await client.logout() }
        result = "已退出新手盒子临时会话。"
    }
    func readShare() {
        guard !manager.busy else { return }
        clearShare()
        let api = client, code = code.trimmingCharacters(in: .whitespacesAndNewlines), flavor = manager.flavor
        manager.runNetwork("正在读取新手盒子配置分享…", operation: {
            let share = try await api.share(code: code, flavor: flavor)
            let plugins = try await api.resolvePlugins(in: share, flavor: flavor) { text in await MainActor.run { self.progress(text) } }
            var fonts: [NewBeeIndexFile] = []
            if let index = share.fontIndex, !index.isEmpty { fonts = try await api.indexFiles(index) }
            return (share, plugins, fonts)
        }) { data in
            guard self.manager.flavor == flavor else { return }
            self.share = data.0; self.plugins = data.1; self.fontFiles = data.2
            self.selectedPlugins = Set(data.1.filter { $0.file != nil }.map(\.id))
            self.sourceID = self.sources.first?.id ?? ""
            self.common = !data.0.accounts.isEmpty; self.roleSettings = !data.0.accounts.isEmpty
            self.materials = !(data.0.materialZIP ?? "").isEmpty
            self.fonts = false
            let unavailable = data.1.filter { $0.file == nil }.count
            self.result = "已读取 \(data.1.count) 项插件" + (unavailable > 0 ? "，其中 \(unavailable) 项暂不可用，未自动选中。" : "，请选择本地角色和安装内容。")
            self.reloadLocal()
        }
    }
    var choices: NewBeeInstallChoices {
        let owners = folderOwners.filter { key, value in conflicts.contains(where: { $0.folder == key && $0.plugins.contains(where: { $0.id == value }) }) }
        return NewBeeInstallChoices(pluginIDs: selectedPlugins, source: sources.first { $0.id == sourceID }, roles: localRoles.filter { selectedRoles.contains($0.id) }, common: common, roleSettings: roleSettings, materials: materials, fonts: fonts, folderOwners: owners)
    }
    struct FolderConflict { let folder: String; let plugins: [NewBeeResolvedPlugin] }
    var conflicts: [FolderConflict] {
        var folders: [String: [NewBeeResolvedPlugin]] = [:]
        for plugin in plugins where selectedPlugins.contains(plugin.id) {
            for folder in plugin.file?.file_folders ?? [] { folders[folder.precomposedStringWithCanonicalMapping.lowercased(), default: []].append(plugin) }
        }
        return folders.filter { $0.value.count > 1 }.map { FolderConflict(folder: $0.key, plugins: $0.value) }.sorted { $0.folder < $1.folder }
    }
    var canPrepare: Bool {
        guard authenticated, share != nil, gameClient != nil, preview == nil else { return false }
        if (common || roleSettings) && (selectedRoles.isEmpty || sourceID.isEmpty) { return false }
        if conflicts.contains(where: { conflict in !conflict.plugins.contains(where: { $0.id == folderOwners[conflict.folder] }) }) { return false }
        return !selectedPlugins.isEmpty || common || roleSettings || materials || fonts
    }
    func prepare() {
        guard let share, let root = gameClient, manager.gameIsClosed(), canPrepare, !manager.busy else { return }
        let api = client, plugins = plugins, choices = choices, flavor = manager.flavor
        manager.runNetwork("正在准备配置安装预览…", operation: {
            try await api.prepare(share: share, resolved: plugins, choices: choices, client: root, flavor: flavor) { text in await MainActor.run { self.progress(text) } }
        }) { preview in
            guard self.gameClient == root, self.manager.flavor == flavor else { self.configurations.discard(preview); return }
            self.preview = preview
            self.result = "预览已准备好：\(choices.pluginIDs.count)/\(share.plugins.count) 项插件、\(choices.roles.count) 个目标角色。尚未写入游戏。"
        }
    }
    func install() {
        guard let preview, let root = gameClient, preview.client == root, manager.gameIsClosed(), !manager.busy else { return }
        let global = preview.accountWide ? "\n账号公共配置会影响所选账号的所有角色，同名 SavedVariables（包括个人 WA）、键位和宏可能被覆盖。" : ""
        manager.prompt = Prompt(title: "确认安装配置分享", message: "目标：\(root.path)\n写入 \(preview.fileCount) 个文件，其中 \(preview.replacedFiles) 个将覆盖同名文件。\(global)\n提交前自动完整备份 Interface、WTF、Fonts；失败会回滚。", confirm: "备份并安装", destructive: true, action: {
            guard self.gameClient == root, self.manager.gameIsClosed() else { return }
            let library = self.configurations
            self.manager.run("正在完整备份并安装配置，请勿启动游戏…", operation: { try library.install(preview) }) { _ in
                self.discardPreview(); self.result = "配置安装完成，完整备份已保留。请进入游戏检查界面；如需撤销，可恢复本页的完整配置备份。"
                self.reloadLocal(); self.manager.refresh()
            }
        })
    }
    func restore(_ snapshot: ConfigurationSnapshot) {
        guard let root = gameClient, manager.gameIsClosed(), !manager.busy else { return }
        manager.prompt = Prompt(title: "恢复完整配置备份", message: "将恢复 \(snapshot.date.formatted()) 的 Interface、WTF、Fonts，替换当前这三个目录。恢复前会再完整备份当前状态。\n\(root.path)", confirm: "备份并恢复", destructive: true, action: {
            guard self.gameClient == root, self.manager.gameIsClosed() else { return }
            let library = self.configurations
            self.manager.run("正在备份当前状态并恢复完整配置…", operation: { try library.restore(snapshot, client: root) }) { _ in
                self.discardPreview(); self.result = "完整配置已恢复，恢复前状态也已备份。"; self.reloadLocal(); self.manager.refresh()
            }
        })
    }
    func recover() {
        guard let root = gameClient, manager.gameIsClosed(), !manager.busy else { return }
        let library = configurations
        manager.run("正在检查配置安装恢复记录…", operation: { try library.recoverInterrupted(in: root) }) { _ in
            self.discardPreview(); self.result = "中断安装检查完成。"; self.reloadLocal(); self.manager.refresh()
        }
    }
}

struct NewBeeShareView: View {
    @ObservedObject var controller: NewBeeShareController
    @ObservedObject var manager: ManagerModel
    private let gold = Color(red: 0.89, green: 0.70, blue: 0.39)
    private var locked: Bool { controller.preview != nil }
    private func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { controller.selectedPlugins.contains(id) }, set: { if $0 { controller.selectedPlugins.insert(id) } else { controller.selectedPlugins.remove(id) } })
    }
    private func roleBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { controller.selectedRoles.contains(id) }, set: { if $0 { controller.selectedRoles.insert(id) } else { controller.selectedRoles.remove(id) } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("新手盒子 · 配置分享", systemImage: "square.stack.3d.up.fill").font(.title2.bold())
                    Spacer()
                    Text(controller.authenticated ? "本次会话已登录" : "尚未登录").font(.caption).foregroundStyle(.secondary)
                    Button(controller.authenticated ? "重新登录" : "微信登录", action: controller.startLogin)
                    if controller.authenticated { Button("退出登录", action: controller.logout) }
                }
                HStack {
                    TextField("新手盒子六位分享码", text: $controller.code).textFieldStyle(.roundedBorder).onSubmit(controller.readShare)
                    Button("读取 / 更新分享", action: controller.readShare).disabled(!controller.authenticated)
                }.disabled(locked)
                Text("露露 NDui 时光服：867253。登录凭据仅保存在内存；退出应用后需重新登录。普通插件更新仍使用网易 DD。").font(.caption).foregroundStyle(.secondary)
                if let share = controller.share {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(share.title).font(.headline)
                            Text("分享码 \(share.shareCode) · \(share.plugins.count) 项插件 · \(manager.flavor.rawValue)").font(.caption).foregroundStyle(gold)
                            Link("查看作者发布页", destination: URL(string: "https://www.wclbox.com/games/1/ConfigureShareItem/\(share.id)")!)
                            if let root = controller.gameClient { Text("目标：" + root.path).font(.caption).textSelection(.enabled) }
                            else { Text("请先在左上方选择游戏目录。采用所选客户端的用途标记，请核对实际启动路径。").foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("安装内容与角色") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("账号公共配置（同账号所有角色共享）", isOn: $controller.common)
                                Toggle("所选角色的设置、键位和宏", isOn: $controller.roleSettings)
                                Toggle("界面材质", isOn: $controller.materials).disabled((share.materialZIP ?? "").isEmpty)
                                Toggle("字体资源", isOn: $controller.fonts).disabled(share.fontIndex == nil && share.fontZIP == nil)
                                if !controller.fontFiles.isEmpty {
                                    Text("字体索引 \(controller.fontFiles.count) 项；分享说明 \(share.fonts.count) 项。按当前索引下载，默认不勾选。").font(.caption).foregroundStyle(.secondary)
                                    DisclosureGroup("查看字体文件") { ForEach(controller.fontFiles, id: \.relPath) { Text($0.relPath).font(.caption) } }
                                }
                                if !controller.sources.isEmpty {
                                    Picker("来源配置", selection: $controller.sourceID) { ForEach(controller.sources) { role in Text("\(role.name) · \(role.realm)").tag(role.id) } }
                                }
                                Divider()
                                HStack {
                                    Text("本地目标角色").font(.headline)
                                    Spacer()
                                    Button("全选") { controller.selectedRoles = Set(controller.localRoles.map(\.id)) }
                                    Button("清空") { controller.selectedRoles = [] }
                                }
                                if controller.localRoles.isEmpty { Text("尚未发现角色。请先登录游戏中的目标角色并正常退出，再刷新。").font(.caption).foregroundStyle(.secondary) }
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 9) {
                                        ForEach(controller.localRoles) { role in Toggle("\(role.name) · \(role.realm) · \(role.account)", isOn: roleBinding(role.id)).font(.caption) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 160)
                            }.padding(8)
                        }.frame(maxWidth: .infinity).disabled(locked)
                        GroupBox("插件清单 · 已选 \(controller.selectedPlugins.count)/\(controller.plugins.count)") {
                            VStack {
                                HStack {
                                    Button("选择可用插件") { controller.selectedPlugins = Set(controller.plugins.filter { $0.file != nil }.map(\.id)) }
                                    Button("清空") { controller.selectedPlugins = [] }
                                    Spacer()
                                }
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(controller.plugins) { plugin in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Toggle(plugin.plugin.name, isOn: pluginBinding(plugin.id)).disabled(plugin.file == nil)
                                                Text(plugin.file.map { "正式文件：" + $0.file_display_name } ?? plugin.failure ?? "不可用").font(.caption).foregroundStyle(plugin.file == nil ? .orange : .secondary)
                                            }
                                        }
                                    }
                                }.frame(height: 270)
                                Text("按分享的更新策略解析对应客户端的正式文件；同名插件目录整体替换，其他本地插件保留。").font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }.frame(maxWidth: .infinity).disabled(locked)
                    }
                    if !controller.conflicts.isEmpty {
                        GroupBox("共享插件目录 · 请选择发布来源") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("多个包包含同一目录时，只从所选发布包安装这个目录，其他目录仍按原插件安装。").font(.caption).foregroundStyle(.secondary)
                                ForEach(controller.conflicts, id: \.folder) { conflict in
                                    Picker(conflict.folder, selection: Binding(get: { controller.folderOwners[conflict.folder] ?? "" }, set: { controller.folderOwners[conflict.folder] = $0 })) {
                                        Text("请选择来源").tag("")
                                        ForEach(conflict.plugins) { Text($0.plugin.name).tag($0.id) }
                                    }
                                }
                            }.padding(8)
                        }.disabled(locked)
                    }
                    if let preview = controller.preview {
                        GroupBox("安装预览 · 尚未写入游戏") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(preview.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file)) · 覆盖 \(preview.replacedFiles) 个同名文件 · \(preview.roles.count) 个角色")
                                if preview.accountWide { Text("公共 SavedVariables 会影响所选账号的所有角色，包括个人 WA 设置。安装前将备份整个 Interface、WTF、Fonts。").font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button("备份并安装…", action: controller.install).buttonStyle(.borderedProminent).tint(gold)
                                    Button("丢弃预览，重新选择", action: controller.discardPreview)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    } else {
                        Button("下载校验并准备安装预览", action: controller.prepare).buttonStyle(.borderedProminent).tint(gold).disabled(!controller.canPrepare)
                    }
                }
                Text(controller.result).font(.callout).foregroundStyle(gold).textSelection(.enabled)
                Divider()
                GroupBox("完整配置备份 · Interface / WTF / Fonts") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("刷新角色与完整备份", action: controller.reloadLocal)
                            Button("检查并恢复中断安装", action: controller.recover).disabled(controller.gameClient == nil)
                        }
                        Text("此处的完整备份与左侧“备份与恢复”中的 AddOns 备份分别管理。").font(.caption).foregroundStyle(.secondary)
                        if controller.backups.isEmpty { Text("此游戏目录暂无完整配置备份。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(controller.backups.prefix(10)) { snapshot in
                            HStack {
                                VStack(alignment: .leading) { Text(snapshot.date.formatted()).font(.callout); Text(snapshot.reason).font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Button("恢复…") { controller.restore(snapshot) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(.bottom, 10)
        }
        .onAppear { controller.reloadLocal() }
        .onChange(of: manager.target) { _, _ in controller.discardPreview(); controller.reloadLocal() }
        .onChange(of: manager.flavor) { _, _ in controller.clearShare() }
        .onChange(of: manager.busy) { _, busy in if !busy { controller.reloadLocal() } }
    }
}

struct NewBeeLoginView: View {
    @ObservedObject var controller: NewBeeShareController
    @ObservedObject var manager: ManagerModel
    var body: some View {
            VStack(spacing: 16) {
                Text("新手盒子官方微信登录").font(.title2.bold())
                if let login = controller.login, let image = NSImage(data: login.image) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 300, height: 300).padding(12).background(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { context in Text("二维码剩余 \(max(0, Int(login.expires.timeIntervalSince(context.date)))) 秒").font(.caption).foregroundStyle(.secondary) }
                } else if manager.busy { ProgressView("正在获取官方二维码…").frame(height: 240) }
                Text(controller.loginFailure ?? "请用微信扫码，按官方页面提示完成授权。不会接收或保存你的密码；临时访问凭据仅保存在本次应用内存中。").font(.callout).multilineTextAlignment(.center)
                HStack {
                    Button("关闭", action: controller.closeLogin)
                    if !manager.busy { Button("重新获取二维码", action: controller.startLogin) }
                }
            }.padding(24).frame(width: 440)
    }
}
