import Foundation
import CryptoKit
import Security

/// Credentials are stored only in the login keychain, never in preferences or source receipts.
public struct CurseForgeKeyStore {
    private let service: String
    public init(service: String = "local.azeroth.manager.curseforge") { self.service = service }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }
    public func load() throws -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw ManagerError("无法读取钥匙串密钥，请检查钥匙串访问权限") }
        return key
    }
    public func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 512, !key.contains("\n"), !key.contains("\r") else { throw ManagerError("API Key 格式无效") }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ManagerError("无法将密钥保存到钥匙串") }
        } else if status != errSecSuccess { throw ManagerError("无法更新钥匙串密钥") }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagerError("无法移除钥匙串密钥") }
    }
}

public struct CFVersionType: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let gameId: Int
    public let name: String
}
public struct CFMod: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let gameId: Int
    public let name: String
    public let summary: String
    public let allowModDistribution: Bool?
    public let links: Links
    public struct Links: Decodable, Hashable, Sendable { public let websiteUrl: URL }
    public var safeWebsite: URL? {
        let url = links.websiteUrl
        guard url.scheme == "https", ["www.curseforge.com", "curseforge.com"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }
}
public struct CFFile: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let gameId: Int
    public let modId: Int
    public let isAvailable: Bool
    public let displayName: String
    public let fileName: String
    public let releaseType: Int
    public let fileDate: String
    public let fileLength: Int
    public let gameVersions: [String]
    public let sortableGameVersions: [Version]
    public let hashes: [Hash]
    public let dependencies: [Dependency]
    public struct Version: Decodable, Hashable, Sendable { public let gameVersionTypeId: Int? }
    public struct Hash: Decodable, Hashable, Sendable { public let value: String; public let algo: Int }
    public struct Dependency: Decodable, Hashable, Sendable { public let modId: Int; public let relationType: Int }
    public var date: Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: fileDate) ?? ISO8601DateFormatter().date(from: fileDate)
    }
    public func matches(typeID: Int, version: String) -> Bool {
        gameId == 1 && isAvailable && releaseType == 1 && fileName.lowercased().hasSuffix(".zip") && fileLength > 0 && fileLength <= GitHubClient.maxArchiveBytes && sortableGameVersions.contains { $0.gameVersionTypeId == typeID } && (version.isEmpty || gameVersions.contains(version))
    }
}
public struct CFSearchPage: Decodable, Sendable {
    public let data: [CFMod]
    public let pagination: Pagination
    public struct Pagination: Decodable, Sendable { public let index: Int; public let pageSize: Int; public let resultCount: Int; public let totalCount: Int }
    public var hasNext: Bool { pagination.index + pagination.resultCount < pagination.totalCount && pagination.resultCount > 0 }
}
private struct CFResponse<Value: Decodable>: Decodable { let data: Value }

final class CFRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowsCDN(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil else { return false }
        return (host == "forgecdn.net" || host.hasSuffix(".forgecdn.net")) && url.path.hasPrefix("/files/")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Authenticated API calls never follow redirects; CDN downloads never receive the API key.
        guard task.originalRequest?.value(forHTTPHeaderField: "x-api-key") == nil,
              request.url.map(Self.allowsCDN) == true else { completionHandler(nil); return }
        var clean = request; clean.setValue(nil, forHTTPHeaderField: "x-api-key"); clean.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(clean)
    }
}

public final class CurseForgeClient: @unchecked Sendable {
    private let key: String
    private let session: URLSession
    public init(apiKey: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw ManagerError("请先配置 CurseForge API Key") }
        key = value
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: CFRedirectPolicy(), delegateQueue: nil)
    }
    public func versionTypes() async throws -> [CFVersionType] {
        let response: CFResponse<[CFVersionType]> = try await api("games/1/version-types")
        return response.data.filter { $0.gameId == 1 }.sorted { $0.name < $1.name }
    }
    public func search(_ query: String, index: Int = 0) async throws -> CFSearchPage {
        guard index >= 0, index <= 9980 else { throw ManagerError("已达到搜索分页上限") }
        return try await api("mods/search", query: [URLQueryItem(name: "gameId", value: "1"), URLQueryItem(name: "searchFilter", value: query), URLQueryItem(name: "pageSize", value: "20"), URLQueryItem(name: "index", value: String(index)), URLQueryItem(name: "sortField", value: "2"), URLQueryItem(name: "sortOrder", value: "desc")])
    }
    public func mod(_ id: Int) async throws -> CFMod {
        guard id > 0 else { throw ManagerError("插件 ID 无效") }
        let response: CFResponse<CFMod> = try await api("mods/\(id)")
        guard response.data.gameId == 1, response.data.id == id else { throw ManagerError("返回的插件不属于魔兽世界") }
        return response.data
    }
    public func files(modID: Int, typeID: Int, version: String) async throws -> [CFFile] {
        guard modID > 0, typeID > 0 else { throw ManagerError("请先选择版本分支") }
        var query = [URLQueryItem(name: "gameVersionTypeId", value: String(typeID)), URLQueryItem(name: "pageSize", value: "50")]
        if !version.isEmpty { query.append(URLQueryItem(name: "gameVersion", value: version)) }
        let response: CFResponse<[CFFile]> = try await api("mods/\(modID)/files", query: query)
        return response.data.filter { $0.modId == modID && $0.matches(typeID: typeID, version: version) }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    public func download(_ selection: CFSelection) async throws -> URL {
        let file = selection.file
        guard file.modId == selection.mod.id, selection.mod.gameId == 1,
              selection.mod.allowModDistribution != false, file.matches(typeID: selection.typeID, version: selection.version) else { throw ManagerError("作者禁止第三方分发，或此文件不匹配所选版本") }
        // Recheck current author permission before every download, including previously installed sources.
        let current = try await mod(selection.mod.id)
        guard current.allowModDistribution != false else { throw ManagerError("作者已禁止第三方分发，请前往作者页面") }
        let result: CFResponse<String?> = try await api("mods/\(current.id)/files/\(file.id)/download-url")
        guard let text = result.data, let url = URL(string: text), CFRedirectPolicy.allowsCDN(url) else { throw ManagerError("API 未提供允许的下载链接，请前往作者页面") }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        try validate(response)
        guard response.expectedContentLength <= Int64(GitHubClient.maxArchiveBytes) else { throw ManagerError("下载超过 256 MB 限制") }
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("AzerothCF-" + UUID().uuidString + ".zip")
        guard FileManager.default.createFile(atPath: location.path, contents: nil) else { throw ManagerError("无法创建下载文件") }
        let handle = try FileHandle(forWritingTo: location)
        do {
            var count = 0, chunk = Data(), sha1 = Insecure.SHA1(), md5 = Insecure.MD5()
            for try await byte in stream {
                try Task.checkCancellation(); count += 1
                guard count <= file.fileLength, count <= GitHubClient.maxArchiveBytes else { throw ManagerError("下载超出声明大小") }
                chunk.append(byte)
                if chunk.count == 65536 { sha1.update(data: chunk); md5.update(data: chunk); try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            sha1.update(data: chunk); md5.update(data: chunk); try handle.write(contentsOf: chunk); try handle.close()
            guard count == file.fileLength else { throw ManagerError("文件下载不完整") }
            let sha = sha1.finalize().map { String(format: "%02x", $0) }.joined(), md = md5.finalize().map { String(format: "%02x", $0) }.joined()
            let known = file.hashes.filter { $0.algo == 1 || $0.algo == 2 }
            guard !known.isEmpty, known.allSatisfy({ $0.value.lowercased() == ($0.algo == 1 ? sha : md) }) else { throw ManagerError("文件校验失败，或 API 未提供可识别摘要") }
            return location
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: location); throw error }
    }
    private func api<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        var components = URLComponents(string: "https://api.curseforge.com/v1/" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        try validate(response)
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 8 * 1024 * 1024 else { throw ManagerError("API 响应超过限制") }
            data.append(byte)
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw ManagerError("CurseForge 返回的数据格式无法识别") }
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ManagerError("无法读取网络响应") }
        switch http.statusCode {
        case 200: return
        case 401: throw ManagerError("API Key 无效或已失效，请重新配置")
        case 403: throw ManagerError("访问被拒绝：请检查 API 权限或作者分发限制")
        case 429: throw ManagerError("请求受到频率限制，请稍后重试")
        case 404: throw ManagerError("插件、文件或版本不存在")
        default: throw ManagerError("CurseForge 请求失败（HTTP \(http.statusCode)）")
        }
    }
}

public struct CFSelection: Sendable {
    public let mod: CFMod
    public let file: CFFile
    public let typeID: Int
    public let version: String
    public let flavor: Flavor
    public init(mod: CFMod, file: CFFile, typeID: Int, version: String, flavor: Flavor) {
        self.mod = mod; self.file = file; self.typeID = typeID; self.version = version; self.flavor = flavor
    }
}
public struct CFReceipt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let modID: Int
    public let fileID: Int
    public let fileDate: String
    public let typeID: Int
    public let version: String
    public let flavor: Flavor
    public let folders: [String]
    public let fingerprints: [String: String]
    public init(selection: CFSelection, folders: [URL]) throws {
        id = UUID(); modID = selection.mod.id; fileID = selection.file.id; fileDate = selection.file.fileDate
        typeID = selection.typeID; version = selection.version; flavor = selection.flavor
        self.folders = folders.map(\.lastPathComponent)
        fingerprints = try Dictionary(uniqueKeysWithValues: folders.map { ($0.lastPathComponent, try SourceTracking.fingerprint($0)) })
    }
    public func newerFile(in files: [CFFile]) -> CFFile? {
        // Never select another client branch, beta/alpha, or a known older release.
        let date = CFReceipt.parseDate(fileDate)
        return files.first { file in file.id != fileID && file.modId == modID && file.matches(typeID: typeID, version: version) && date != nil && (file.date ?? .distantPast) >= date! }
    }
    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
public enum CFTracking {
    static let filename = ".azeroth-curseforge.json"
    public static func receipts(in target: URL) throws -> [CFReceipt] {
        let file = target.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 4 * 1024 * 1024 else { throw ManagerError("CurseForge 安装记录过大") }
        do { return try JSONDecoder().decode([CFReceipt].self, from: data) }
        catch { throw ManagerError("CurseForge 安装记录损坏，请先备份后检查") }
    }
    static func write(_ records: [CFReceipt], to target: URL) throws {
        try JSONEncoder().encode(records).write(to: target.appendingPathComponent(filename), options: .atomic)
    }
    static func removing(_ folders: [String], from records: [CFReceipt]) -> [CFReceipt] {
        let keys = Set(folders.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        return records.filter { record in !record.folders.contains { keys.contains($0.precomposedStringWithCanonicalMapping.lowercased()) } }
    }
    public static func isUnchanged(_ record: CFReceipt, in target: URL) throws -> Bool {
        guard !record.folders.isEmpty else { return false }
        for name in record.folders {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..", FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path) else { return false }
            if try SourceTracking.fingerprint(target.appendingPathComponent(name)) != record.fingerprints[name] { return false }
        }
        return true
    }
}
