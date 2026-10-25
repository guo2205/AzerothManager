import Foundation

/// DD 发布版本属于插件包，不代表其中任一子目录的 TOC 版本。
public struct DDPackageInfo: Sendable {
    public let projectID: String
    public let name: String
    public let installedVersion: String?
    public let latestVersion: String
    public let folders: [String]
    public var containsMultipleFolders: Bool { folders.count > 1 }
    public var installedVersionText: String {
        let value = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未识别" : value
    }
    init(package: DDScanPackage, latest: DDAddon.Version) {
        projectID = package.sn; name = package.name; installedVersion = package.local_version
        latestVersion = latest.version; folders = package.folders
    }
}

public struct InstalledUpdate: Sendable {
    public let label: String
    public let packageInfo: DDPackageInfo?
    public let externalURL: URL?
    public let ddSelection: DDSelection?
    /// 检查时的本地内容指纹，安装前再次核对。
    public let expected: [String: String]
    public let isCurrent: Bool
    public var sortPriority: Int { ddSelection != nil ? 0 : isCurrent ? 2 : 1 }
    public init(label: String, packageInfo: DDPackageInfo? = nil, expected: [String: String] = [:], externalURL: URL? = nil, ddSelection: DDSelection? = nil, isCurrent: Bool = false) {
        self.label = label; self.packageInfo = packageInfo; self.expected = expected
        self.externalURL = externalURL; self.ddSelection = ddSelection; self.isCurrent = isCurrent
    }
}

public enum InstalledUpdates {
    /// 可更新优先、未识别或待核对居中、已是最新置底；同组保留原顺序。
    public static func ordered(_ addons: [Addon], updates: [String: InstalledUpdate], search: String = "") -> [Addon] {
        addons.enumerated().filter { _, addon in
            search.isEmpty || [addon.title, addon.folder, addon.author].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }.sorted { a, b in
            let left = updates[a.element.folder]?.sortPriority ?? 1, right = updates[b.element.folder]?.sortPriority ?? 1
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }
    public static func verify(_ expected: [String: String], target: URL) throws {
        for (name, fingerprint) in expected {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  try AddonFingerprint.fingerprint(target.appendingPathComponent(name)) == fingerprint else { throw ManagerError("本地插件在检查后发生变化，请重新检查更新") }
        }
    }
}

/// 一个 DD 项目只显示一行；无可靠来源的目录保持独立。
public struct AddonPackageRow: Identifiable {
    public let id: String
    public let title: String
    public let members: [Addon]
    public let info: DDPackageInfo?
    public let update: InstalledUpdate?
    public let label: String
    public let isCurrent: Bool
    public var canUpdate: Bool { update?.ddSelection != nil }
    public var priority: Int { canUpdate ? 0 : isCurrent ? 2 : 1 }
}

public extension InstalledUpdates {
    static func packages(_ addons: [Addon], updates: [String: InstalledUpdate], search: String = "") -> [AddonPackageRow] {
        var order: [String] = [], grouped: [String: [Addon]] = [:]
        for addon in addons {
            let key = updates[addon.folder]?.packageInfo.map { "dd:" + $0.projectID } ?? "folder:" + addon.folder
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(addon)
        }
        // 项目目录交叠时不允许两个包相继覆盖同一目录。
        var owners: [String: Set<String>] = [:]
        for key in order {
            for addon in grouped[key] ?? [] {
                for folder in (updates[addon.folder]?.packageInfo?.folders ?? [addon.folder]) + (updates[addon.folder]?.ddSelection?.version.folders ?? []) {
                    owners[folder.precomposedStringWithCanonicalMapping.lowercased(), default: []].insert(key)
                }
            }
        }
        let rows = order.compactMap { key -> AddonPackageRow? in
            guard let members = grouped[key], let first = members.first else { return nil }
            let states = members.compactMap { updates[$0.folder] }
            let info = states.first?.packageInfo
            let title = info?.name ?? first.title
            let searchable = ([title] + members.flatMap { [$0.title, $0.folder, $0.author] }).joined(separator: " ")
            guard search.isEmpty || searchable.localizedCaseInsensitiveContains(search) else { return nil }
            let overlap = (info?.folders ?? members.map(\.folder)).contains { (owners[$0.precomposedStringWithCanonicalMapping.lowercased()]?.count ?? 0) > 1 }
            let candidate = states.first { $0.ddSelection != nil }
            let consistent = candidate.map { chosen in
                states.count == members.count && states.allSatisfy { state in
                    guard let a = state.ddSelection, let b = chosen.ddSelection else { return false }
                    return a.package.sn == b.package.sn && a.version.sn == b.version.sn && a.flavor == b.flavor && Set(a.package.folders) == Set(b.package.folders)
                }
            } ?? false
            let current = states.count == members.count && states.allSatisfy(\.isCurrent) && !overlap
            let label = overlap ? "目录归属冲突，暂不可更新" : current ? "已是最新" : consistent ? "有新版本" : candidate != nil ? "版本信息不一致，请重新检查" : states.first(where: { !$0.isCurrent })?.label ?? "等待检查"
            return AddonPackageRow(id: key, title: title, members: members, info: info, update: consistent && !overlap ? candidate : nil, label: label, isCurrent: current)
        }
        return rows.enumerated().sorted { a, b in
            a.element.priority == b.element.priority ? a.offset < b.offset : a.element.priority < b.element.priority
        }.map(\.element)
    }
}

public struct PackageUpdateJob: Sendable {
    public let selection: DDSelection
    public let expected: [String: String]
    public init(selection: DDSelection, expected: [String: String]) {
        self.selection = selection
        // 只校验本次包涉及的旧目录；批次中其他包的成功更新不应使后续任务失效。
        let names = Set(selection.package.folders + (selection.version.folders ?? []))
        self.expected = expected.filter { names.contains($0.key) }
    }
}
public struct PackageUpdateOutcome: Sendable {
    public let projectID: String
    public let name: String
    public let error: String?
    public var succeeded: Bool { error == nil }
}
public struct PackageBatchResult: Sendable {
    public let outcomes: [PackageUpdateOutcome]
    public let cancelled: Bool
    public let total: Int
    public var succeeded: Int { outcomes.filter(\.succeeded).count }
    public var failed: Int { outcomes.count - succeeded }
    public var remaining: Int { total - outcomes.count }
}

/// 顺序执行并按项目去重；单包失败继续，取消不打断已开始的文件事务。
public enum PackageBatch {
    public static func run(_ jobs: [PackageUpdateJob], progress: (Int, Int, String) async -> Void = { _, _, _ in }, operation: (PackageUpdateJob) async throws -> Void) async -> PackageBatchResult {
        var seen = Set<String>()
        let unique = jobs.filter { seen.insert($0.selection.package.sn).inserted }
        var outcomes: [PackageUpdateOutcome] = []
        for (index, job) in unique.enumerated() {
            if Task.isCancelled { return PackageBatchResult(outcomes: outcomes, cancelled: true, total: unique.count) }
            await progress(index + 1, unique.count, job.selection.package.name)
            do {
                try await operation(job)
                outcomes.append(PackageUpdateOutcome(projectID: job.selection.package.sn, name: job.selection.package.name, error: nil))
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    return PackageBatchResult(outcomes: outcomes, cancelled: true, total: unique.count)
                }
                outcomes.append(PackageUpdateOutcome(projectID: job.selection.package.sn, name: job.selection.package.name, error: error.localizedDescription))
            }
        }
        return PackageBatchResult(outcomes: outcomes, cancelled: Task.isCancelled, total: unique.count)
    }
}
