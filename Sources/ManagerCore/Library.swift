import Foundation

public struct Snapshot: Identifiable, Codable, Hashable {
    public let id: String
    public let date: Date
    public let reason: String
    public let target: String
}
public struct InstallPreview {
    public let staging: URL
    public let folders: [URL]
    public let replacing: [String]
}
/// All mutations are serialized by the UI. Each operation prepares a whole-tree replacement
/// on the same volume, then renames it, retaining the original until commit succeeds.
public final class Library {
    let fm = FileManager.default
    public let backupRoot: URL
    public init(backupRoot: URL? = nil) {
        self.backupRoot = backupRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AzerothManager/Backups", isDirectory: true)
    }
    public func snapshots(for target: URL) throws -> [Snapshot] {
        guard fm.fileExists(atPath: backupRoot.path) else { return [] }
        return try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.id == dir.lastPathComponent, snapshot.target == target.standardizedFileURL.path else { return nil }
            return snapshot
        }.sorted { $0.date > $1.date }
    }
    @discardableResult public func backup(_ target: URL, reason: String) throws -> Snapshot {
        try FileSafety.validateTarget(target)
        let snapshot = Snapshot(id: UUID().uuidString, date: Date(), reason: reason, target: target.standardizedFileURL.path)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let pending = backupRoot.appendingPathComponent(".pending-" + snapshot.id)
        do {
            try fm.createDirectory(at: pending, withIntermediateDirectories: false)
            try fm.copyItem(at: target, to: pending.appendingPathComponent("AddOns"))
            try JSONEncoder().encode(snapshot).write(to: pending.appendingPathComponent("snapshot.json"), options: .atomic)
            try fm.moveItem(at: pending, to: backupRoot.appendingPathComponent(snapshot.id))
        } catch { try? fm.removeItem(at: pending); throw error }
        return snapshot
    }
    public func prepare(_ archive: URL, target: URL, flavor: Flavor, newBeeCompatibility: Bool = false) throws -> InstallPreview {
        try FileSafety.validateTarget(target)
        let staging = fm.temporaryDirectory.appendingPathComponent("AzerothImport-" + UUID().uuidString)
        do {
            try SafeZIP.extract(archive, into: staging, newBeeCompatibility: newBeeCompatibility)
            var folders: [URL] = []
            func walk(_ dir: URL, depth: Int) throws {
                guard depth <= 8 else { throw ManagerError("插件 ZIP 的目录层级过深") }
                let children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                let name = dir.lastPathComponent.lowercased()
                let hasTOC = children.contains { $0.pathExtension.lowercased() == "toc" && ($0.deletingPathExtension().lastPathComponent.lowercased() == name || $0.lastPathComponent.lowercased().hasPrefix(name + "_") || $0.lastPathComponent.lowercased().hasPrefix(name + "-")) }
                if hasTOC { folders.append(dir); return }
                for child in children where child.lastPathComponent != "__MACOSX" {
                    if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try walk(child, depth: depth + 1) }
                }
            }
            try walk(staging, depth: 0)
            guard !folders.isEmpty else { throw ManagerError("没有找到名称匹配的插件文件夹与 .toc 文件") }
            let keys = folders.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            guard Set(keys).count == folders.count else { throw ManagerError("ZIP 中有同名插件，无法决定安装哪一个") }
            // Parsing now ensures malformed metadata cannot leave a partially installed batch.
            for folder in folders { _ = try AddonScanner.scan(folder.deletingLastPathComponent(), flavor: flavor) }
            let existing = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            let replacing = existing.filter { keys.contains($0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()) }.map(\.lastPathComponent)
            return InstallPreview(staging: staging, folders: folders.sorted { $0.lastPathComponent < $1.lastPathComponent }, replacing: replacing)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    public func discard(_ preview: InstallPreview) { try? fm.removeItem(at: preview.staging) }
    public func install(_ preview: InstallPreview, target: URL, expected: [String: String] = [:], dd: DDSelection? = nil) throws {
        try InstalledUpdates.verify(expected, target: target)
        try FileSafety.checkTree(preview.staging)
        let ddReceipt = try dd.map { try DDReceipt(selection: $0, folders: preview.folders) }
        func verifyNewDDDestinations(_ directory: URL) throws {
            guard dd != nil else { return }
            func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
            let expectedKeys = Set(expected.keys.map(key))
            let newKeys = Set(preview.folders.map { key($0.lastPathComponent) }).subtracting(expectedKeys)
            let existing = Set(try fm.contentsOfDirectory(atPath: directory.path).map(key))
            guard newKeys.isDisjoint(with: existing) else { throw ManagerError("检查后出现了新插件目录，请重新检查更新") }
        }
        try verifyNewDDDestinations(target)
        try mutate(target, reason: "安装 ZIP 前") { next in
            try InstalledUpdates.verify(expected, target: next)
            try verifyNewDDDestinations(next)
            for folder in preview.folders {
                let key = folder.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                for existing in try self.fm.contentsOfDirectory(at: next, includingPropertiesForKeys: nil) where existing.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == key { try self.fm.removeItem(at: existing) }
                try self.fm.copyItem(at: folder, to: next.appendingPathComponent(folder.lastPathComponent))
            }
            var ddRecords = DDTracking.removing(preview.folders.map(\.lastPathComponent), from: try DDTracking.receipts(in: next))
            if let ddReceipt { ddRecords.append(ddReceipt) }
            try DDTracking.write(ddRecords, to: next)
        }
    }
    public func uninstall(_ folders: [String], target: URL) throws {
        guard !folders.isEmpty, folders.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }) else { throw ManagerError("插件名称无效") }
        try mutate(target, reason: "卸载前：" + folders.joined(separator: "、")) { next in
            for folder in folders { try self.fm.removeItem(at: next.appendingPathComponent(folder)) }
            try DDTracking.write(DDTracking.removing(folders, from: DDTracking.receipts(in: next)), to: next)
        }
    }
    public func restore(_ snapshot: Snapshot, target: URL) throws {
        guard UUID(uuidString: snapshot.id) != nil, snapshot.target == target.standardizedFileURL.path else { throw ManagerError("此备份不属于当前目录") }
        let source = backupRoot.appendingPathComponent(snapshot.id).appendingPathComponent("AddOns")
        try FileSafety.checkTree(source)
        try mutate(target, reason: "恢复备份前") { next in
            try self.fm.removeItem(at: next)
            try self.fm.copyItem(at: source, to: next)
        }
    }
    private func mutate(_ target: URL, reason: String, change: (URL) throws -> Void) throws {
        try FileSafety.validateTarget(target)
        _ = try backup(target, reason: reason)
        let parent = target.deletingLastPathComponent(), token = UUID().uuidString
        let next = parent.appendingPathComponent(".Azeroth-next-" + token)
        let old = parent.appendingPathComponent(".Azeroth-old-" + token)
        do {
            try fm.copyItem(at: target, to: next)
            try change(next)
            try FileSafety.checkTree(next)
            try fm.moveItem(at: target, to: old)
            do { try fm.moveItem(at: next, to: target) }
            catch {
                do { try fm.moveItem(at: old, to: target) }
                catch { throw ManagerError("提交及回滚失败。原插件保存在 \(old.path)，请退出游戏后手动恢复；完整备份位于 \(backupRoot.path)") }
                throw error
            }
            // Original remains recoverable through the completed snapshot if cleanup fails.
            try? fm.removeItem(at: old)
        } catch { try? fm.removeItem(at: next); throw error }
    }
}
