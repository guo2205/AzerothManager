import Foundation

public struct DDShareSummary: Decodable, Identifiable, Sendable {
    public let sn: String
    public let title: String
    public let user_nick: String?
    public let game_type: Int
    public let brief_desc: String?
    public let need_buy: Bool?
    public let need_anchor_vip: Bool?
    public var id: String { sn }
}
public struct DDSharePage: Decodable, Sendable {
    public let count: Int
    public let shares: [DDShareSummary]
}
public struct DDShareDetail: Decodable, Identifiable, Sendable {
    public let sn: String
    public let title: String
    public let user_nick: String?
    public let share_code: String?
    public let version: String?
    public let game_type: Int
    public let brief_desc: String?
    public let scope: String?
    public let expired: Bool?
    public let need_buy: Bool?
    public let need_anchor_vip: Bool?
    public let known_addon: Addons?
    public let unknown_addon: Extra?
    public let wtf: WTF?
    public let font: Extra?
    public let material: Extra?
    public var id: String { sn }
    public struct Addons: Decodable, Sendable {
        public let url: String?
        public let size: Int?
        public let items: [Item]?
        public struct Item: Decodable, Sendable {
            public let name: String
            public let dirs: [String]
            public let modified: Bool?
            public let url: String?
        }
    }
    public struct Extra: Decodable, Sendable { public let url: String?; public let size: Int? }
    public struct WTF: Decodable, Sendable {
        public let url: String?
        public let size: Int?
        public let accounts: [Account]?
        public struct Account: Decodable, Sendable {
            public let name: String
            public let servers: [Server]?
            public struct Server: Decodable, Sendable { public let name: String; public let items: [String]? }
        }
    }
    public var requiresPurchase: Bool { need_buy == true || need_anchor_vip == true }
    public var hasConfigurationDownload: Bool { !(wtf?.url ?? "").isEmpty }
    public var website: URL { DDShareClient.website(sn: sn, gameType: game_type) }
}
private struct DDShareResponse<T: Decodable>: Decodable { let code: Int; let msg: String?; let result: T? }

/// 官方配置分享的只读入口；不调用订阅、购买、上传或安装上报接口。
public struct DDShareClient: Sendable {
    /// 在官方网页的临时会话内完成插件登录。凭据不返回 Swift、不写入磁盘。
    public static let authenticatedDetailScript = #"""
    async function readJSON(url, headers = {}) {
        const response = await fetch(url, {credentials: 'include', cache: 'no-store', redirect: 'error', headers});
        if (!response.ok) throw new Error('网易 DD 接口请求失败，请稍后重试');
        const raw = await response.text();
        if (raw.length > 16777216) throw new Error('DD 响应超过限制');
        try { return JSON.parse(raw); } catch (_) { throw new Error('DD 响应格式无法识别'); }
    }
    // 只允许向已确认的官方插件接口发送临时凭据，拒绝重定向。
    if (typeof endpoint !== 'string' || !endpoint.startsWith('https://uiapi.w.163.com/share/detail?'))
        throw new Error('分享接口地址无效');
    const login = await readJSON('https://uiapi.w.163.com/login/dslogin?ef=0&uf=0&ts=0&ab=0');
    if (login.code !== 0 || typeof login.result?.token !== 'string' || !login.result.token)
        throw new Error('DD 网页已登录，但插件服务登录未完成；当前网页会话可能不支持此登录方式');
    const detail = await readJSON(endpoint, {'x-w163-token': login.result.token});
    // 仅传回分享数据，不传回登录响应或临时凭据。
    return JSON.stringify({code: detail.code, result: detail.result});
    """#
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: DDRedirectPolicy(), delegateQueue: nil)
    }
    public static func website(sn: String, gameType: Int) -> URL {
        var url = URLComponents(string: "https://dd.163.com/wow/plugin")!
        url.queryItems = [URLQueryItem(name: "wow-plugin", value: "/dd-wow-tools/index.html#/config-share?sn=\(sn)&gametype=\(gameType)")]
        return url.url!
    }
    public static func detailURL(_ sn: String) throws -> URL {
        guard sn.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw ManagerError("DD 分享 ID 无效") }
        var url = URLComponents(string: "https://uiapi.w.163.com/share/detail")!
        url.queryItems = [URLQueryItem(name: "sn", value: sn)] + fixedQuery
        return url.url!
    }
    private static var fixedQuery: [URLQueryItem] { ["ef", "uf", "ts", "ab"].map { URLQueryItem(name: $0, value: "0") } }
    public static func decodeDetail(_ data: Data) throws -> DDShareDetail {
        try decode(DDShareDetail.self, data: data)
    }
    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        guard data.count <= 16 * 1024 * 1024 else { throw ManagerError("DD 配置分享响应超过限制") }
        let response: DDShareResponse<T>
        do { response = try JSONDecoder().decode(DDShareResponse<T>.self, from: data) }
        catch { throw ManagerError("DD 配置分享数据格式无法识别") }
        guard response.code == 0, let result = response.result else {
            if response.code == 412 || response.code == 401 { throw ManagerError("需要在网易 DD 官方页面登录后重试") }
            throw ManagerError(response.msg ?? "DD 配置分享请求失败")
        }
        return result
    }
    private func get(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ManagerError("DD 配置分享网络请求失败") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16 * 1024 * 1024 else { throw ManagerError("DD 配置分享响应超过限制") }
            data.append(byte)
        }
        return data
    }
    public func search(_ query: String, flavor: Flavor, page: Int = 1) async throws -> DDSharePage {
        guard page > 0, page <= 500 else { throw ManagerError("分享列表页码无效") }
        var url = URLComponents(string: "https://uiapi.w.163.com/share/list")!
        url.queryItems = Self.fixedQuery + [URLQueryItem(name: "game_type", value: String(DDClient.gameType(flavor))), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "20"), URLQueryItem(name: "origin", value: "all"), URLQueryItem(name: "sort_type", value: "week_download"), URLQueryItem(name: "search_type", value: "title_or_author_nick_or_share_code"), URLQueryItem(name: "search_text", value: query)]
        return try Self.decode(DDSharePage.self, data: await get(url.url!))
    }
    public func detail(_ sn: String, flavor: Flavor) async throws -> DDShareDetail {
        let result = try Self.decodeDetail(await get(Self.detailURL(sn)))
        guard result.sn == sn, result.game_type == DDClient.gameType(flavor) else { throw ManagerError("配置分享与当前客户端不匹配") }
        return result
    }
}
