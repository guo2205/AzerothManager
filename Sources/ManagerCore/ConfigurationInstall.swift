import Foundation

public struct ConfigurationRole: Codable, Hashable, Identifiable, Sendable {
    public let account: String; public let realm: String; public let name: String
    public var id: String { [account, realm, name].joined(separator: "/") }
    public init(account: String, realm: String, name: String) throws {
        for value in [account, realm, name] { try ConfigurationFiles.validateComponent(value) }
        self.account = account.precomposedStringWithCanonicalMapping
        self.realm = realm.precomposedStringWithCanonicalMapping
        self.name = name.precomposedStringWithCanonicalMapping
    }
    public var relativePath: String { "WTF/Account/" + id }
    enum CodingKeys: String, CodingKey { case account, realm, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), realm: c.decode(String.self, forKey: .realm), name: c.decode(String.self, forKey: .name))
    }
}
public enum ConfigurationFiles {
    public static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ManagerError("账号、角色或目录名称无效") }
    }
    public static func roles(in client: URL) throws -> [ConfigurationRole] {
        try FileSafety.validateTarget(client.appendingPathComponent("Interface/AddOns"))
        let base = client.appendingPathComponent("WTF/Account")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        try FileSafety.checkTree(base)
        func directories(_ url: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter {
                try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true && $0.lastPathComponent.lowercased() != "savedvariables"
            }
        }
        var result: [ConfigurationRole] = []
        for account in try directories(base) {
            for realm in try directories(account) {
                for role in try directories(realm) {
                    // A role already entered in-game has one of these persisted settings files.
                    let files = try FileManager.default.contentsOfDirectory(atPath: role.path)
                    if files.contains(where: { ["config-cache.wtf", "bindings-cache.wtf", "AddOns.txt"].contains($0) }) {
                        result.append(try ConfigurationRole(account: account.lastPathComponent, realm: realm.lastPathComponent, name: role.lastPathComponent))
                    }
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}
public struct ConfigurationSnapshot: Codable, Identifiable, Sendable {
    public let id: String; public let date: Date; public let target: String; public let reason: String
    let roots: [String]; let fingerprints: [String: String]
}
public struct ConfigurationPreview: Sendable {
    public let id: UUID
    public let client: URL
    public let roles: [ConfigurationRole]
    public let fileCount: Int
    public let replacedFiles: Int
    public let bytes: Int64
    public let accountWide: Bool
    let staging: URL
    let roots: [String]
    let originals: [String: String]
    let payloadFingerprint: String
}
/// Full managed-root backups; a durable rollback journal protects multi-root commits.
/// UI serializes calls and prevents writes while WoW is running.
public final class ConfigurationLibrary {
    private let fm = FileManager.default
    public let backupRoot: URL
    private let managed = ["Interface", "WTF", "Fonts"]
    public init(backupRoot: URL? = nil) {
        self.backupRoot = backupRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AzerothManager/ConfigurationBackups")
    }
    public func hasPendingTransaction(in client: URL) throws -> Bool {
        try fm.contentsOfDirectory(at: client, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".azeroth-share-txn-") }
    }
    private func validate(_ client: URL, recovering: Bool = false) throws {
        guard client.isFileURL, client.standardizedFileURL.path == client.resolvingSymlinksInPath().standardizedFileURL.path,
              (try client.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ManagerError("游戏目录无效或包含符号链接") }
        if !recovering {
            guard try !hasPendingTransaction(in: client) else { throw ManagerError("存在未恢复的配置安装，请先在配置分享页恢复中断安装") }
            try FileSafety.validateTarget(client.appendingPathComponent("Interface/AddOns"))
        }
        guard !backupRoot.standardizedFileURL.path.hasPrefix(client.standardizedFileURL.path + "/") else { throw ManagerError("配置备份目录不能位于游戏目录中") }
        for name in managed {
            let path = client.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try FileSafety.checkTree(path) }
        }
    }
    private func fingerprints(_ client: URL, roots: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in roots {
            let path = client.appendingPathComponent(name)
            result[name] = fm.fileExists(atPath: path.path) ? try AddonFingerprint.fingerprint(path) : "absent"
        }
        return result
    }
    public func snapshots(for client: URL) throws -> [ConfigurationSnapshot] {
        guard fm.fileExists(atPath: backupRoot.path) else { return [] }
        return try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("configuration.json")),
                  let value = try? JSONDecoder().decode(ConfigurationSnapshot.self, from: data), value.target == client.standardizedFileURL.path,
                  value.id == dir.lastPathComponent, UUID(uuidString: value.id) != nil else { return nil }
            return value
        }.sorted { $0.date > $1.date }
    }
    @discardableResult public func backup(_ client: URL, reason: String) throws -> ConfigurationSnapshot {
        try validate(client)
        let before = try fingerprints(client, roots: managed)
        let snapshot = ConfigurationSnapshot(id: UUID().uuidString, date: Date(), target: client.standardizedFileURL.path, reason: reason, roots: managed, fingerprints: before)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let pending = backupRoot.appendingPathComponent(".pending-" + snapshot.id)
        do {
            try fm.createDirectory(at: pending, withIntermediateDirectories: false)
            for name in managed where before[name] != "absent" { try fm.copyItem(at: client.appendingPathComponent(name), to: pending.appendingPathComponent(name)) }
            guard try fingerprints(pending, roots: managed) == before, try fingerprints(client, roots: managed) == before else { throw ManagerError("备份期间游戏文件发生变化，请退出游戏后重试") }
            try JSONEncoder().encode(snapshot).write(to: pending.appendingPathComponent("configuration.json"), options: .atomic)
            try fm.moveItem(at: pending, to: backupRoot.appendingPathComponent(snapshot.id))
            return snapshot
        } catch { try? fm.removeItem(at: pending); throw error }
    }
    /// Payload contains already-validated, explicitly scoped Interface/WTF/Fonts files.
    public func preview(payload: URL, client: URL, roles: [ConfigurationRole], accountWide: Bool) throws -> ConfigurationPreview {
        try validate(client); try FileSafety.checkTree(payload)
        let children = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
        guard !children.isEmpty, children.allSatisfy({ managed.contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { throw ManagerError("配置暂存目录包含未允许的安装范围") }
        let known = Set(try ConfigurationFiles.roles(in: client))
        guard Set(roles).isSubset(of: known) else { throw ManagerError("目标角色目录已变化，请重新扫描") }
        let staging = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AzerothConfigPreview-" + UUID().uuidString)
        try fm.copyItem(at: payload, to: staging)
        do {
            let roots = children.map(\.lastPathComponent).sorted()
            var count = 0, replaced = 0; var bytes: Int64 = 0
            guard let enumerator = fm.enumerator(atPath: staging.path) else { throw ManagerError("无法读取配置暂存目录") }
            for case let relative as String in enumerator {
                let file = staging.appendingPathComponent(relative)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    if relative.hasPrefix("WTF/") {
                        let parts = relative.split(separator: "/").map(String.init)
                        guard parts.count >= 4, parts[1] == "Account", roles.contains(where: { $0.account == parts[2] }) else { throw ManagerError("WTF 文件超出所选账号范围") }
                        let roleScoped = roles.contains { relative.hasPrefix($0.relativePath + "/") }
                        let commonScoped = accountWide && (parts.count == 4 || parts[3] == "SavedVariables")
                        guard roleScoped || commonScoped else { throw ManagerError("WTF 文件超出所选角色或公共配置范围") }
                    }
                    count += 1; bytes += Int64(values.fileSize ?? 0)
                    if fm.fileExists(atPath: client.appendingPathComponent(relative).path) { replaced += 1 }
                }
            }
            guard count > 0, count <= 100000, bytes <= 4 * 1024 * 1024 * 1024 else { throw ManagerError("配置文件数量或大小超过限制") }
            return ConfigurationPreview(id: UUID(), client: client, roles: roles, fileCount: count, replacedFiles: replaced, bytes: bytes, accountWide: accountWide, staging: staging, roots: roots, originals: try fingerprints(client, roots: roots), payloadFingerprint: try AddonFingerprint.fingerprint(staging))
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    public func discard(_ preview: ConfigurationPreview) { try? fm.removeItem(at: preview.staging) }
    private func merge(_ source: URL, into target: URL) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destination = target.appendingPathComponent(child.lastPathComponent)
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                if fm.fileExists(atPath: destination.path), (try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { try fm.removeItem(at: destination) }
                try merge(child, into: destination)
            } else {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: child, to: destination)
            }
        }
    }
    private struct Journal: Codable { let id: String; let client: String; let roots: [String]; let originals: [String: String]; let prepared: [String: String]; var committed: Bool }
    private func cleanTransaction(_ directory: URL) throws {
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where child.lastPathComponent != "journal.json" { try fm.removeItem(at: child) }
        let record = directory.appendingPathComponent("journal.json")
        if fm.fileExists(atPath: record.path) { try fm.removeItem(at: record) }
        try fm.removeItem(at: directory)
    }
    /// Restores uncommitted roots after an interrupted process. Never interprets arbitrary journal paths.
    public func recoverInterrupted(in client: URL) throws {
        try validate(client, recovering: true)
        for dir in try fm.contentsOfDirectory(at: client, includingPropertiesForKeys: nil) where dir.lastPathComponent.hasPrefix(".azeroth-share-txn-") {
            if !fm.fileExists(atPath: dir.appendingPathComponent("journal.json").path) {
                let suffix = String(dir.lastPathComponent.dropFirst(".azeroth-share-txn-".count))
                let children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                if UUID(uuidString: suffix) != nil, children.allSatisfy({ $0.lastPathComponent == "old" && ((try? fm.contentsOfDirectory(atPath: $0.path).isEmpty) == true) }) {
                    try FileSafety.checkTree(dir); try fm.removeItem(at: dir); continue
                }
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("journal.json")), let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  UUID(uuidString: journal.id) != nil, dir.lastPathComponent == ".azeroth-share-txn-" + journal.id,
                  journal.client == client.standardizedFileURL.path, !journal.roots.isEmpty, Set(journal.roots).isSubset(of: Set(managed)),
                  Set(journal.originals.keys) == Set(journal.roots), Set(journal.prepared.keys) == Set(journal.roots) else { throw ManagerError("发现无法识别的配置恢复记录，请保留并人工检查") }
            try FileSafety.checkTree(dir)
            if !journal.committed {
                for name in journal.roots.reversed() {
                    let old = dir.appendingPathComponent("old/" + name), live = client.appendingPathComponent(name)
                    if fm.fileExists(atPath: old.path) {
                        guard try AddonFingerprint.fingerprint(old) == journal.originals[name] else { throw ManagerError("回滚原目录已变化，请保留记录并人工恢复") }
                        if fm.fileExists(atPath: live.path) {
                            guard try AddonFingerprint.fingerprint(live) == journal.prepared[name] else { throw ManagerError("安装中断后目录又发生变化，不能自动覆盖，请使用完整备份人工恢复") }
                        }
                        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
                        try fm.moveItem(at: old, to: live)
                    } else if journal.originals[name] == "absent", !fm.fileExists(atPath: dir.appendingPathComponent("next/" + name).path), fm.fileExists(atPath: live.path) {
                        guard try AddonFingerprint.fingerprint(live) == journal.prepared[name] else { throw ManagerError("新增目录在中断后发生变化，不能自动删除") }
                        try fm.removeItem(at: live)
                    }
                }
            }
            try cleanTransaction(dir)
        }
    }
    private func commit(next: URL, client: URL, roots: [String], original: [String: String], checkpoint: ((Int) throws -> Void)?) throws {
        let id = UUID().uuidString
        // Directory name is tied to its journal ID; the temporary tree remains on the game's volume.
        let transaction = client.appendingPathComponent(".azeroth-share-txn-" + id)
        try fm.createDirectory(at: transaction.appendingPathComponent("old"), withIntermediateDirectories: true)
        do {
            var journal = Journal(id: id, client: client.standardizedFileURL.path, roots: roots, originals: original, prepared: try fingerprints(next, roots: roots), committed: false)
            let record = transaction.appendingPathComponent("journal.json")
            try JSONEncoder().encode(journal).write(to: record, options: .atomic)
            try fm.moveItem(at: next, to: transaction.appendingPathComponent("next"))
            guard try fingerprints(client, roots: roots) == original else { throw ManagerError("预览后游戏文件发生变化，请重新预览") }
            for (index, name) in roots.enumerated() {
                let live = client.appendingPathComponent(name)
                if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: transaction.appendingPathComponent("old/" + name)) }
                let prepared = transaction.appendingPathComponent("next/" + name)
                if fm.fileExists(atPath: prepared.path) { try fm.moveItem(at: prepared, to: live) }
                try checkpoint?(index)
            }
            journal.committed = true; try JSONEncoder().encode(journal).write(to: record, options: .atomic)
            try? cleanTransaction(transaction)
        } catch {
            if !fm.fileExists(atPath: transaction.appendingPathComponent("journal.json").path) {
                try? fm.removeItem(at: transaction)
                throw error
            }
            // Leave a durable journal if recovery itself fails; do not silently discard originals.
            do { try recoverInterrupted(in: client) } catch { throw ManagerError("配置提交中断，自动回滚尚未完成；恢复记录与完整备份已保留，请先恢复后再继续") }
            throw error
        }
    }
    @discardableResult public func install(_ preview: ConfigurationPreview, checkpoint: ((Int) throws -> Void)? = nil) throws -> ConfigurationSnapshot {
        try validate(preview.client)
        guard try fingerprints(preview.client, roots: preview.roots) == preview.originals,
              try AddonFingerprint.fingerprint(preview.staging) == preview.payloadFingerprint else { throw ManagerError("预览后文件已变化，请重新预览") }
        let snapshot = try backup(preview.client, reason: "配置分享安装前")
        let next = preview.client.appendingPathComponent(".azeroth-config-stage-" + UUID().uuidString)
        try fm.createDirectory(at: next, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: next) }
        for name in preview.roots {
            let live = preview.client.appendingPathComponent(name), destination = next.appendingPathComponent(name)
            if fm.fileExists(atPath: live.path) { try fm.copyItem(at: live, to: destination) }
            if name == "Interface" {
                let addonPayload = preview.staging.appendingPathComponent("Interface/AddOns")
                if fm.fileExists(atPath: addonPayload.path) {
                    let folders = try fm.contentsOfDirectory(at: addonPayload, includingPropertiesForKeys: nil)
                    let addonTarget = destination.appendingPathComponent("AddOns")
                    let replacing = Set(folders.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() })
                    for old in (try? fm.contentsOfDirectory(at: addonTarget, includingPropertiesForKeys: nil)) ?? [] where replacing.contains(old.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()) { try fm.removeItem(at: old) }
                    if fm.fileExists(atPath: addonTarget.path) {
                        try DDTracking.write(DDTracking.removing(folders.map(\.lastPathComponent), from: DDTracking.receipts(in: addonTarget)), to: addonTarget)
                    }
                }
            }
            try merge(preview.staging.appendingPathComponent(name), into: destination)
        }
        try commit(next: next, client: preview.client, roots: preview.roots, original: preview.originals, checkpoint: checkpoint)
        return snapshot
    }
    public func restore(_ snapshot: ConfigurationSnapshot, client: URL) throws {
        try validate(client)
        guard UUID(uuidString: snapshot.id) != nil, snapshot.target == client.standardizedFileURL.path,
              snapshot.roots == managed else { throw ManagerError("此完整备份不属于当前游戏目录") }
        let source = backupRoot.appendingPathComponent(snapshot.id)
        try FileSafety.checkTree(source)
        guard try fingerprints(source, roots: managed) == snapshot.fingerprints else { throw ManagerError("完整备份内容已变化，不能恢复") }
        let current = try fingerprints(client, roots: managed)
        _ = try backup(client, reason: "恢复完整配置备份前")
        let next = client.appendingPathComponent(".azeroth-config-stage-" + UUID().uuidString)
        try fm.createDirectory(at: next, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: next) }
        for name in managed where snapshot.fingerprints[name] != "absent" { try fm.copyItem(at: source.appendingPathComponent(name), to: next.appendingPathComponent(name)) }
        try commit(next: next, client: client, roots: managed, original: current, checkpoint: nil)
    }
}
