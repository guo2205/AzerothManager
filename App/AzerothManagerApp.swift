import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ManagerCore
import WebKit

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
    @Published var networkTask: Task<Void, Never>?
    let library = Library()
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
                if error is CancellationError || (error as? URLError)?.code == .cancelled { status = "已取消网络操作"; self.installedUpdates = self.installedUpdates.mapValues { $0.label == "检查中…" ? InstalledUpdate(label: "检查已取消") : $0 } }
                else {
                    self.error = error.localizedDescription; status = "网络操作未完成"
                    self.installedUpdates = self.installedUpdates.mapValues { $0.label == "检查中…" ? InstalledUpdate(label: "检查失败，请重试") : $0 }
                }
            }
        }
    }
    @Published var shareQuery = "297986"
    @Published var sharePage: DDSharePage?
    @Published var shareDetail: DDShareDetail?
    @Published var shareMessage = "选择网易 DD 配置分享，读取内容后预览安装。"
    func searchShares() {
        let query = shareQuery, flavor = flavor
        runNetwork("正在搜索 DD 配置分享…", operation: { try await DDShareClient().search(query, flavor: flavor) }) { page in
            self.sharePage = page; self.shareDetail = nil
            if page.shares.count == 1, let first = page.shares.first { self.loadShare(first.sn) }
        }
    }
    func loadShare(_ sn: String) {
        let flavor = flavor
        runNetwork("正在读取 DD 分享详情…", operation: { try await DDShareClient().detail(sn, flavor: flavor) }) { detail in
            self.shareDetail = detail
            self.shareMessage = detail.hasConfigurationDownload ? "已读取配置下载信息，待检查安装内容" : "DD 暂未提供配置下载地址，请在官方页面登录后重新读取。"
        }
    }
    @Published var ddQuery = ""
    @Published var ddPage: DDPage?
    @Published var ddPageNumber = 1
    @Published var ddSort: DDSort = .weekly
    @Published var ddLoadedQuery = ""
    @Published var ddLoadedSort: DDSort = .weekly
    @Published var installedUpdates: [String: InstalledUpdate] = [:]
    private var ddNeedsInitialLoad = true
    func searchDD(page: Int = 1) {
        guard !busy else { return }
        ddNeedsInitialLoad = false
        let query = page == 1 ? ddQuery.trimmingCharacters(in: .whitespacesAndNewlines) : ddLoadedQuery
        let sort = page == 1 ? ddSort : ddLoadedSort
        let flavor = flavor, type = DDClient.gameType(flavor)
        runNetwork(query.isEmpty ? "正在加载网易 DD 热门插件…" : "正在搜索网易 DD 插件…", operation: {
            try await DDClient().search(query, gameType: type, page: page, sort: sort)
        }) { result in
            guard self.flavor == flavor else { return }
            self.ddPage = result; self.ddPageNumber = page; self.ddLoadedQuery = query; self.ddLoadedSort = sort
            self.status = query.isEmpty ? "已加载网易 DD \(sort.rawTitle) · 已安装插件可在插件库直接更新" : "网易 DD 搜索完成"
        }
    }
    func showPopularDD() { ddQuery = ""; searchDD() }
    func invalidateCatalogue() { ddPage = nil; ddPageNumber = 1; ddNeedsInitialLoad = true }
    func ensureOnline() { if ddNeedsInitialLoad && !busy { searchDD() } }
    func checkInstalledUpdates() {
        guard !busy else { return }
        guard let target, !addons.isEmpty else { status = "选择游戏目录后可检查更新"; return }
        let addons = addons, flavor = flavor
        installedUpdates = Dictionary(uniqueKeysWithValues: addons.map { ($0.folder, InstalledUpdate(label: "检查中…")) })
        runNetwork("正在通过网易 DD 检查版本…", operation: { try await DDClient().check(target: target, addons: addons, flavor: flavor) }) { result in
            guard self.target == target, self.flavor == flavor else { return }
            self.installedUpdates = result
            let matched = result.values.filter { $0.externalURL != nil }.count
            let updates = self.updateablePackages.count
            self.status = "DD 检查完成 · 匹配 \(matched) 个文件夹 · \(updates) 个插件包可更新 · 更新前自动备份"
        }
    }
    @Published var batchResult: PackageBatchResult?
    var packages: [AddonPackageRow] { InstalledUpdates.packages(addons, updates: installedUpdates) }
    var visiblePackages: [AddonPackageRow] { InstalledUpdates.packages(addons, updates: installedUpdates, search: search) }
    var updateablePackages: [AddonPackageRow] { packages.filter(\.canUpdate) }
    func updatePackage(_ row: AddonPackageRow) {
        guard let update = row.update, let selection = update.ddSelection else { return }
        startPackageUpdates([PackageUpdateJob(selection: selection, expected: update.expected)])
    }
    func updateAllPackages() {
        let jobs = updateablePackages.compactMap { row -> PackageUpdateJob? in
            guard let update = row.update, let selection = update.ddSelection else { return nil }
            return PackageUpdateJob(selection: selection, expected: update.expected)
        }
        startPackageUpdates(jobs)
    }
    func startPackageUpdates(_ jobs: [PackageUpdateJob]) {
        guard !busy, !jobs.isEmpty, let target, gameIsClosed(), jobs.allSatisfy({ $0.selection.flavor == flavor }) else { return }
        let flavor = flavor, library = library, client = DDClient()
        batchResult = nil; busy = true; status = "正在准备更新 \(jobs.count) 个插件包…"
        networkTask = Task {
            let result = await PackageBatch.run(jobs, progress: { index, total, name in
                self.status = "更新 \(index)/\(total)：\(name) · 下载、校验、备份并安装"
            }, operation: { job in
                guard self.target == target, self.flavor == flavor else { throw CancellationError() }
                guard self.gameIsClosed() else { throw CancellationError() }
                let refreshed = try await client.refresh(job.selection, target: target, expected: job.expected)
                let archive = try await client.download(refreshed)
                defer { try? FileManager.default.removeItem(at: archive) }
                let preview = try await Task.detached { try library.prepare(archive, target: target, flavor: flavor) }.value
                defer { library.discard(preview) }
                try Task.checkCancellation()
                try await client.verify(preview, selection: refreshed)
                try Task.checkCancellation()
                guard self.target == target, self.flavor == flavor, self.gameIsClosed() else { throw CancellationError() }
                // 文件事务开始后不再取消，确保本包完成或回滚；取消会在下一包生效。
                try await Task.detached { try library.install(preview, target: target, expected: job.expected, dd: refreshed) }.value
            })
            self.batchResult = result
            self.busy = false; self.networkTask = nil
            self.status = "更新结束 · 成功 \(result.succeeded) 包 · 失败 \(result.failed) 包" + (result.cancelled ? " · 剩余 \(result.remaining) 包未执行" : "")
            self.refresh()
        }
    }
    var visible: [Addon] { InstalledUpdates.ordered(addons, updates: installedUpdates, search: search) }
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
        run("正在扫描插件…", operation: { (try AddonScanner.scan(target, flavor: flavor), try library.snapshots(for: target)) }) { value in
            guard self.target == target, self.flavor == flavor else { self.refresh(); return }
            self.addons = value.0; self.snapshots = value.1; self.installedUpdates = [:]
            self.selected.formIntersection(Set(value.0.map(\.folder)))
            self.status = "已扫描 \(value.0.count) 个插件 · \(Date().formatted(date: .omitted, time: .shortened))"
            self.checkInstalledUpdates()
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
        target = url; selected = []; addons = []; snapshots = []; installedUpdates = [:]; batchResult = nil
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
    @StateObject private var ddShareSession = DDShareWebSession()
    @State private var showShareLogin = false
    @State private var expandedPackages: Set<String> = []
    private let gold = Color(red: 0.89, green: 0.70, blue: 0.39)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 26)).foregroundStyle(gold)
                    VStack(alignment: .leading) { Text("艾泽拉斯").font(.title3.bold()); Text("插 件 管 家").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 18)
                Text("工作空间").font(.caption).foregroundStyle(.secondary)
                ForEach(["插件库", "在线插件", "配置分享", "备份与恢复", "设置与关于"], id: \.self) { item in
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
                    Text("网易 DD 实时检查\n一键更新，先备份。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }.padding(22).frame(width: 205).background(Color(red: 0.065, green: 0.075, blue: 0.09))
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                header
                if page == "插件库" { libraryView }
                else if page == "在线插件" { onlineView }
                else if page == "配置分享" { shareView }
                else if page == "备份与恢复" { backupView }
                else { aboutView }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(gold) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Text("v0.10.0").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(28).background(Color(red: 0.09, green: 0.10, blue: 0.12))
        }
        .onChange(of: model.busy) { _, busy in if !busy && page == "在线插件" { model.ensureOnline() } }
        .disabled(model.busy)
        .overlay(alignment: .bottomTrailing) {
            if model.networkTask != nil {
                Button("取消网络操作") { model.networkTask?.cancel() }.padding(.trailing, 110).padding(.bottom, 16)
            }
        }
        .alert(item: $model.prompt) { prompt in
            Alert(title: Text(prompt.title), message: Text(prompt.message), primaryButton: prompt.destructive ? .destructive(Text(prompt.confirm), action: prompt.action) : .default(Text(prompt.confirm), action: prompt.action), secondaryButton: .cancel(Text("取消"), action: prompt.cancel))
        }
        .sheet(isPresented: $showShareLogin) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("网易 DD 官方登录与分享详情").font(.headline)
                    Spacer()
                    Button("关闭") { showShareLogin = false }
                }
                Text("请在官方网页完成登录。本应用不接收密码，登录状态只用于本次会话，不保存到源码或钥匙串。").font(.caption).foregroundStyle(.secondary)
                DDShareLoginView(session: ddShareSession)
                HStack {
                    Text(ddShareSession.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("已登录，读取下载信息") {
                        guard let detail = model.shareDetail else { return }
                        Task {
                            do {
                                let value = try await ddShareSession.readDetail(detail.sn)
                                guard value.game_type == DDClient.gameType(model.flavor), value.sn == detail.sn else { throw ManagerError("分享客户端与当前目录不匹配") }
                                model.shareDetail = value
                                model.shareMessage = value.hasConfigurationDownload ? "已取得配置下载信息，等待安装预览" : "插件服务已完成登录，但分享接口仍未返回配置下载地址；尚不能安装。"
                                ddShareSession.message = model.shareMessage
                                if value.hasConfigurationDownload { showShareLogin = false }
                            } catch { ddShareSession.message = ddShareSession.failureMessage(error) }
                        }
                    }
                }
            }.padding(20).frame(width: 1080, height: 750)
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
                    .onChange(of: model.flavor) { _, value in
                        model.invalidateCatalogue(); model.installedUpdates = [:]; UserDefaults.standard.set(value.rawValue, forKey: "flavor"); model.refresh(); if page == "在线插件" { model.ensureOnline() } }
            }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("\(model.packages.count)").font(.title.bold()).foregroundStyle(gold)
                Text("个插件包 · \(model.addons.count) 个目录").foregroundStyle(.secondary)
                Spacer()
                Button("更新全部（\(model.updateablePackages.count) 包）", systemImage: "arrow.down.to.line") { model.updateAllPackages() }
                    .disabled(model.updateablePackages.isEmpty)
                Button(action: model.checkInstalledUpdates) {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(gold.opacity(0.14), in: Capsule()).overlay(Capsule().stroke(gold.opacity(0.3), lineWidth: 1)).foregroundStyle(gold)
                }.buttonStyle(.plain)
                Button("重新扫描", systemImage: "arrow.clockwise", action: model.refresh)
                Button(action: model.importZIP) {
                    Label("导入 ZIP", systemImage: "plus")
                        .foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(gold, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }.disabled(model.target == nil)
            if let result = model.batchResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(result.cancelled ? "已停止后续任务" : "更新完成") · 成功 \(result.succeeded) 包 · 失败 \(result.failed) 包 · 未执行 \(result.remaining) 包").font(.callout.weight(.medium))
                        Spacer()
                        Button("关闭结果") { model.batchResult = nil }.buttonStyle(.plain).font(.caption)
                    }
                    if result.failed > 0 {
                        DisclosureGroup("查看失败原因") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(result.outcomes.enumerated()), id: \.offset) { _, item in
                                        if let error = item.error { Text(item.name + "：" + error).font(.caption).textSelection(.enabled) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 100)
                        }
                    }
                }.padding(12).background(gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Label("网易 DD · 同一整包只更新一次 · 可更新置顶，已是最新置底", systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
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
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.visiblePackages) { row in packageCard(row) }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 200)
                if model.selected.count == 1, let addon = model.addons.first(where: { model.selected.contains($0.folder) }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addon.notes.isEmpty ? "此插件没有中文说明。" : addon.notes).lineLimit(3)
                        Text("依赖：\(addon.dependencies)\nTOC：\(addon.tocNames)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let package = model.installedUpdates[addon.folder]?.packageInfo {
                            Text("所属 DD 包：\(package.name) · 已装整包 \(package.installedVersionText) · 最新整包 \(package.latestVersion)").font(.caption).foregroundStyle(gold).textSelection(.enabled)
                            if package.containsMultipleFolders {
                                Text("更新整包会一起处理这 \(package.folders.count) 个目录：\(package.folders.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    .help(package.folders.joined(separator: "、"))
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Label("本地 TOC 与 DD 整包版本分别显示；子模块随所属包一起更新，安装前自动备份。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func packageCard(_ row: AddonPackageRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Toggle("选择整包", isOn: Binding(get: {
                    row.members.allSatisfy { model.selected.contains($0.folder) }
                }, set: { selected in
                    let folders = Set(row.members.map(\.folder))
                    if selected { model.selected.formUnion(folders) } else { model.selected.subtract(folders) }
                })).labelsHidden().toggleStyle(.checkbox)
                Button {
                    if expandedPackages.contains(row.id) { expandedPackages.remove(row.id) } else { expandedPackages.insert(row.id) }
                } label: {
                    Image(systemName: expandedPackages.contains(row.id) ? "chevron.down" : "chevron.right").frame(width: 16)
                }.buttonStyle(.plain).help("展开子目录与各自的 TOC 版本")
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.headline)
                    Text("\(row.members.count) 个本地目录" + (row.info == nil ? " · 未识别整包来源" : " · DD 整包")).font(.caption).foregroundStyle(.secondary)
                    if row.members.count == 1, let addon = row.members.first {
                        Text("本地 TOC：\(addon.version) · \(addon.folder)").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let info = row.info {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已装包：\(info.installedVersionText)").foregroundStyle(.secondary)
                        Text("最新包：\(info.latestVersion)").foregroundStyle(gold)
                    }.font(.caption).frame(width: 175, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 7) {
                    Text(row.label).font(.caption).foregroundStyle(row.canUpdate ? gold : .secondary)
                    if row.canUpdate {
                        Button { model.updatePackage(row) } label: {
                            Label("更新整包", systemImage: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7).foregroundStyle(.black).background(gold.gradient, in: Capsule())
                        }.buttonStyle(.plain)
                    } else if let url = row.members.compactMap({ model.installedUpdates[$0.folder]?.externalURL }).first, !row.isCurrent {
                        Link("前往 DD ↗", destination: url).font(.caption).foregroundStyle(gold)
                    }
                }.frame(width: 155, alignment: .trailing)
            }
            if expandedPackages.contains(row.id) {
                Divider()
                Text("子目录 TOC 版本独立于整包版本；更新按钮会处理整个包。").font(.caption).foregroundStyle(.secondary)
                ForEach(row.members) { addon in
                    HStack {
                        Toggle("选择 \(addon.folder)", isOn: Binding(get: { model.selected.contains(addon.folder) }, set: { checked in
                            if checked { model.selected.insert(addon.folder) } else { model.selected.remove(addon.folder) }
                        })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(addon.title).font(.callout)
                            Text(addon.folder).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text("本地 TOC：" + addon.version).font(.caption).frame(width: 180, alignment: .leading)
                        Text(addon.author).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .trailing)
                    }.padding(.vertical, 3)
                }
            }
        }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
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
    private var shareView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("网易 DD 配置分享").font(.title2.bold())
            HStack {
                TextField("分享码、标题或作者（露露 NDui：297986）", text: $model.shareQuery).textFieldStyle(.roundedBorder).onSubmit { model.searchShares() }
                Button("搜索分享", action: model.searchShares)
            }
            Text("露露 NDui 时光服分享码：297986。当前支持查询详情与验证官方登录，配置下载安装尚未开放，不会修改 WTF。").font(.caption).foregroundStyle(.secondary)
            if let detail = model.shareDetail {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(detail.title).font(.headline)
                        Text("作者：\(detail.user_nick ?? "未知") · 分享码：\(detail.share_code ?? "未知")").font(.callout)
                        Text(detail.brief_desc ?? "").foregroundStyle(.secondary)
                        Text("插件：\(detail.known_addon?.items?.count ?? 0) 项 · 配置：\(ByteCountFormatter.string(fromByteCount: Int64(detail.wtf?.size ?? 0), countStyle: .file))")
                        Text(model.shareMessage).font(.callout).foregroundStyle(gold)
                        if detail.requiresPurchase { Text("此分享需要购买或粉丝权限，请在 DD 官方平台处理。").foregroundStyle(.orange) }
                        HStack {
                            Button("在 DD 官方页面登录并读取") { ddShareSession.open(detail.website); showShareLogin = true }
                            Link("在浏览器查看分享", destination: detail.website)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.sharePage?.shares ?? []) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline)
                                Text(item.user_nick ?? "未知作者").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("读取详情") { model.loadShare(item.sn) }
                        }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
    private var onlineView: some View { ddOnlineView }
    private var ddOnlineView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.ddLoadedQuery.isEmpty ? "网易 DD 热门插件" : "网易 DD 搜索结果").font(.title2.bold())
                Spacer()
                Button("热门插件", action: model.showPopularDD)
            }
            Picker("热门排行", selection: $model.ddSort) { ForEach(DDSort.allCases) { Text($0.rawTitle).tag($0) } }
                .pickerStyle(.segmented).frame(width: 350)
                .onChange(of: model.ddSort) { _, _ in model.searchDD() }
            Text("查询所选客户端的实时版本。已安装插件在插件库中直接更新；新插件可通过 DD 官方页面安装。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("搜索 DD 插件", text: $model.ddQuery).textFieldStyle(.roundedBorder).onSubmit { model.searchDD() }
                Button("搜索") { model.searchDD() }
            }
            if let page = model.ddPage {
                HStack {
                    Text("共 \(page.count ?? 0) 个结果").foregroundStyle(.secondary)
                    Spacer()
                    Button("上一页") { model.searchDD(page: model.ddPageNumber - 1) }.disabled(model.ddPageNumber <= 1)
                    Text("第 \(model.ddPageNumber) 页").font(.caption)
                    Button("下一页") { model.searchDD(page: model.ddPageNumber + 1) }.disabled(model.ddPageNumber * 20 >= (page.count ?? 0))
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(page.result ?? []) { item in
                            HStack(spacing: 16) {
                                Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(gold).frame(width: 36)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.headline)
                                    Text(item.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    HStack(spacing: 14) {
                                        Text("DD 整包版本：" + (item.latest_version?.version ?? "未知"))
                                        if let downloads = item.downloads(for: model.ddLoadedSort) { Text("\(model.ddLoadedSort.downloadTitle) \(downloads.formatted())") }
                                    }.font(.caption).foregroundStyle(gold)
                                }
                                Spacer()
                                Link("前往 DD ↗", destination: item.website(gameType: DDClient.gameType(model.flavor))).font(.callout.weight(.semibold)).foregroundStyle(gold)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("网易 DD 热门插件", systemImage: "flame")
                } description: { Text(model.busy ? "正在加载排行榜…" : "按所选客户端的下载量排行展示插件") }
                actions: { Button("加载热门插件", action: model.showPopularDD).disabled(model.busy) }
            }
        }.onAppear { model.ensureOnline() }
    }
    private var aboutView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("艾泽拉斯插件管家 · v0.10", systemImage: "puzzlepiece.extension").font(.title2.bold()).foregroundStyle(gold)
                Text("仅通过网易 DD 官方扫描查询并直接下载更新，无需密钥。插件库按整包分组，可更新置顶、已是最新置底；支持一键更新全部，单包失败继续其他任务；在线页默认展示周热门，也可查看月热门与总下载排行。")
                Divider()
                Text("自动检查与一键更新").font(.headline)
                Text("每次启动、扫描或安装完成后自动检查。DD 使用 TOC 文件名和 MD5 扫描识别插件，并比较包版本 ID；不需要本地 DD 清单。本地 TOC 版本由各子目录声明，DD 版本属于整个发布包；二者分开显示，不用依赖插件或整包版本代替子模块版本。点击更新会复查版本、下载网易 CDN ZIP、检查大小与 ZIP 完整性，再向 DD 核对解压后的 TOC 版本和目录，最后备份整个 AddOns 并安装。DD 未提供整个 ZIP 的密码学摘要，TOC 匹配也不等于所有代码完全一致。")
                Text("请退出游戏后更新。一次更新可能替换同一插件包的多个文件夹，本地修改也会被替换；WTF 设置不会更改。检查后发生本地变更会中止安装，需重新检查。依赖暂不自动安装，未提供无人值守定时更新。")
                Text("网易 DD 国服时光服使用泰坦重铸分支，正式服使用正式服分支。作者标记仍不能保证游戏内兼容。应用仅本机临时签名，尚无发行签名或公证。").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }
    }

}

@MainActor final class DDShareWebSession: NSObject, ObservableObject, WKUIDelegate {
    let webView: WKWebView
    @Published var message = "请在网易官方页面登录，完成后点击读取安装内容。"
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 官方网站的登录入口使用新窗口，在同一临时会话中打开。
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           url.scheme == "https", url.host == "dd.163.com" {
            webView.load(navigationAction.request)
        }
        return nil
    }
    func open(_ url: URL) {
        guard url.scheme == "https", url.host == "dd.163.com" else { return }
        webView.load(URLRequest(url: url))
    }
    func failureMessage(_ error: Error) -> String {
        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        // 仅显示本应用定义的固定诊断；不展示网页登录响应、Cookie 或令牌。
        let known = ["网易 DD 接口请求失败，请稍后重试", "DD 响应超过限制", "DD 响应格式无法识别", "分享接口地址无效", "DD 网页已登录，但插件服务登录未完成；当前网页会话可能不支持此登录方式"]
        if let detail, let message = known.first(where: { detail == $0 || detail == "Error: " + $0 }) { return message }
        if (error as NSError).domain == WKError.errorDomain { return "官方网页未能完成插件接口请求，可能是跨域或会话限制；尚未取得下载地址。" }
        return error.localizedDescription
    }
    func readDetail(_ sn: String) async throws -> DDShareDetail {
        guard let url = webView.url, url.scheme == "https", url.host == "dd.163.com" else { throw ManagerError("请先回到网易 DD 官方分享页面") }
        let endpoint = try DDShareClient.detailURL(sn)
        let text: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(DDShareClient.authenticatedDetailScript, arguments: ["endpoint": endpoint.absoluteString], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        guard let string = text as? String else { throw ManagerError("无法读取官方分享响应") }
        return try DDShareClient.decodeDetail(Data(string.utf8))
    }
}
struct DDShareLoginView: NSViewRepresentable {
    let session: DDShareWebSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
