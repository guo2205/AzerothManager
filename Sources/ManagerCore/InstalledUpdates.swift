import Foundation

public struct CFFingerprintMatch: Decodable, Sendable {
    public let id: Int
    public let file: CFFile
}
struct CFFingerprintResults: Decodable { let exactMatches: [CFFingerprintMatch] }

/// CF's whitespace-normalized MurmurHash2 protocol, seed 1. This identifies code;
/// SHA-256 folder fingerprints separately detect *all* local changes before installation.
public enum CFFingerprint {
    public static func hash(_ data: Data) -> UInt32 {
        let bytes = data.filter { ![9, 10, 13, 32].contains($0) }
        let multiplier: UInt32 = 0x5bd1e995
        var h = UInt32(truncatingIfNeeded: bytes.count) ^ 1, word: UInt32 = 0, shift: UInt32 = 0
        for byte in bytes {
            word |= UInt32(byte) << shift; shift += 8
            if shift == 32 {
                word = word &* multiplier; word ^= word >> 24; word = word &* multiplier
                h = (h &* multiplier) ^ word; word = 0; shift = 0
            }
        }
        if shift > 0 { h = (h ^ word) &* multiplier }
        h ^= h >> 13; h = h &* multiplier; return h ^ (h >> 15)
    }
    public static func folder(_ folder: URL) throws -> UInt32 {
        try FileSafety.checkTree(folder)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder.path) else { throw ManagerError("无法读取插件指纹") }
        let names = enumerator.compactMap { $0 as? String }
        let lookup = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let rootName = folder.lastPathComponent.lowercased()
        var queue = names.filter {
            !$0.contains("/") && $0.lowercased().hasSuffix(".toc") && ($0.lowercased() == rootName + ".toc" || $0.lowercased().hasPrefix(rootName + "_") || $0.lowercased().hasPrefix(rootName + "-"))
        }
        if let binding = lookup["bindings.xml"] { queue.append(binding) }
        var visited = Set<String>(), hashes: [UInt32] = [], bytes = 0
        while let relative = queue.popLast() {
            try Task.checkCancellation()
            guard visited.insert(relative).inserted else { continue }
            let url = folder.appendingPathComponent(relative)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            bytes += size
            guard size <= 32 * 1024 * 1024, bytes <= 128 * 1024 * 1024 else { throw ManagerError("插件指纹计算超过大小限制") }
            let data = try Data(contentsOf: url); hashes.append(hash(data))
            let ext = url.pathExtension.lowercased()
            guard ext == "toc" || ext == "xml" else { continue }
            var text = String(decoding: data, as: UTF8.self)
            var paths: [String] = []
            if ext == "toc" {
                paths = text.components(separatedBy: .newlines).map { $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { ["lua", "xml"].contains(($0 as NSString).pathExtension.lowercased()) }
            } else {
                text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
                let regex = try NSRegularExpression(pattern: "(?i)<(?:Include|Script)\\s+[^>]*?file\\s*=\\s*[\"']([^\"']+)[\"']")
                paths = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            }
            for path in paths {
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                guard !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains(".."), !normalized.contains(":") else { continue }
                let parent = (relative as NSString).deletingLastPathComponent
                let candidate = parent.isEmpty ? normalized : parent + "/" + normalized
                if let found = lookup[candidate.lowercased()] { queue.append(found) }
            }
        }
        guard !hashes.isEmpty else { throw ManagerError("没有可识别的插件代码") }
        return hash(Data(hashes.sorted().map(String.init).joined().utf8))
    }
}

public struct InstalledUpdate: Sendable {
    public let label: String
    public let latest: String?
    public let externalURL: URL?
    public let ddSelection: DDSelection?
    public let sourceID: Int?
    public let selection: CFSelection?
    /// Snapshots of every existing folder in the package; rechecked immediately before mutation.
    public let expected: [String: String]
    public init(label: String, latest: String? = nil, sourceID: Int? = nil, selection: CFSelection? = nil, expected: [String: String] = [:], externalURL: URL? = nil, ddSelection: DDSelection? = nil) {
        self.ddSelection = ddSelection; self.externalURL = externalURL; self.label = label; self.latest = latest; self.sourceID = sourceID; self.selection = selection; self.expected = expected
    }
}

public enum InstalledUpdates {
    public static func defaultType(_ types: [CFVersionType], flavor: Flavor) -> Int? {
        let name = flavor == .time ? "WoW Wrath Titan Reforged" : "WoW Retail"
        return types.first { $0.gameId == 1 && $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
    public static func decide(installed: CFFile?, latest: CFFile, unchanged: Bool) -> String {
        guard let installed else { return "本地版本未识别" }
        if installed.id == latest.id { return unchanged ? "已是最新" : "本地有修改" }
        guard let oldDate = installed.date, let newDate = latest.date else { return "版本日期无法比较" }
        return newDate > oldDate ? "有新版本" : "本地版本较新"
    }
    public static func verify(_ expected: [String: String], target: URL) throws {
        for (name, fingerprint) in expected {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  try SourceTracking.fingerprint(target.appendingPathComponent(name)) == fingerprint else { throw ManagerError("本地插件在检查后发生变化，请重新检查更新") }
        }
    }
    public static func check(target: URL, addons: [Addon], receipts: [CFReceipt], client: CurseForgeClient, typeID: Int, flavor: Flavor) async throws -> [String: InstalledUpdate] {
        // Local hashing is off the UI executor. Only numeric code fingerprints reach the API.
        let local = try await Task.detached { () -> ([String: UInt32], [String: Int], [String: String]) in
            var hashes: [String: UInt32] = [:], ids: [String: Int] = [:], content: [String: String] = [:]
            for addon in addons {
                try Task.checkCancellation()
                let folder = target.appendingPathComponent(addon.folder)
                content[addon.folder] = try SourceTracking.fingerprint(folder)
                hashes[addon.folder] = try? CFFingerprint.folder(folder)
                let tocs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "toc" }
                let projectIDs = Set(tocs.compactMap { url -> Int? in
                    guard let data = try? Data(contentsOf: url), let metadata = try? TOC.parse(data), let text = metadata["x-curse-project-id"], let id = Int(text), id > 0 else { return nil }
                    return id
                })
                if projectIDs.count == 1 { ids[addon.folder] = projectIDs.first }
            }
            return (hashes, ids, content)
        }.value
        try Task.checkCancellation()
        var matches: [CFFingerprintMatch] = []
        let hashes = Array(Set(local.0.values)).sorted()
        for start in stride(from: 0, to: hashes.count, by: 50) {
            matches += try await client.matches(Array(hashes[start..<min(start + 50, hashes.count)]))
        }
        var result: [String: InstalledUpdate] = [:], fileCache: [Int: [CFFile]] = [:], modCache: [Int: CFMod] = [:]
        for addon in addons {
            try Task.checkCancellation()
            let receipt = receipts.first { $0.flavor == flavor && $0.typeID == typeID && $0.folders.contains(addon.folder) }
            let exact = matches.filter { match in
                match.file.modules?.contains { $0.name == addon.folder && $0.fingerprint == local.0[addon.folder] } == true
            }
            let exactIDs = Set(exact.map { $0.file.modId })
            let inferredID = exactIDs.count == 1 ? exact.first?.file.modId : nil
            guard let modID = receipt?.modID ?? inferredID ?? local.1[addon.folder] else {
                result[addon.folder] = InstalledUpdate(label: "未识别来源"); continue
            }
            if let declaredID = local.1[addon.folder], declaredID != modID {
                result[addon.folder] = InstalledUpdate(label: "来源记录与本地声明冲突"); continue
            }
            if let inferredID, inferredID != modID {
                result[addon.folder] = InstalledUpdate(label: "来源记录与代码指纹冲突"); continue
            }
            do {
                if modCache[modID] == nil { modCache[modID] = try await client.mod(modID) }
                if fileCache[modID] == nil { fileCache[modID] = try await client.files(modID: modID, typeID: typeID, version: "") }
                guard let mod = modCache[modID], let latest = fileCache[modID]?.first else { result[addon.folder] = InstalledUpdate(label: "无适配版本"); continue }
                guard latest.modules?.contains(where: { $0.name == addon.folder }) == true else {
                    result[addon.folder] = InstalledUpdate(label: "来源目录不匹配"); continue
                }
                let installed = exact.filter { $0.file.modId == modID }.map(\.file).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.first
                let receiptUnchanged = receipt.map { r in r.folders.allSatisfy { local.2[$0] == r.fingerprints[$0] } } ?? true
                let label: String
                if let receipt {
                    if receipt.fileID == latest.id { label = receiptUnchanged ? "已是最新" : "本地有修改" }
                    else if let old = CFReceipt.parseDate(receipt.fileDate), let new = latest.date { label = new > old ? "有新版本" : "本地版本较新" }
                    else { label = "版本日期无法比较" }
                } else { label = decide(installed: installed, latest: latest, unchanged: true) }
                let canUpdate = mod.allowModDistribution != false && ["有新版本", "本地版本未识别", "本地有修改"].contains(label)
                let names = Set((latest.modules ?? []).map(\.name) + (receipt?.folders ?? []) + [addon.folder])
                let expected = local.2.filter { names.contains($0.key) }
                result[addon.folder] = InstalledUpdate(label: mod.allowModDistribution == false ? "作者禁止分发" : label, latest: latest.displayName, sourceID: modID, selection: canUpdate ? CFSelection(mod: mod, file: latest, typeID: typeID, version: "", flavor: flavor) : nil, expected: expected)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                result[addon.folder] = InstalledUpdate(label: "检查失败：" + error.localizedDescription)
            }
        }
        return result
    }
}
