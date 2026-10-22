import Foundation

public struct InstalledUpdate: Sendable {
    public let label: String
    public let latest: String?
    public let externalURL: URL?
    public let ddSelection: DDSelection?
    /// 检查时的本地内容指纹，安装前再次核对。
    public let expected: [String: String]
    public let isCurrent: Bool
    public var sortPriority: Int { ddSelection != nil ? 0 : isCurrent ? 2 : 1 }
    public init(label: String, latest: String? = nil, expected: [String: String] = [:], externalURL: URL? = nil, ddSelection: DDSelection? = nil, isCurrent: Bool = false) {
        self.label = label; self.latest = latest; self.expected = expected
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
