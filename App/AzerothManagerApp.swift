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
            let updates = result.values.filter { $0.ddSelection != nil }.count
            self.status = "DD 检查完成 · 匹配 \(matched) 个文件夹 · \(updates) 个文件夹可更新 · 更新前自动备份"
        }
    }
    func updateInstalled(_ addon: Addon) {
        guard let item = installedUpdates[addon.folder], let selection = item.ddSelection else { return }
        updateDD(addon, selection: selection, expected: item.expected)
    }
    func updateDD(_ addon: Addon, selection: DDSelection, expected: [String: String]) {
        guard let target, selection.flavor == flavor, !busy, gameIsClosed() else { return }
        let client = DDClient(), library = library, flavor = flavor
        runNetwork("正在从 DD 下载并校验 \(selection.package.name)…", operation: {
            let refreshed = try await client.refresh(selection, target: target, expected: expected)
            let archive = try await client.download(refreshed)
            defer { try? FileManager.default.removeItem(at: archive) }
            let preview = try await Task.detached { try library.prepare(archive, target: target, flavor: flavor) }.value
            do {
                try Task.checkCancellation()
                guard preview.folders.contains(where: { $0.lastPathComponent == addon.folder }) else { throw ManagerError("DD 新版缺少所选插件目录，已停止安装") }
                try await client.verify(preview, selection: refreshed)
                return preview
            } catch { library.discard(preview); throw error }
        }) { preview in
            guard self.target == target, self.flavor == flavor, self.gameIsClosed() else { library.discard(preview); return }
            self.run("正在自动备份并安装 DD 插件…", operation: {
                defer { library.discard(preview) }
                try library.install(preview, target: target, expected: expected, dd: selection)
            }) { self.refresh() }
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
        target = url; selected = []; addons = []; snapshots = []; installedUpdates = [:]
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
                ForEach(["插件库", "在线插件", "备份与恢复", "设置与关于"], id: \.self) { item in
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
                else if page == "备份与恢复" { backupView }
                else { aboutView }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(gold) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Text("v0.7.0").font(.caption).foregroundStyle(.tertiary)
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
                Text("\(model.addons.count)").font(.title.bold()).foregroundStyle(gold)
                Text("个本地插件").foregroundStyle(.secondary)
                Spacer()
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
            Label("网易 DD · 可更新置顶，已是最新置底", systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
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
                    TableColumn("最新版本") { addon in
                        Text(model.installedUpdates[addon.folder]?.latest ?? "—").font(.caption).lineLimit(2)
                    }.width(min: 90, ideal: 120)
                    TableColumn("状态 / 操作") { addon in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.installedUpdates[addon.folder]?.label ?? "等待检查").font(.caption).lineLimit(2)
                            if model.installedUpdates[addon.folder]?.ddSelection != nil {
                                Button { model.updateInstalled(addon) } label: {
                                    Label("更新", systemImage: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 5).foregroundStyle(.black)
                                        .background(gold.gradient, in: Capsule())
                                }.buttonStyle(.plain)
                            } else if let url = model.installedUpdates[addon.folder]?.externalURL, model.installedUpdates[addon.folder]?.label != "已是最新 · DD（TOC）" {
                                Link(destination: url) {
                                    Label("前往 DD", systemImage: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                                        .padding(.horizontal, 11).padding(.vertical, 5).foregroundStyle(gold)
                                        .background(gold.opacity(0.12), in: Capsule())
                                }
                            }
                        }.padding(.vertical, 4)
                    }.width(min: 140, ideal: 180)
                }.frame(minHeight: 200)
                if model.selected.count == 1, let addon = model.addons.first(where: { model.selected.contains($0.folder) }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addon.notes.isEmpty ? "此插件没有中文说明。" : addon.notes).lineLimit(3)
                        Text("依赖：\(addon.dependencies)\nTOC：\(addon.tocNames)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Label("通过网易 DD 官方扫描获取新版并直接更新，安装前自动备份。TOC 匹配不代表所有代码完全一致。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
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
                                        Text("DD 版本：" + (item.latest_version?.version ?? "未知"))
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
                Label("艾泽拉斯插件管家 · v0.7", systemImage: "puzzlepiece.extension").font(.title2.bold()).foregroundStyle(gold)
                Text("仅通过网易 DD 官方扫描查询并直接下载更新，无需密钥。插件库将可更新置顶、已是最新置底；在线页默认展示周热门，也可查看月热门与总下载排行。")
                Divider()
                Text("自动检查与一键更新").font(.headline)
                Text("每次启动、扫描或安装完成后自动检查。DD 使用 TOC 文件名和 MD5 扫描识别插件，并比较包版本 ID；不需要本地 DD 清单。点击更新会复查版本、下载网易 CDN ZIP、检查大小与 ZIP 完整性，再向 DD 核对解压后的 TOC 版本和目录，最后备份整个 AddOns 并安装。DD 未提供整个 ZIP 的密码学摘要，TOC 匹配也不等于所有代码完全一致。")
                Text("请退出游戏后更新。一次更新可能替换同一插件包的多个文件夹，本地修改也会被替换；WTF 设置不会更改。检查后发生本地变更会中止安装，需重新检查。依赖暂不自动安装，未提供无人值守定时更新。")
                Text("网易 DD 国服时光服使用泰坦重铸分支，正式服使用正式服分支。作者标记仍不能保证游戏内兼容。应用仅本机临时签名，尚无发行签名或公证。").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }
    }

}
