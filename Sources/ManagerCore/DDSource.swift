import Foundation

public struct DDAddon: Decodable, Identifiable, Sendable {
    public let sn: String
    public let name: String
    public let description: String?
    public let game_types: [Int]?
    public let latest_version: Version?
    public var id: String { sn }
    public struct Version: Decodable, Sendable {
        public let sn: String
        public let version: String
        public let folders: [String]?
        public let release_type: Int?
    }
    public func website(gameType: Int) -> URL {
        var url = URLComponents(string: "https://dd.163.com/wow/plugin")!
        url.queryItems = [URLQueryItem(name: "gametype", value: String(gameType)), URLQueryItem(name: "sn", value: sn)]
        return url.url!
    }
}
public struct DDPage: Decodable, Sendable {
    public let code: Int
    public let msg: String?
    public let count: Int?
    public let result: [DDAddon]?
}
private struct DDLocalRecord: Decodable {
    let sn: String
    let name: String
    let folders: [String]
}
private final class DDRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
/// Uses the same public catalogue as the DD website. No login tokens or cached download URLs.
public struct DDClient: Sendable {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 25
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: DDRedirectPolicy(), delegateQueue: nil)
    }
    public static func gameType(_ flavor: Flavor) -> Int { flavor == .time ? 2 : 10001 }
    public func search(_ query: String, gameType: Int, page: Int = 1) async throws -> DDPage {
        var request = URLRequest(url: URL(string: "https://uiapi.w.163.com/addon/addon_list")!)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["game_type": gameType, "origin": "all", "name": query, "page": max(1, page), "size": 20])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 16 * 1024 * 1024 else { throw ManagerError("DD 查询失败，请稍后重试") }
        let result = try JSONDecoder().decode(DDPage.self, from: data)
        guard result.code == 0, result.result != nil else { throw ManagerError(result.msg ?? "DD 接口没有返回插件列表") }
        return result
    }
    public static func status(local: String, latest: String) -> String {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v(?=[0-9])", with: "", options: [.regularExpression, .caseInsensitive]) }
        return normalized(local) == normalized(latest) ? "版本号一致 · DD" : "版本不同 · DD"
    }
    public func check(target: URL, addons: [Addon], flavor: Flavor) async throws -> [String: InstalledUpdate] {
        let file = target.appendingPathComponent("addon_strategy.txt")
        let records: [DDLocalRecord]
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw ManagerError("DD 本地清单过大或路径异常") }
            do { records = try JSONDecoder().decode([DDLocalRecord].self, from: Data(contentsOf: file)) }
            catch { throw ManagerError("DD 本地清单无法读取，请在 DD 中重新扫描插件") }
        } else { records = [] }
        let type = Self.gameType(flavor)
        var result: [String: InstalledUpdate] = [:], cache: [String: [DDAddon]] = [:]
        for addon in addons {
            try Task.checkCancellation()
            let known = records.filter { $0.folders.contains(addon.folder) }
            guard known.count <= 1 else { result[addon.folder] = InstalledUpdate(label: "DD 清单存在多个对应插件"); continue }
            let query = known.first?.name ?? addon.folder
            do {
                if cache[query] == nil { cache[query] = try await search(query, gameType: type).result ?? [] }
                let matches = (cache[query] ?? []).filter { item in
                    guard item.game_types?.contains(type) == true, let version = item.latest_version, version.release_type == 1 else { return false }
                    if let record = known.first { return item.sn == record.sn }
                    return version.folders?.contains(addon.folder) == true
                }
                guard matches.count == 1, let match = matches.first, let latest = match.latest_version else {
                    result[addon.folder] = InstalledUpdate(label: matches.isEmpty ? "DD 未精确匹配" : "DD 存在多个匹配"); continue
                }
                result[addon.folder] = InstalledUpdate(label: Self.status(local: addon.version, latest: latest.version), latest: latest.version, externalURL: match.website(gameType: type))
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                result[addon.folder] = InstalledUpdate(label: "DD 检查失败：" + error.localizedDescription)
            }
        }
        return result
    }
}
