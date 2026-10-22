import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ManagerCore

@main
struct AzerothManagerApp: App {
    @StateObject private var model = ManagerModel()
    var body: some Scene {
        WindowGroup("艾泽拉斯 · 插件管家") {
            ContentView(model: model).preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 700)
        }.defaultSize(width: 1240, height: 800)
    }
}

struct Prompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    let destructive: Bool
    let action: () -> Void
    var cancel: () -> Void = {}
}

@MainActor final class ManagerModel: ObservableObject {
    @Published var target: URL?
    @Published var flavor: Flavor = .time
    @Published var addons: [Addon] = []
    @Published var snapshots: [Snapshot] = []
    @Published var selected: Set<String> = []
    @Published var search = ""
    @Published var busy = false
    @Published var status = "选择游戏目录，开始整理插件"
    @Published var error: String? {
        didSet {
            if let message = error {
                prompt = Prompt(title: "操作未完成", message: message, confirm: "知道了", destructive: false, action: { self.error = nil }, cancel: { self.error = nil })
            }
        }
    }
    @Published var candidates: [URL] = []
    @Published var showCandidates = false
    @Published var prompt: Prompt?
    @Published var repositoryText = ""
    @Published var loadedRepository: GitHubRepository?
    @Published var releases: [GitHubRelease] = []
    @Published var releaseID: Int?
    @Published var assetID: Int?
    @Published var sourceReceipts: [SourceReceipt] = []
    @Published var updateLabels: [UUID: String] = [:]
    @Published var networkTask: Task<Void, Never>?
    @Published var checkOnLaunch = UserDefaults.standard.bool(forKey: "checkGitHubOnLaunch")
    private var checkedLaunch = false
    private let github = GitHubClient()
    let library = Library()
    var chosenRelease: GitHubRelease? { releases.first { $0.id == releaseID } }
    var chosenAsset: GitHubAsset? { chosenRelease?.zipAssets.first { $0.id == assetID } }
    func runNetwork<T>(_ message: String, operation: @escaping () async throws -> T, completion: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true; status = message
        networkTask = Task {
            do {
                let value = try await operation()
                if Task.isCancelled {
                    if let preview = value as? InstallPreview { library.discard(preview) }
                    throw CancellationError()
                }
                busy = false; networkTask = nil; completion(value)
            } catch {
                busy = false; networkTask = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled { status = "已取消网络操作" }
                else { self.error = error.localizedDescription; status = "网络操作未完成" }
            }
        }
    }
    func loadReleases() {
        do {
            let repo = try GitHubRepository(repositoryText), github = github
            releases = []; releaseID = nil; assetID = nil; loadedRepository = nil
            runNetwork("正在读取 GitHub 正式发布…", operation: { try await github.releases(in: repo) }) { releases in
                self.loadedRepository = repo; self.releases = releases
                self.releaseID = releases.first?.id
                self.status = releases.isEmpty ? "没有找到正式发布，请确认作者是否上传了 Release" : "已读取发布，请选择对应客户端的 ZIP 附件"
            }
        } catch { self.error = error.localizedDescription }
    }
    func checkGitHubUpdates() {
        guard let target, !sourceReceipts.isEmpty else { return }
        let records = sourceReceipts, github = github, flavor = flavor
        runNetwork("正在检查已记录的 GitHub 来源…", operation: {
            var results: [UUID: String] = [:], cache: [GitHubRepository: [GitHubRelease]] = [:]
            for record in records {
                try Task.checkCancellation()
                if record.flavor != flavor { results[record.id] = "客户端标记不同，请确认目录"; continue }
                do {
                    let unchanged = try await Task.detached { try SourceTracking.isUnchanged(record, in: target) }.value
                    if !unchanged { results[record.id] = "本地文件已修改或缺失，更新前请核对"; continue }
                    if cache[record.repository] == nil { cache[record.repository] = try await github.releases(in: record.repository) }
                    if let next = record.newerRelease(in: cache[record.repository] ?? []) {
                        results[record.id] = "检测到发布或附件更新：\(next.tagName)，需确认客户端附件"
                    } else {
                        results[record.id] = "最近 30 条发布中未发现较新的正式 ZIP"
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    results[record.id] = error.localizedDescription
                }
            }
            return results
        }) { values in self.updateLabels = values; self.status = "GitHub 来源检查完成" }
    }
    func downloadChosenAsset() {
        guard let target, let repo = loadedRepository, let release = chosenRelease, let asset = chosenAsset, gameIsClosed() else { return }
        let source = GitHubSelection(repository: repo, release: release, asset: asset, flavor: flavor)
        let github = github, library = library, flavor = flavor
        runNetwork("正在下载并校验 \(asset.name)…", operation: {
            let archive = try await github.download(source)
            defer { try? FileManager.default.removeItem(at: archive) }
            let preview = try await Task.detached { try library.prepare(archive, target: target, flavor: flavor) }.value
            if Task.isCancelled { library.discard(preview); throw CancellationError() }
            return preview
        }) { preview in
            self.status = "下载与 ZIP 检查完成，等待安装确认"
            self.prompt = Prompt(title: "从 GitHub 安装 \(release.tagName)？", message: "来源：\(repo.fullName)\n附件：\(asset.name)\n目标：\(target.path)\n\n安装：\(preview.folders.map(\.lastPathComponent).joined(separator: "、"))\n覆盖：\(preview.replacing.isEmpty ? "无" : preview.replacing.joined(separator: "、"))\n\n请确认附件适用于\(flavor.rawValue)。覆盖会替换整个文件夹，包括本地修改；系统将先备份。", confirm: "备份并安装", destructive: false, action: {
                guard self.gameIsClosed(), self.target == target, self.flavor == flavor else { library.discard(preview); return }
                self.run("正在备份并安装 GitHub 插件…", operation: {
                    defer { library.discard(preview) }
                    try library.install(preview, target: target, source: source)
                }) { self.refresh() }
            }, cancel: { library.discard(preview); self.status = "已取消安装" })
        }
    }
    @Published var onlineProvider = "CurseForge"
    @Published var apiKeyInput = ""
    @Published var keyStatus = "密钥保存在本机钥匙串；不会写入仓库"
    @Published var cfQuery = ""
    @Published var cfPage: CFSearchPage?
    @Published var cfTypes: [CFVersionType] = []
    @Published var cfTypeID = 0
    @Published var cfVersion = ""
    @Published var cfMod: CFMod?
    @Published var cfFiles: [CFFile] = []
    @Published var cfReceipts: [CFReceipt] = []
    @Published var cfCheckOnLaunch = UserDefaults.standard.bool(forKey: "checkCurseForgeOnLaunch")
    private var searchedQuery = ""
    private let keyStore = CurseForgeKeyStore()
    func cfClient() throws -> CurseForgeClient {
        guard let key = try keyStore.load() else { throw ManagerError("请先保存 CurseForge API Key") }
        return try CurseForgeClient(apiKey: key)
    }
    func saveCFKey() {
        do { try keyStore.save(apiKeyInput); apiKeyInput = ""; keyStatus = "已保存到本机钥匙串，正在验证…"; loadCFTypes() }
        catch { self.error = error.localizedDescription }
    }
    func deleteCFKey() {
        do { try keyStore.delete(); apiKeyInput = ""; cfTypes = []; cfFiles = []; cfPage = nil; keyStatus = "已移除本机密钥" }
        catch { self.error = error.localizedDescription }
    }
    func loadCFTypes() {
        do {
            let client = try cfClient()
            runNetwork("正在验证密钥并读取客户端分支…", operation: { try await client.versionTypes() }) { types in
                self.cfTypes = types; self.keyStatus = "接口验证成功 · 密钥保存在本机钥匙串"
                self.status = "请选择作者对应的客户端分支"
            }
        } catch { self.error = error.localizedDescription }
    }
    func searchCF(index: Int = 0) {
        do {
            let client = try cfClient(), query = index == 0 ? cfQuery.trimmingCharacters(in: .whitespacesAndNewlines) : searchedQuery
            runNetwork("正在搜索 CurseForge…", operation: { try await client.search(query, index: index) }) { page in
                self.cfPage = page; self.searchedQuery = query; self.cfMod = nil; self.cfFiles = []
                self.status = "搜索完成：本页 \(page.data.count) 项"
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadCFFiles(_ mod: CFMod) {
        guard cfTypeID > 0 else { error = "请先读取并选择客户端分支"; return }
        do {
            let client = try cfClient(), type = cfTypeID, version = cfVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            cfMod = nil; cfFiles = []
            runNetwork("正在读取匹配的正式版本…", operation: { try await client.files(modID: mod.id, typeID: type, version: version) }) { files in
                self.cfPage = nil; self.cfMod = mod; self.cfFiles = files
                self.status = files.isEmpty ? "最近 50 个文件中没有匹配的正式 ZIP" : "请选择文件，核对游戏版本与依赖"
            }
        } catch { self.error = error.localizedDescription }
    }
    func openCFRecord(_ record: CFReceipt) {
        do {
            let client = try cfClient()
            cfTypeID = record.typeID; cfVersion = record.version; cfFiles = []; cfMod = nil
            runNetwork("正在读取插件来源…", operation: { try await client.mod(record.modID) }) { mod in self.loadCFFiles(mod) }
        } catch { self.error = error.localizedDescription }
    }
    func downloadCF(_ file: CFFile) {
        guard let target, let mod = cfMod, gameIsClosed() else { return }
        do {
            let client = try cfClient(), library = library, flavor = flavor
            let selection = CFSelection(mod: mod, file: file, typeID: cfTypeID, version: cfVersion.trimmingCharacters(in: .whitespacesAndNewlines), flavor: flavor)
            runNetwork("正在下载、校验与检查 ZIP…", operation: {
                let archive = try await client.download(selection)
                defer { try? FileManager.default.removeItem(at: archive) }
                let preview = try await Task.detached { try library.prepare(archive, target: target, flavor: flavor) }.value
                if Task.isCancelled { library.discard(preview); throw CancellationError() }
                return preview
            }) { preview in
                self.status = "下载与校验完成，等待安装确认"
                self.prompt = Prompt(title: "安装 \(mod.name)？", message: "文件：\(file.displayName)\n游戏版本：\(file.gameVersions.joined(separator: "、"))\n目标：\(target.path)\n安装：\(preview.folders.map(\.lastPathComponent).joined(separator: "、"))\n覆盖：\(preview.replacing.isEmpty ? "无" : preview.replacing.joined(separator: "、"))\n\n请确认适用于\(flavor.rawValue)。将先备份，再整体替换插件文件夹；依赖需单独安装。", confirm: "备份并安装", destructive: false, action: {
                    guard self.gameIsClosed(), self.target == target, self.flavor == flavor else { library.discard(preview); return }
                    self.run("正在备份并安装 CurseForge 插件…", operation: {
                        defer { library.discard(preview) }
                        try library.install(preview, target: target, curseForge: selection)
                    }) { self.refresh() }
                }, cancel: { library.discard(preview); self.status = "已取消安装" })
            }
        } catch { self.error = error.localizedDescription }
    }
    func checkCFUpdates() {
        guard let target, !cfReceipts.isEmpty else { return }
        do {
            let client = try cfClient(), records = cfReceipts, flavor = flavor
            runNetwork("正在检查 CurseForge 来源…", operation: {
                var labels: [UUID: String] = [:]
                for record in records {
                    try Task.checkCancellation()
                    do {
                        guard record.flavor == flavor else { labels[record.id] = "客户端标记不同，请确认目录"; continue }
                        let unchanged = try await Task.detached { try CFTracking.isUnchanged(record, in: target) }.value
                        guard unchanged else { labels[record.id] = "本地文件已修改或缺失，请核对后更新"; continue }
                        let files = try await client.files(modID: record.modID, typeID: record.typeID, version: record.version)
                        labels[record.id] = record.newerFile(in: files).map { "发现更新：" + $0.displayName } ?? "最近 50 个文件中未发现匹配的新正式版本"
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        labels[record.id] = error.localizedDescription
                    }
                }
                return labels
            }) { labels in self.updateLabels.merge(labels) { _, new in new }; self.status = "CurseForge 更新检查完成" }
        } catch { self.error = error.localizedDescription }
    }
    var visible: [Addon] {
        addons.filter { search.isEmpty || [$0.title, $0.folder, $0.author].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    init() {
        if let stored = UserDefaults.standard.string(forKey: "target") { target = URL(fileURLWithPath: stored) }
        if let stored = UserDefaults.standard.string(forKey: "flavor"), let value = Flavor(rawValue: stored) { flavor = value }
        if target != nil { refresh() }
    }
    func run<T>(_ message: String, operation: @escaping () throws -> T, completion: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true; status = message
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            busy = false
            switch result {
            case .success(let value): completion(value)
            case .failure(let failure): error = failure.localizedDescription; status = "操作未完成"
            }
        }
    }
    func refresh() {
        guard let target else { return }
        let flavor = flavor, library = library
        run("正在扫描插件…", operation: { (try AddonScanner.scan(target, flavor: flavor), try library.snapshots(for: target), try SourceTracking.receipts(in: target), try CFTracking.receipts(in: target)) }) { value in
            guard self.target == target, self.flavor == flavor else { self.refresh(); return }
            self.addons = value.0; self.snapshots = value.1; self.sourceReceipts = value.2; self.cfReceipts = value.3; self.updateLabels = [:]
            self.selected.formIntersection(Set(value.0.map(\.folder)))
            self.status = "已扫描 \(value.0.count) 个插件 · \(Date().formatted(date: .omitted, time: .shortened))"
            if !self.checkedLaunch {
                self.checkedLaunch = true
                Task {
                    if self.checkOnLaunch { self.checkGitHubUpdates(); await self.networkTask?.value }
                    if self.cfCheckOnLaunch { self.checkCFUpdates() }
                }
            }
        }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择魔兽世界目录或 Interface/AddOns"
        panel.message = "可选择游戏根目录、客户端目录或现有的 AddOns 文件夹。请确认时光服实际使用的客户端路径。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resolved = url.resolvingSymlinksInPath()
        let found = FileSafety.candidates(resolved)
        guard !found.isEmpty else { error = "没有找到 Interface/AddOns。请先运行一次游戏，或手动建立该目录后重新选择。"; return }
        candidates = found; showCandidates = true
    }
    func selectTarget(_ url: URL) {
        guard !busy else { return }
        target = url; selected = []; addons = []; snapshots = []; sourceReceipts = []; cfReceipts = []; updateLabels = [:]
        UserDefaults.standard.set(url.path, forKey: "target")
        showCandidates = false; refresh()
    }
    func gameIsClosed() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains("warcraft") || ($0.localizedName ?? "").contains("魔兽世界") }) {
            error = "请先退出《魔兽世界》，再修改插件文件。"; return false
        }
        return true
    }
    func importZIP() {
        guard let target, gameIsClosed() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        panel.title = "导入插件 ZIP"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let library = library, flavor = flavor
        run("正在检查 ZIP 安全性与插件结构…", operation: { try library.prepare(archive, target: target, flavor: flavor) }) { preview in
            self.status = "ZIP 检查完成，等待确认"
            self.prompt = Prompt(title: "安装 \(preview.folders.count) 个插件？", message: "目标：\(target.path)\n\n安装：\(preview.folders.map(\.lastPathComponent).joined(separator: "、"))\n\n覆盖：\(preview.replacing.isEmpty ? "无" : preview.replacing.joined(separator: "、"))\n\n将先备份全部插件。文件夹会整体替换，请确认版本适用于当前客户端。", confirm: "备份并安装", destructive: false, action: {
                guard self.gameIsClosed() else { library.discard(preview); return }
                self.run("正在备份并安装…", operation: {
                    defer { library.discard(preview) }
                    try library.install(preview, target: target)
                }) { self.refresh() }
            }, cancel: { library.discard(preview); self.status = "已取消导入" })
        }
    }
    func uninstall() {
        guard let target, !selected.isEmpty, gameIsClosed() else { return }
        let folders = selected.sorted(), library = library
        prompt = Prompt(title: "卸载 \(folders.count) 个插件？", message: folders.joined(separator: "、") + "\n\n将先备份全部插件。依赖这些插件的其他插件可能无法正常使用。WTF 设置不会删除。", confirm: "备份并卸载", destructive: true, action: {
            guard self.gameIsClosed() else { return }
            self.run("正在备份并卸载…", operation: { try library.uninstall(folders, target: target) }) { self.refresh() }
        })
    }
    func backup() {
        guard let target, gameIsClosed() else { return }
        let library = library
        run("正在创建完整插件备份…", operation: { try library.backup(target, reason: "手动备份") }) { _ in self.refresh() }
    }
    func restore(_ snapshot: Snapshot) {
        guard let target, gameIsClosed() else { return }
        let library = library
        prompt = Prompt(title: "恢复这份备份？", message: "\(snapshot.date.formatted())\n\n将整体替换当前 AddOns，备份后新增的插件也会移除。恢复前会再备份当前插件。WTF 设置不在备份范围。", confirm: "备份当前并恢复", destructive: true, action: {
            guard self.gameIsClosed() else { return }
            self.run("正在恢复插件…", operation: { try library.restore(snapshot, target: target) }) { self.refresh() }
        })
    }
}

struct ContentView: View {
    @ObservedObject var model: ManagerModel
    @State private var page = "插件库"
    private let gold = Color(red: 0.89, green: 0.70, blue: 0.39)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 26)).foregroundStyle(gold)
                    VStack(alignment: .leading) { Text("艾泽拉斯").font(.title3.bold()); Text("插 件 管 家").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 18)
                Text("工作空间").font(.caption).foregroundStyle(.secondary)
                ForEach(["插件库", "在线插件", "备份与恢复", "关于与更新"], id: \.self) { item in
                    Button { page = item } label: {
                        Label(item, systemImage: item == "插件库" ? "square.grid.2x2" : item == "在线插件" ? "network" : item == "备份与恢复" ? "clock.arrow.circlepath" : "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(page == item ? gold.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(page == item ? gold : .secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label("本地 + 在线来源", systemImage: "internaldrive").foregroundStyle(gold)
                    Text("CurseForge / GitHub\n搜索、下载与更新检查。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }.padding(22).frame(width: 205).background(Color(red: 0.065, green: 0.075, blue: 0.09))
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                header
                if page == "插件库" { libraryView }
                else if page == "在线插件" { onlineView }
                else if page == "备份与恢复" { backupView }
                else { aboutView }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(gold) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Text("v0.3.0").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(28).background(Color(red: 0.09, green: 0.10, blue: 0.12))
        }
        .disabled(model.busy)
        .overlay(alignment: .bottomTrailing) {
            if model.networkTask != nil {
                Button("取消网络操作") { model.networkTask?.cancel() }.padding(.trailing, 110).padding(.bottom, 16)
            }
        }
        .alert(item: $model.prompt) { prompt in
            Alert(title: Text(prompt.title), message: Text(prompt.message), primaryButton: prompt.destructive ? .destructive(Text(prompt.confirm), action: prompt.action) : .default(Text(prompt.confirm), action: prompt.action), secondaryButton: .cancel(Text("取消"), action: prompt.cancel))
        }
        .sheet(isPresented: $model.showCandidates) {
            VStack(alignment: .leading, spacing: 18) {
                Text("确认客户端目录").font(.title2.bold())
                Text("时光服的目录命名可能不同，请按战网实际启动路径选择。此处不会自动判断客户端版本。").foregroundStyle(.secondary)
                Picker("用途标记", selection: $model.flavor) { ForEach(Flavor.allCases) { Text($0.rawValue).tag($0) } }
                ForEach(model.candidates, id: \.path) { url in
                    Button { model.selectTarget(url) } label: {
                        HStack { Image(systemName: "folder"); Text(url.path).textSelection(.enabled); Spacer(); Text("使用此目录") }.padding(10)
                    }
                }
                Button("取消") { model.showCandidates = false }
            }.padding(28).frame(width: 720).disabled(model.busy)
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(page).font(.system(size: 28, weight: .bold))
                    Text(page == "插件库" ? "让每一次冒险，从整洁的插件开始。" : page == "备份与恢复" ? "为熟悉的界面，留一份回到过去的机会。" : "原生 macOS · 中文 · 本地优先").foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择游戏目录", systemImage: "folder.badge.plus", action: model.chooseDirectory)
            }
            HStack {
                Image(systemName: "externaldrive.fill").foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.flavor.rawValue).font(.subheadline.bold())
                    Text(model.target?.path ?? "尚未选择 Interface/AddOns").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Picker("客户端", selection: $model.flavor) { ForEach(Flavor.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 145)
                    .onChange(of: model.flavor) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "flavor"); model.refresh() }
            }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("\(model.addons.count)").font(.title.bold()).foregroundStyle(gold)
                Text("个本地插件").foregroundStyle(.secondary)
                Spacer()
                Button("重新扫描", systemImage: "arrow.clockwise", action: model.refresh)
                Button(action: model.importZIP) {
                    Label("导入 ZIP", systemImage: "plus")
                        .foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(gold, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }.disabled(model.target == nil)
            HStack {
                TextField("搜索名称、文件夹或作者", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                Spacer()
                Button("在 Finder 中打开") { if let target = model.target { NSWorkspace.shared.open(target) } }.disabled(model.target == nil)
                Button("卸载所选（\(model.selected.count)）", role: .destructive, action: model.uninstall).disabled(model.selected.isEmpty)
            }
            if model.addons.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "shippingbox").font(.system(size: 48)).foregroundStyle(gold.opacity(0.7))
                    Text(model.target == nil ? "先找到你的艾泽拉斯" : "插件库还是空的").font(.title3.bold())
                    Text(model.target == nil ? "选择游戏目录，或直接选择 Interface/AddOns。" : "导入包含插件文件夹的 ZIP，开始安装。无法解析时会显示错误。")
                        .foregroundStyle(.secondary)
                    Button(model.target == nil ? "选择游戏目录" : "导入 ZIP") { if model.target == nil { model.chooseDirectory() } else { model.importZIP() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            } else {
                Table(model.visible, selection: $model.selected) {
                    TableColumn("插件") { addon in
                        VStack(alignment: .leading, spacing: 4) { Text(addon.title).fontWeight(.medium); Text(addon.folder).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 5)
                    }.width(min: 180, ideal: 260)
                    TableColumn("版本", value: \.version).width(min: 80, ideal: 110)
                    TableColumn("作者", value: \.author).width(min: 90, ideal: 130)
                    TableColumn("接口声明", value: \.interface).width(min: 90, ideal: 120)
                }.frame(minHeight: 200)
                if model.selected.count == 1, let addon = model.addons.first(where: { model.selected.contains($0.folder) }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addon.notes.isEmpty ? "此插件没有中文说明。" : addon.notes).lineLimit(3)
                        Text("依赖：\(addon.dependencies)\nTOC：\(addon.tocNames)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Label("接口版本仅作展示，不能据此保证适配时光服。请安装可信来源、对应客户端的插件。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var backupView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("完整 AddOns 快照").font(.title3.bold()); Spacer()
                Button("打开备份目录") {
                    do { try FileManager.default.createDirectory(at: model.library.backupRoot, withIntermediateDirectories: true); NSWorkspace.shared.open(model.library.backupRoot) }
                    catch { model.error = error.localizedDescription }
                }
                Button("立即备份", systemImage: "archivebox", action: model.backup).disabled(model.target == nil)
            }
            Text("安装、卸载和恢复前都会自动备份。备份只包含插件文件，不包含 WTF / SavedVariables 设置。备份保留在本机，暂不自动清理。").font(.callout).foregroundStyle(.secondary)
            if model.snapshots.isEmpty { Text("当前目录还没有备份。").foregroundStyle(.secondary).padding(.vertical, 30) }
            List(model.snapshots) { snapshot in
                HStack {
                    Image(systemName: "archivebox.fill").foregroundStyle(gold).padding(.trailing, 8)
                    VStack(alignment: .leading, spacing: 6) { Text(snapshot.date.formatted()); Text(snapshot.reason).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("恢复") { model.restore(snapshot) }
                }.padding(.vertical, 8)
            }.listStyle(.inset)
        }
    }
    private var onlineView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("插件来源", selection: $model.onlineProvider) {
                Text("CurseForge").tag("CurseForge")
                Text("GitHub 作者发布").tag("GitHub")
            }.pickerStyle(.segmented)
            if model.onlineProvider == "CurseForge" { curseForgeView } else { githubView }
        }
    }
    private var curseForgeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("CurseForge 插件搜索").font(.title3.bold())
                HStack {
                    SecureField("输入 API Key", text: $model.apiKeyInput).textFieldStyle(.roundedBorder)
                    Button("保存并验证", action: model.saveCFKey).disabled(model.apiKeyInput.isEmpty)
                    Button("验证已存密钥 / 读取分支", action: model.loadCFTypes)
                    Button("移除密钥", action: model.deleteCFKey)
                }
                Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("客户端分支", selection: $model.cfTypeID) {
                        Text("请选择分支").tag(0)
                        ForEach(model.cfTypes) { type in Text(type.name).tag(type.id) }
                    }.onChange(of: model.cfTypeID) { _, _ in model.cfFiles = []; model.cfMod = nil }
                    TextField("可选：精确游戏版本，如 12.0.0", text: $model.cfVersion).textFieldStyle(.roundedBorder)
                        .onChange(of: model.cfVersion) { _, _ in model.cfFiles = []; model.cfMod = nil }
                }
                Text("请按作者说明选择实际客户端分支。国服时光服标记不代表 CurseForge 已验证兼容；仅列出匹配分支的正式 ZIP，依赖需单独安装。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("插件名或关键词（留空浏览热门）", text: $model.cfQuery).textFieldStyle(.roundedBorder).onSubmit { model.searchCF() }
                    Button("搜索") { model.searchCF() }
                }
                if let page = model.cfPage {
                    HStack {
                        Text("第 \(page.pagination.index / 20 + 1) 页 · 共 \(page.pagination.totalCount) 项").foregroundStyle(.secondary)
                        Spacer()
                        Button("上一页") { model.searchCF(index: max(0, page.pagination.index - 20)) }.disabled(page.pagination.index == 0)
                        Button("下一页") { model.searchCF(index: page.pagination.index + 20) }.disabled(!page.hasNext || page.pagination.index >= 9980)
                    }
                    ForEach(page.data) { mod in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mod.name).fontWeight(.medium)
                                Text(mod.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                if let url = mod.safeWebsite { Link("作者页面", destination: url) }
                                if mod.allowModDistribution == false { Text("作者禁止第三方分发，请在作者页面获取").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Button("查看版本") { model.loadCFFiles(mod) }.disabled(model.cfTypeID == 0 || mod.allowModDistribution == false)
                        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let mod = model.cfMod {
                    Divider()
                    Text(mod.name + " · 可用正式文件").font(.headline)
                    if model.cfFiles.isEmpty { Text("最近 50 个文件中没有匹配结果，请核对客户端分支和游戏版本。").foregroundStyle(.secondary) }
                    ForEach(model.cfFiles) { file in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(file.displayName).fontWeight(.medium)
                            Text("游戏版本：" + file.gameVersions.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                            Text("\(file.fileDate) · \(ByteCountFormatter.string(fromByteCount: Int64(file.fileLength), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            let required = file.dependencies.filter { $0.relationType == 3 }
                            if !required.isEmpty { Text("必需依赖（插件 ID）：" + required.map { String($0.modId) }.joined(separator: "、")).font(.caption).foregroundStyle(.orange) }
                            Button("下载、校验并预览安装") { model.downloadCF(file) }.disabled(model.target == nil || mod.allowModDistribution == false)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider()
                HStack {
                    Text("已安装的 CurseForge 来源").font(.headline)
                    Spacer()
                    Button("检查更新", action: model.checkCFUpdates).disabled(model.cfReceipts.isEmpty)
                }
                Toggle("启动时自动检查 CurseForge 更新", isOn: $model.cfCheckOnLaunch)
                    .onChange(of: model.cfCheckOnLaunch) { _, value in UserDefaults.standard.set(value, forKey: "checkCurseForgeOnLaunch") }
                Text("默认关闭；按安装时的分支与可选游戏版本检查。更新仍需预览、确认并备份，不会静默覆盖本地文件。").font(.caption).foregroundStyle(.secondary)
                if model.cfReceipts.isEmpty { Text("通过 CurseForge 安装后会记录来源。已有的手动插件不会自动匹配。").foregroundStyle(.secondary) }
                ForEach(model.cfReceipts) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("插件 ID \(record.modID) · 文件 ID \(record.fileID)").fontWeight(.medium)
                            Spacer()
                            Button("查看版本 / 更新") { model.openCFRecord(record) }
                        }
                        Text(record.folders.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        Text("\(record.flavor.rawValue) · 分支 \(record.typeID) · \(record.version.isEmpty ? "不限精确版本" : record.version)").font(.caption).foregroundStyle(.secondary)
                        if let label = model.updateLabels[record.id] { Text(label).foregroundStyle(gold) }
                    }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.bottom, 10)
        }
    }
    private var githubView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("GitHub 作者发布").font(.title3.bold())
                Text("输入作者的公开仓库。只读取最近 30 条发布中的正式版 ZIP 附件；不使用源码压缩包。请选择作者标明适用于当前客户端的文件。").foregroundStyle(.secondary)
                HStack {
                    TextField("owner/repo 或 https://github.com/owner/repo", text: $model.repositoryText).textFieldStyle(.roundedBorder)
                        .onSubmit { model.loadReleases() }
                    Button("读取发布", action: model.loadReleases).disabled(model.repositoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let repository = model.loadedRepository {
                    Link("查看 \(repository.fullName) 的作者页面", destination: repository.webURL)
                    if model.releases.isEmpty { Text("未找到正式发布。该仓库可能只提供源码或预发布版本。").foregroundStyle(.secondary) }
                    else {
                        Picker("正式版本", selection: $model.releaseID) {
                            ForEach(model.releases) { release in Text(release.title + " · " + release.tagName).tag(Optional(release.id)) }
                        }.onChange(of: model.releaseID) { _, _ in model.assetID = nil }
                        if let release = model.chosenRelease {
                            Text(release.body ?? "作者未填写更新说明").font(.caption).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                            if release.zipAssets.isEmpty { Text("此发布没有可安装的 ZIP 附件。").foregroundStyle(.secondary) }
                            ForEach(release.zipAssets) { asset in
                                HStack {
                                    Button { model.assetID = asset.id } label: {
                                        HStack {
                                            Image(systemName: model.assetID == asset.id ? "checkmark.circle.fill" : "circle")
                                            Text(asset.name).lineLimit(2)
                                        }
                                    }.buttonStyle(.plain)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    Text(asset.digest == nil ? "无远端摘要" : "提供 SHA-256").font(.caption).foregroundStyle(.secondary)
                                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                            Button("下载、检查并预览安装", systemImage: "arrow.down.circle", action: model.downloadChosenAsset)
                                .disabled(model.chosenAsset == nil || model.target == nil)
                            if model.target == nil { Text("先选择游戏目录才能安装。").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("已记录的 GitHub 来源").font(.title3.bold())
                    Spacer()
                    Button("检查更新", systemImage: "arrow.clockwise", action: model.checkGitHubUpdates).disabled(model.sourceReceipts.isEmpty)
                }
                Toggle("启动时自动检查 GitHub 更新", isOn: $model.checkOnLaunch)
                    .onChange(of: model.checkOnLaunch) { _, value in UserDefaults.standard.set(value, forKey: "checkGitHubOnLaunch") }
                Text("自动检查默认关闭；只检查来源记录，不会静默安装。已手动安装的插件不会被猜测绑定到某个仓库。更新时仍需选择客户端附件并确认。").font(.caption).foregroundStyle(.secondary)
                if model.sourceReceipts.isEmpty { Text("通过上方下载并安装后，将在此记录来源。手动 ZIP 导入暂不跟踪在线版本。").foregroundStyle(.secondary) }
                ForEach(model.sourceReceipts) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.repository.fullName).fontWeight(.medium)
                            Spacer()
                            Button("查看发布 / 更新") {
                                model.repositoryText = record.repository.fullName; model.loadReleases()
                            }
                        }
                        Text("已安装：\(record.tagName) · \(record.flavor.rawValue)\n附件：\(record.assetName)\n插件：\(record.folders.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let label = model.updateLabels[record.id] { Text(label).font(.callout).foregroundStyle(gold) }
                    }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("GitHub 匿名请求有频率限制，网络失败会明确报错。").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 10)
        }
    }
    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("CurseForge 与 GitHub · v0.3", systemImage: "network").font(.title3.bold()).foregroundStyle(gold)
            Text("已接入公开 GitHub 仓库的正式发布 ZIP：读取版本、下载、安全安装、来源记录和新版本检查。可选择启动时自动检查，更新安装仍需确认。已接入 CurseForge 搜索、版本筛选、校验下载和更新检查。密钥保存在本机钥匙串。无人值守自动安装尚未实现。")
            Divider()
            Text("使用前请退出游戏").font(.headline)
            Text("先确认实际客户端的 AddOns 路径，再导入 ZIP。时光服用途标记不代表自动适配；TOC 优先读取通用文件，正式服优先读取 Mainline 文件。请在游戏内验证兼容性。")
            Text("安全与恢复").font(.headline)
            Text("只接受常规 ZIP，拒绝路径穿越、链接、加密、ZIP64、重复路径与超限压缩包。安装按文件夹整体替换，避免混留旧文件。操作期间请勿同时使用其他插件管理器或修改 AddOns。异常中断的恢复方法见工程 README。")
            Spacer()
        }.foregroundStyle(.secondary)
    }
}
