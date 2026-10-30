import Foundation

public struct ManagerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Flavor: String, CaseIterable, Identifiable, Codable, Sendable {
    case time = "国服时光服", retail = "正式服"
    public var id: String { rawValue }
}
public struct Addon: Identifiable, Hashable {
    public var id: String { folder }
    public let folder: String
    public let title: String
    public let version: String
    public let author: String
    public let notes: String
    public let interface: String
    public let dependencies: String
    public let tocNames: String
}
public enum TOC {
    public static func parse(_ data: Data) throws -> [String: String] {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) else { throw ManagerError("TOC 编码无法识别") }
        var result: [String: String] = [:]
        for line in raw.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) {
            guard line.hasPrefix("##"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            result[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\|c[0-9a-fA-F]{8}|\\|r", with: "", options: .regularExpression)
    }
}
import CoreFoundation

public enum AddonScanner {
    public static func scan(_ directory: URL, flavor: Flavor) throws -> [Addon] {
        try FileSafety.checkTree(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let name = folder.lastPathComponent
            let tocs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "toc" && ($0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() || $0.lastPathComponent.lowercased().hasPrefix(name.lowercased() + "_") || $0.lastPathComponent.lowercased().hasPrefix(name.lowercased() + "-")) }
            guard !tocs.isEmpty else { return nil }
            let ordered = tocs.sorted { a, b in
                func rank(_ u: URL) -> Int {
                    let stem = u.deletingPathExtension().lastPathComponent.lowercased()
                    if stem == name.lowercased() { return 1 }
                    if flavor == .retail && (stem.hasSuffix("_mainline") || stem.hasSuffix("-mainline")) { return 0 }
                    if flavor == .time && (stem.hasSuffix("_titan") || stem.hasSuffix("-titan")) { return 0 }
                    if flavor == .time && (stem.hasSuffix("_wrath") || stem.hasSuffix("-wrath")) { return 2 }
                    if flavor == .time && (stem.hasSuffix("_classic") || stem.hasSuffix("-classic")) { return 3 }
                    if flavor == .time && (stem.hasSuffix("_vanilla") || stem.hasSuffix("-vanilla")) { return 4 }
                    return flavor == .time ? 5 : 2
                }
                return rank(a) == rank(b) ? a.lastPathComponent < b.lastPathComponent : rank(a) < rank(b)
            }
            let meta = try TOC.parse(Data(contentsOf: ordered[0]))
            return Addon(folder: name, title: TOC.clean(meta["title-zhcn"] ?? meta["title"] ?? name), version: meta["version"] ?? "未知", author: meta["author"] ?? "未知", notes: TOC.clean(meta["notes-zhcn"] ?? meta["notes"] ?? ""), interface: meta["interface"] ?? "未声明", dependencies: meta["dependencies"] ?? meta["requireddeps"] ?? "无", tocNames: ordered.map(\.lastPathComponent).joined(separator: "、"))
        }
    }
}

public enum FileSafety {
    public static func checkTree(_ url: URL) throws {
        let fm = FileManager.default
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw ManagerError("不支持符号链接：\(url.lastPathComponent)") }
        guard values.isDirectory == true || values.isRegularFile == true else { throw ManagerError("不支持特殊文件") }
        if values.isDirectory == true {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try checkTree(child) }
        }
    }
    public static func validateTarget(_ url: URL) throws {
        guard url.lastPathComponent.lowercased() == "addons", url.deletingLastPathComponent().lastPathComponent.lowercased() == "interface" else { throw ManagerError("请选择 Interface/AddOns 文件夹") }
        // Resolve every existing ancestor to reject redirects outside the selected location.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw ManagerError("插件路径含符号链接，请选择真实目录") }
        try checkTree(url)
    }
    public static func candidates(_ root: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let bases = [root] + ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        for base in bases {
            let target = base.appendingPathComponent("Interface/AddOns", isDirectory: true)
            if (try? validateTarget(target)) != nil { result.append(target) }
        }
        if (try? validateTarget(root)) != nil { result.insert(root, at: 0) }
        return Array(Set(result)).sorted { a, b in
            let ar = a.path.contains("_retail_") ? 1 : 0, br = b.path.contains("_retail_") ? 1 : 0
            return ar == br ? a.path < b.path : ar < br
        }
    }
}
