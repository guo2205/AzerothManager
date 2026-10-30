import Foundation

private struct NBArray<T: Decodable>: Decodable {
    let values: [T]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { values = try JSONDecoder().decode([T].self, from: Data(text.utf8)) }
        else { values = try c.decode([T].self) }
    }
}
public struct NewBeeShare: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable { public let name: String }
    public struct Plugin: Decodable, Sendable, Equatable {
        public let name: String; public let id: String; public let fileName: String?
        public let updateType: Int?; public let mod_file_id: Int?
    }
    public struct Role: Decodable, Sendable, Equatable { public let name: String; public let zip: String? }
    public struct Realm: Decodable, Sendable, Equatable { public let serverName: String; public let roleList: [Role] }
    public struct Account: Decodable, Sendable, Equatable { public let account: String; public let commonConfig: String?; public let server: [Realm] }
    public let id: Int; public let title: String; public let shareCode: String
    public let gameVersion: Int; public let accessible: Bool
    public let revision: Int64
    public let plugins: [Plugin]; public let accounts: [Account]
    public let materialZIP: String?; public let fontZIP: String?; public let fontIndex: String?
    public let materials: [Asset]; public let fonts: [Asset]
    enum CodingKeys: String, CodingKey {
        case id = "t_id", title = "t_title", shareCode = "t_sharecode", gameVersion = "t_versionid", accessible = "is_content_access"
        case plugins = "t__known_plug", accounts = "wtflist", materialZIP = "t_material", fontZIP = "t_font", fontIndex = "t_font_ncs_hash"
        case materials = "t_material_list", fonts = "t_font_list", unknown = "t_un_known_list"
        case revision = "t_update_time"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        if let value = try? c.decode(String.self, forKey: .shareCode) { shareCode = value }
        else { shareCode = String(try c.decode(Int.self, forKey: .shareCode)) }
        gameVersion = try c.decode(Int.self, forKey: .gameVersion); accessible = try c.decode(Bool.self, forKey: .accessible)
        revision = try c.decode(Int64.self, forKey: .revision)
        plugins = try c.decode(NBArray<Plugin>.self, forKey: .plugins).values
        guard plugins.count <= 500, Set(plugins.map(\.id)).count == plugins.count else { throw ManagerError("分享插件数量超过限制或包含重复项目") }
        accounts = try c.decodeIfPresent(NBArray<Account>.self, forKey: .accounts)?.values ?? []
        materialZIP = try c.decodeIfPresent(String.self, forKey: .materialZIP); fontZIP = try c.decodeIfPresent(String.self, forKey: .fontZIP)
        fontIndex = try c.decodeIfPresent(String.self, forKey: .fontIndex)
        materials = try c.decodeIfPresent(NBArray<Asset>.self, forKey: .materials)?.values ?? []
        fonts = try c.decodeIfPresent(NBArray<Asset>.self, forKey: .fonts)?.values ?? []
        let unknown = try c.decodeIfPresent(NBArray<Asset>.self, forKey: .unknown)?.values ?? []
        guard unknown.isEmpty else { throw ManagerError("此分享包含尚不支持的未知插件归档，不能按完整配置安装") }
    }
}
public struct NewBeePluginFile: Decodable, Sendable, Equatable {
    public let release_type: Int
    public let file_display_name: String
    public let file_name: String
    public let file_url: String
    public let file_folders: [String]
    public func downloadURL(pluginID: Int) throws -> URL {
        let prefix = "https://cdn8.newbeebox.com/mod_file/\(pluginID)/"
        if file_url == prefix + file_name {
            try ConfigurationFiles.validateComponent(file_name)
            var url = URLComponents(string: prefix)!
            url.path = "/mod_file/\(pluginID)/" + file_name
            return try NewBeeClient.resourceURL(url.url!.absoluteString)
        }
        return try NewBeeClient.resourceURL(file_url)
    }
}
public struct NewBeeIndexFile: Decodable, Sendable, Equatable {
    public struct Chunk: Decodable, Sendable, Equatable { public let size: Int; public let url: String; public let hash: String }
    public let relPath: String; public let totalSize: Int; public let chunks: [Chunk]; public let fullHash: String
}
public struct NewBeeLogin: Sendable { public let image: Data; public let expires: Date }
private struct NBEnvelope<T: Decodable>: Decodable { let code: Int; let data: T? }
private final class NBRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
/// Temporary account session. No cookies, credential persistence, logs or refresh tokens.
public actor NewBeeClient {
    private let session: URLSession
    private var token: String?
    private var challenge: String?
    private var expiry = Date.distantPast
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpAdditionalHeaders = nil
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: NBRedirectPolicy(), delegateQueue: nil)
    }
    public func logout() { token = nil; challenge = nil; expiry = .distantPast }
    public static func gameVersion(_ flavor: Flavor) -> Int { flavor == .time ? 4 : 2 }
    public static func resourceURL(_ path: String) throws -> URL {
        var raw = path
        for _ in 0..<8 {
            guard !raw.contains("\\"), !raw.split(separator: "/").contains("..") else { throw ManagerError("资源路径无效") }
            let decoded = raw.removingPercentEncoding ?? raw
            if decoded == raw { break }
            raw = decoded
        }
        guard !raw.contains("\\"), !raw.split(separator: "/").contains(".."), (raw.removingPercentEncoding ?? raw) == raw else { throw ManagerError("资源路径编码过于复杂") }
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: path, relativeTo: URL(string: "https://cdn8.newbeebox.com/")!)?.absoluteURL,
              url.scheme == "https", url.host == "cdn8.newbeebox.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { throw ManagerError("资源下载地址不受信任") }
        var decoded = url.path
        for _ in 0..<3 {
            guard !decoded.contains("\\"), !decoded.split(separator: "/").contains("..") else { throw ManagerError("资源路径无效") }
            let next = decoded.removingPercentEncoding ?? decoded
            if next == decoded { break }; decoded = next
        }
        return url
    }
    private func read(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ManagerError("新手盒子网络请求未完成") }
        if response.expectedContentLength > Int64(limit) { throw ManagerError("新手盒子响应超过大小限制") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ManagerError("新手盒子响应超过大小限制") }
            data.append(byte)
        }
        return data
    }
    private func post<T: Decodable>(_ path: String, _ body: [String: Any], authenticated: Bool = false, form: Bool = false) async throws -> T {
        let host = path.hasPrefix("v3/") ? "api.newbeebox.com" : "api.next.newbeebox.com"
        var request = URLRequest(url: URL(string: "https://" + host + "/" + path)!)
        if path.hasPrefix("legacy:") { throw ManagerError("接口路径无效") }
        request.httpMethod = "POST"
        if authenticated {
            guard let token else { throw ManagerError("请先登录新手盒子") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        if form {
            var parts = URLComponents(); parts.queryItems = body.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
            request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data = try await read(request, limit: 16 * 1024 * 1024)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ManagerError("新手盒子响应格式无法识别") }
    }
    public func beginLogin() async throws -> NewBeeLogin {
        struct QR: Decodable { let qrCode: String; let resultId: String; let expiresAt: Double }
        let reply: NBEnvelope<QR> = try await post("auth/oauth/wechat/getAuthUrl", ["clientId": "nbb-desktop"])
        guard reply.code == 1, let value = reply.data, value.qrCode.hasPrefix("data:image/png;base64,"),
              let image = Data(base64Encoded: String(value.qrCode.dropFirst("data:image/png;base64,".count))), image.count < 2 * 1024 * 1024,
              (image.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) || image.prefix(3) == Data([255, 216, 255])) else { throw ManagerError("未取得官方登录二维码") }
        token = nil; challenge = value.resultId; expiry = min(Date(timeIntervalSince1970: value.expiresAt / 1000), Date().addingTimeInterval(900))
        return NewBeeLogin(image: image, expires: expiry)
    }
    public func waitForLogin() async throws {
        struct Result: Decodable { let oAuthCode: String? }
        struct Access: Decodable { let access_token: String? }
        guard let challenge else { throw ManagerError("请先获取登录二维码") }
        while Date() < expiry {
            guard self.challenge == challenge else { throw CancellationError() }
            let reply: NBEnvelope<Result> = try await post("auth/oauth/getResult", ["resultId": challenge])
            guard self.challenge == challenge else { throw CancellationError() }
            if let code = reply.data?.oAuthCode {
                let access: Access = try await post("auth/connect/token", ["client_id": "nbb-desktop", "grant_type": "oauth_code", "code": code, "scope": "openid", "device_name": "艾泽拉斯插件管家", "device_type": "desktop"], form: true)
                guard let value = access.access_token, !value.isEmpty else { throw ManagerError("新手盒子授权未完成") }
                guard self.challenge == challenge else { throw CancellationError() }
                token = value; self.challenge = nil; return
            }
            if reply.code == 2001 { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        self.challenge = nil; throw ManagerError("二维码已过期，请重新获取")
    }
    public func downloadResource(_ path: String) async throws -> Data {
        try await read(URLRequest(url: Self.resourceURL(path)), limit: 256 * 1024 * 1024)
    }
    public func share(code: String, flavor: Flavor) async throws -> NewBeeShare {
        struct Resolved: Decodable { let gameId: Int; let moduleType: Int; let moduleId: Int }
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { throw ManagerError("请输入六位新手盒子分享码") }
        let resolution: NBEnvelope<Resolved> = try await post("bannerserver/ShareCode/Get", ["shareCode": code])
        guard resolution.code == 1, let resolved = resolution.data, resolved.gameId == 1, resolved.moduleType == 4, resolved.moduleId > 0 else { throw ManagerError("此分享码不是魔兽世界配置分享，或登录已失效") }
        let reply: NBEnvelope<[NewBeeShare]> = try await post("v3/share_config/details_aps", ["id": resolved.moduleId], authenticated: true)
        guard reply.code == 1, let value = reply.data?.first, value.id == resolved.moduleId,
              value.shareCode == code, value.gameVersion == Self.gameVersion(flavor) else { throw ManagerError("分享与当前客户端不匹配，或登录已失效") }
        guard value.accessible else { throw ManagerError("账号尚无此分享访问权限，请在新手盒子官方平台处理") }
        return value
    }
    public func pluginFile(_ plugin: NewBeeShare.Plugin, flavor: Flavor) async throws -> NewBeePluginFile {
        guard let id = Int(plugin.id), id > 0, plugin.updateType == 1 else { throw ManagerError("暂不支持此插件的锁定或忽略策略，不能用最新版替代") }
        struct Detail: Decodable { struct Item: Decodable { let id: Int; let game_version_id: Int; let is_content_access: Bool; let file_list: [NewBeePluginFile] }; let result: Item }
        let reply: NBEnvelope<Detail> = try await post("v3/mod/detail", ["mod_id": id, "game_version": Self.gameVersion(flavor)], authenticated: true)
        guard reply.code == 1, let detail = reply.data?.result, detail.id == id,
              detail.game_version_id == Self.gameVersion(flavor), detail.is_content_access,
              let file = detail.file_list.first(where: { $0.release_type == 1 }), !file.file_folders.isEmpty else { throw ManagerError("未取得此客户端可访问的正式插件文件：" + plugin.name) }
        _ = try file.downloadURL(pluginID: id)
        return file
    }
    public func indexFiles(_ code: String) async throws -> [NewBeeIndexFile] {
        struct Meta: Decodable { let fileCount: Int; let totalSize: Int; let indexType: Int }
        struct Page: Decodable { let files: [NewBeeIndexFile]; let nextAfter: String?; let hasMore: Bool }
        guard !code.isEmpty, code.utf8.count < 1024 else { throw ManagerError("资源索引无效") }
        let meta: NBEnvelope<Meta> = try await post("uploadserver/upload/v3/index/meta", ["code": code])
        guard meta.code == 1, let info = meta.data, info.indexType == 1, info.fileCount > 0, info.fileCount <= 20000, info.totalSize > 0, info.totalSize <= 1024 * 1024 * 1024 else { throw ManagerError("资源索引类型或大小不受支持") }
        var result: [NewBeeIndexFile] = [], after = "", seen = Set<String>()
        while true {
            let page: NBEnvelope<Page> = try await post("uploadserver/upload/v3/index/files", ["code": code, "after": after, "limit": 100])
            guard page.code == 1, let value = page.data, !value.files.isEmpty else { throw ManagerError("资源索引未能完整读取") }
            for file in value.files {
                guard file.totalSize >= 0, file.totalSize <= 128 * 1024 * 1024, file.chunks.count <= 10000,
                      file.chunks.allSatisfy({ $0.size > 0 && $0.size <= 128 * 1024 * 1024 }),
                      file.chunks.reduce(0, { $0 + $1.size }) == file.totalSize else { throw ManagerError("资源分片大小不一致或超过限制") }
                for chunk in file.chunks { _ = try Self.resourceURL(chunk.url) }
            }
            result += value.files
            guard result.count <= info.fileCount else { throw ManagerError("资源索引条目数量不一致") }
            if !value.hasMore { break }
            guard let next = value.nextAfter, !next.isEmpty, seen.insert(next).inserted else { throw ManagerError("资源索引分页无法继续") }
            after = next
        }
        guard result.count == info.fileCount, result.reduce(0, { $0 + $1.totalSize }) == info.totalSize else { throw ManagerError("资源索引清单已变化，请重新读取") }
        return result
    }
}
