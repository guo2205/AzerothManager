import Foundation
import CryptoKit

public enum DDSort: Int, CaseIterable, Identifiable, Sendable {
    case weekly = 4, monthly = 3, total = 1
    public var id: Int { rawValue }
    public var rawTitle: String { switch self { case .weekly: return "周热门"; case .monthly: return "月热门"; case .total: return "总下载量" } }
    public var downloadTitle: String { switch self { case .weekly: return "周下载"; case .monthly: return "月下载"; case .total: return "总下载" } }
}

public struct DDAddon: Decodable, Identifiable, Sendable {
    public let sn: String
    public let name: String
    public let description: String?
    public let game_types: [Int]?
    public let latest_version: Version?
    public let week_download: Int?
    public let month_download: Int?
    public let total_download: Int?
    public func downloads(for sort: DDSort) -> Int? {
        switch sort { case .weekly: return week_download; case .monthly: return month_download; case .total: return total_download }
    }
    public var id: String { sn }
    public struct Version: Codable, Sendable {
        public let sn: String
        public let version: String
        public let folders: [String]?
        public let release_type: Int?
        public let file_path: String?
        public let size: Int?
    }
    public func website(gameType: Int) -> URL { DDClient.website(sn: sn, gameType: gameType) }
}
public struct DDPage: Decodable, Sendable {
    public let code: Int
    public let msg: String?
    public let count: Int?
    public let result: [DDAddon]?
}
public struct DDScanPackage: Decodable, Sendable {
    public let sn: String
    public let name: String
    public let folders: [String]
    public let detail_sn: String?
    public let local_version: String?
    public let match_degree: String?
    public let local_status: Int?
    public let latest_version: DDAddon.Version?
    public let need_buy: Bool?
    public let need_anchor_vip: Bool?
}
public struct DDScanResult: Decodable, Sendable { public let installed: [DDScanPackage]; public let unknown: [String] }
private struct DDResponse<T: Decodable>: Decodable { let code: Int; let msg: String?; let result: T? }
public struct DDSelection: Sendable {
    public let package: DDScanPackage
    public let flavor: Flavor
    public let version: DDAddon.Version
    init(package: DDScanPackage, flavor: Flavor) throws {
        guard let version = package.latest_version else { throw ManagerError("DD 没有返回版本信息") }
        self.package = package; self.flavor = flavor; self.version = version
    }
}
final class DDRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowsCDN(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "uires.w.163.com" && url.port == nil && url.user == nil && url.password == nil && url.path.hasPrefix("/file/") && url.path.lowercased().hasSuffix(".zip") && url.query == nil && url.fragment == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard task.originalRequest?.url.map(Self.allowsCDN) == true, request.url.map(Self.allowsCDN) == true else { completionHandler(nil); return }
        var clean = request; clean.setValue(nil, forHTTPHeaderField: "Cookie"); clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "x-w163-token")
        completionHandler(clean)
    }
}
/// Implements the official public TOC-MD5 scan protocol. No credentials or Lua source are uploaded.
public struct DDClient: Sendable {
    public static let maxArchiveBytes = 256 * 1024 * 1024
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 300
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: DDRedirectPolicy(), delegateQueue: nil)
    }
    public static func gameType(_ flavor: Flavor) -> Int { flavor == .time ? 2 : 10001 }
    public static func website(sn: String, gameType: Int) -> URL {
        var url = URLComponents(string: "https://dd.163.com/wow/plugin")!
        url.queryItems = [URLQueryItem(name: "gametype", value: String(gameType)), URLQueryItem(name: "sn", value: sn)]
        return url.url!
    }
    private func request(_ path: String, body: [String: Any]) throws -> URLRequest {
        // These fixed parameters are emitted by the official website, including anonymous scans.
        var r = URLRequest(url: URL(string: "https://uiapi.w.163.com/" + path + "?ef=0&uf=0&ts=0&ab=0")!)
        r.httpMethod = "POST"; r.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }
    private func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 16 * 1024 * 1024 else { throw ManagerError("DD 查询失败，请稍后重试") }
        return data
    }
    public func search(_ query: String, gameType: Int, page: Int = 1, sort: DDSort = .weekly) async throws -> DDPage {
        let r = try request("addon/addon_list", body: ["game_type": gameType, "origin": "all", "name": query, "page": max(1, page), "size": 20, "sort_type": sort.rawValue])
        let result = try JSONDecoder().decode(DDPage.self, from: await data(r))
        guard result.code == 0, result.result != nil else { throw ManagerError(result.msg ?? "DD 接口没有返回插件列表") }
        return result
    }
    public func scan(tocs: [String: String], flavor: Flavor, strategy: [String: Int] = [:]) async throws -> DDScanResult {
        guard tocs.count <= 20000 else { throw ManagerError("DD 扫描的 TOC 文件过多") }
        let r = try request("addon/scan", body: ["game_type": Self.gameType(flavor), "user_tocs": tocs, "sn_strategy": strategy])
        let result = try JSONDecoder().decode(DDResponse<DDScanResult>.self, from: await data(r))
        guard result.code == 0, let result = result.result else { throw ManagerError(result.msg ?? "DD 扫描失败") }
        return result
    }
    static func validFolder(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") }
    static func tocs(in folders: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        for folder in folders {
            try Task.checkCancellation(); guard validFolder(folder.lastPathComponent) else { throw ManagerError("插件目录名称异常") }
            try FileSafety.checkTree(folder)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) where file.pathExtension.lowercased() == "toc" {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else { throw ManagerError("插件 TOC 文件过大") }
                result[folder.lastPathComponent + "/" + file.lastPathComponent] = Insecure.MD5.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    public func check(target: URL, addons: [Addon], flavor: Flavor) async throws -> [String: InstalledUpdate] {
        let local = try await Task.detached { () -> ([String: String], [String: String], [DDReceipt]) in
            let folders = addons.map { target.appendingPathComponent($0.folder) }
            let tocs = try Self.tocs(in: folders)
            var fingerprints: [String: String] = [:]
            for folder in folders { try Task.checkCancellation(); fingerprints[folder.lastPathComponent] = try AddonFingerprint.fingerprint(folder) }
            return (tocs, fingerprints, try DDTracking.receipts(in: target))
        }.value
        let scanned = try await scan(tocs: local.0, flavor: flavor)
        let strategies = Dictionary(scanned.installed.map { ($0.sn, 1) }, uniquingKeysWith: { a, _ in a })
        // Explicitly request stable releases for all projects identified in the first scan.
        let stable = strategies.isEmpty ? scanned : try await scan(tocs: local.0, flavor: flavor, strategy: strategies)
        var result: [String: InstalledUpdate] = [:]
        for addon in addons {
            let matches = stable.installed.filter { $0.folders.contains(addon.folder) }
            guard matches.count == 1, let package = matches.first, let latest = package.latest_version else {
                result[addon.folder] = InstalledUpdate(label: matches.count > 1 ? "DD 匹配冲突" : "DD 未精确匹配"); continue
            }
            let valid = !package.folders.isEmpty && package.folders.allSatisfy(Self.validFolder)
            let complete = package.match_degree == "all" && package.local_status == 0 && valid
            let receipt = local.2.first { $0.projectID == package.sn && $0.flavor == flavor && $0.folders.contains(addon.folder) }
            let unchanged = receipt.map { r in r.folders.allSatisfy { local.1[$0] == r.fingerprints[$0] } } ?? true
            let label: String
            if !complete { label = "DD 部分匹配或冲突" }
            else if !unchanged { label = "本地有修改 · DD" }
            else if package.detail_sn == latest.sn { label = "已是最新 · DD（TOC）" }
            else { label = "DD 版本可更新" }
            let downloadable = complete && latest.release_type == 1 && latest.size.map { $0 > 0 && $0 <= Self.maxArchiveBytes } == true && latest.file_path.flatMap(URL.init(string:)).map(DDRedirectPolicy.allowsCDN) == true && package.need_buy != true && package.need_anchor_vip != true
            result[addon.folder] = InstalledUpdate(label: label, latest: latest.version, expected: local.1, externalURL: Self.website(sn: package.sn, gameType: Self.gameType(flavor)), ddSelection: downloadable && (package.detail_sn != latest.sn || !unchanged) ? try DDSelection(package: package, flavor: flavor) : nil, isCurrent: complete && unchanged && package.detail_sn == latest.sn)
        }
        return result
    }
    /// Re-scan immediately before download to refresh the URL and project/version identity.
    public func refresh(_ selection: DDSelection, target: URL, expected: [String: String]) async throws -> DDSelection {
        let tocs = try await Task.detached { () -> [String: String] in
            try InstalledUpdates.verify(expected, target: target)
            return try Self.tocs(in: selection.package.folders.map { target.appendingPathComponent($0) })
        }.value
        let result = try await scan(tocs: tocs, flavor: selection.flavor, strategy: [selection.package.sn: 1])
        guard let current = result.installed.first(where: { $0.sn == selection.package.sn }), current.match_degree == "all", current.local_status == 0, let version = current.latest_version, version.release_type == 1,
              current.need_buy != true, current.need_anchor_vip != true else { throw ManagerError("DD 无法重新确认插件，请重新检查更新") }
        guard version.sn == selection.version.sn else { throw ManagerError("DD 最新版本发生变化，请重新检查更新") }
        return try DDSelection(package: current, flavor: selection.flavor)
    }
    public func download(_ selection: DDSelection) async throws -> URL {
        let version = selection.version
        guard selection.package.match_degree == "all", selection.package.local_status == 0, selection.package.need_buy != true, selection.package.need_anchor_vip != true, version.release_type == 1,
              let size = version.size, size > 0, size <= Self.maxArchiveBytes, let text = version.file_path, let url = URL(string: text), DDRedirectPolicy.allowsCDN(url) else { throw ManagerError("DD 未提供可用的正式版下载地址") }
        let (stream, response) = try await session.bytes(for: URLRequest(url: url))
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url.map(DDRedirectPolicy.allowsCDN) == true,
              response.expectedContentLength == -1 || response.expectedContentLength == Int64(size) else { throw ManagerError("DD 下载响应或声明大小不符") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AzerothDD-" + UUID().uuidString + ".zip")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ManagerError("无法创建下载临时文件") }
        let handle = try FileHandle(forWritingTo: file)
        do {
            var count = 0, chunk = Data()
            for try await byte in stream {
                try Task.checkCancellation(); count += 1; guard count <= size else { throw ManagerError("DD 下载超出声明大小") }
                chunk.append(byte)
                if chunk.count == 65536 { try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: chunk); try handle.close()
            guard count == size else { throw ManagerError("DD 下载不完整") }
            return file
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
    }
    /// Confirm the archive is precisely the selected release using DD's TOC fingerprints.
    public func verify(_ preview: InstallPreview, selection: DDSelection) async throws {
        let tocs = try await Task.detached { try Self.tocs(in: preview.folders) }.value
        let result = try await scan(tocs: tocs, flavor: selection.flavor, strategy: [selection.package.sn: 1])
        let names = Set(preview.folders.map(\.lastPathComponent))
        guard let match = result.installed.first(where: { $0.sn == selection.package.sn }), match.detail_sn == selection.version.sn,
              match.match_degree == "all", match.local_status == 0, Set(match.folders) == names else { throw ManagerError("DD 下载包的版本或目录与所选插件不匹配") }
    }
}

public struct DDReceipt: Codable, Sendable {
    public let projectID: String
    public let fileID: String
    public let version: String
    public let flavor: Flavor
    public let folders: [String]
    public let fingerprints: [String: String]
    init(selection: DDSelection, folders: [URL]) throws {
        projectID = selection.package.sn; fileID = selection.version.sn; version = selection.version.version; flavor = selection.flavor
        self.folders = folders.map(\.lastPathComponent)
        fingerprints = try Dictionary(uniqueKeysWithValues: folders.map { ($0.lastPathComponent, try AddonFingerprint.fingerprint($0)) })
    }
}
public enum DDTracking {
    static let filename = ".azeroth-dd.json"
    public static func receipts(in target: URL) throws -> [DDReceipt] {
        let file = target.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw ManagerError("DD 来源记录路径异常或过大") }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode([DDReceipt].self, from: data)
    }
    static func write(_ records: [DDReceipt], to target: URL) throws { try JSONEncoder().encode(records).write(to: target.appendingPathComponent(filename), options: .atomic) }
    static func removing(_ folders: [String], from records: [DDReceipt]) -> [DDReceipt] {
        let names = Set(folders.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        return records.filter { !$0.folders.contains { names.contains($0.precomposedStringWithCanonicalMapping.lowercased()) } }
    }
}
