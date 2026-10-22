import Foundation
import CryptoKit

public struct GitHubRepository: Hashable, Codable, Sendable {
    public let owner: String
    public let name: String
    public var fullName: String { owner + "/" + name }
    public var webURL: URL { URL(string: "https://github.com/" + fullName)! }
    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
                throw ManagerError("请输入公开 GitHub 仓库地址或 owner/repo")
            }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { path = text }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ManagerError("仓库格式应为 owner/repo，不要填写发布文件地址") }
        let owner = String(parts[0]), name = String(parts[1]).replacingOccurrences(of: "\\.git$", with: "", options: .regularExpression)
        let pattern = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"
        guard owner.range(of: pattern, options: .regularExpression) != nil,
              name.range(of: pattern, options: .regularExpression) != nil, name != ".", name != ".." else {
            throw ManagerError("GitHub 仓库名称无效")
        }
        self.owner = owner; self.name = name
    }
}

public struct GitHubAsset: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
    public let browserDownloadURL: URL
    public let digest: String?
    enum CodingKeys: String, CodingKey {
        case id, name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
    public var isInstallableZIP: Bool { name.lowercased().hasSuffix(".zip") && size > 0 && size <= GitHubClient.maxArchiveBytes }
}

public struct GitHubRelease: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: Date?
    public let assets: [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case id, name, body, draft, prerelease, assets
        case tagName = "tag_name", publishedAt = "published_at"
    }
    public var title: String { name?.isEmpty == false ? name! : tagName }
    public var zipAssets: [GitHubAsset] { assets.filter(\.isInstallableZIP) }
}

public struct GitHubSelection: Sendable {
    public let repository: GitHubRepository
    public let release: GitHubRelease
    public let asset: GitHubAsset
    public let flavor: Flavor
    public init(repository: GitHubRepository, release: GitHubRelease, asset: GitHubAsset, flavor: Flavor) {
        self.repository = repository; self.release = release; self.asset = asset; self.flavor = flavor
    }
}

private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

public final class GitHubClient: @unchecked Sendable {
    public static let maxArchiveBytes = 256 * 1024 * 1024
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }
    public func releases(in repository: GitHubRepository) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repository.fullName)/releases?per_page=30")!
        let (stream, response) = try await session.bytes(for: request(url))
        defer { stream.task.cancel() }
        try validate(response)
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw ManagerError("发布信息过大，已停止读取") }
            data.append(byte)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let all: [GitHubRelease]
        do { all = try decoder.decode([GitHubRelease].self, from: data) }
        catch { throw ManagerError("GitHub 返回的发布信息格式无法识别") }
        return all.filter { !$0.draft && !$0.prerelease }.sorted {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
    }
    public func download(_ selection: GitHubSelection) async throws -> URL {
        let asset = selection.asset, url = asset.browserDownloadURL
        guard asset.isInstallableZIP, selection.release.assets.contains(asset),
              url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.port == nil,
              url.path.lowercased().hasPrefix("/\(selection.repository.fullName.lowercased())/releases/download/") else {
            throw ManagerError("只接受所选仓库正式发布中的 ZIP 附件")
        }
        let (stream, response) = try await session.bytes(for: request(url, accept: "application/octet-stream"))
        defer { stream.task.cancel() }
        try validate(response)
        guard response.expectedContentLength <= Int64(Self.maxArchiveBytes) else { throw ManagerError("下载超过 256 MB 限制") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AzerothDownload-" + UUID().uuidString + ".zip")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ManagerError("无法建立临时下载文件") }
        let handle = try FileHandle(forWritingTo: file)
        do {
            var count = 0, buffer = Data(), hash = SHA256()
            buffer.reserveCapacity(65536)
            for try await byte in stream {
                try Task.checkCancellation()
                count += 1
                guard count <= Self.maxArchiveBytes, count <= asset.size else { throw ManagerError("下载内容超出声明大小，已中止") }
                buffer.append(byte)
                if buffer.count == 65536 { hash.update(data: buffer); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            hash.update(data: buffer); try handle.write(contentsOf: buffer); try handle.close()
            guard count == asset.size else { throw ManagerError("下载不完整，请重试") }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if let digest = asset.digest {
                guard digest.lowercased() == "sha256:" + actual else { throw ManagerError("下载文件 SHA-256 不匹配或摘要格式不受支持") }
            }
            return file
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
    }
    private func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("AzerothManager/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ManagerError("无法读取服务器响应") }
        switch http.statusCode {
        case 200: return
        case 403, 429: throw ManagerError("GitHub 请求受限或额度已用完，请稍后重试")
        case 404: throw ManagerError("仓库或发布文件不存在，或不是公开仓库")
        default: throw ManagerError("GitHub 请求失败（HTTP \(http.statusCode)）")
        }
    }
}

public struct SourceReceipt: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let repository: GitHubRepository
    public let releaseID: Int
    public let tagName: String
    public let publishedAt: Date?
    public let assetID: Int
    public let assetName: String
    public let flavor: Flavor
    public let folders: [String]
    public let fingerprints: [String: String]
    public init(selection: GitHubSelection, folders: [URL]) throws {
        id = UUID(); repository = selection.repository; releaseID = selection.release.id
        tagName = selection.release.tagName; publishedAt = selection.release.publishedAt
        assetID = selection.asset.id; assetName = selection.asset.name; flavor = selection.flavor
        self.folders = folders.map(\.lastPathComponent)
        fingerprints = try Dictionary(uniqueKeysWithValues: folders.map { ($0.lastPathComponent, try SourceTracking.fingerprint($0)) })
    }
    public func newerRelease(in releases: [GitHubRelease]) -> GitHubRelease? {
        guard let date = publishedAt else { return nil }
        return releases.first { release in
            guard !release.draft, !release.prerelease else { return false }
            if release.id == releaseID {
                return release.zipAssets.contains { $0.name == assetName && $0.id != assetID }
            }
            return (release.publishedAt ?? .distantPast) > date && !release.zipAssets.isEmpty
        }
    }
}

public enum SourceTracking {
    static let filename = ".azeroth-sources.json"
    public static func receipts(in target: URL) throws -> [SourceReceipt] {
        let url = target.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw ManagerError("来源记录过大") }
        do { return try JSONDecoder().decode([SourceReceipt].self, from: data) }
        catch { throw ManagerError("来源记录损坏，请先备份并检查 .azeroth-sources.json") }
    }
    static func write(_ records: [SourceReceipt], to target: URL) throws {
        try JSONEncoder().encode(records).write(to: target.appendingPathComponent(filename), options: .atomic)
    }
    static func removing(_ folders: [String], from records: [SourceReceipt]) -> [SourceReceipt] {
        let keys = Set(folders.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        // A release can contain several addon folders: invalidate the whole receipt if any is replaced.
        return records.filter { record in !record.folders.contains { keys.contains($0.precomposedStringWithCanonicalMapping.lowercased()) } }
    }
    public static func isUnchanged(_ record: SourceReceipt, in target: URL) throws -> Bool {
        for name in record.folders {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return false }
            let folder = target.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: folder.path), try fingerprint(folder) == record.fingerprints[name] else { return false }
        }
        return !record.folders.isEmpty
    }
    static func fingerprint(_ folder: URL) throws -> String {
        try FileSafety.checkTree(folder)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder.path) else { throw ManagerError("无法读取插件文件") }
        let names = enumerator.compactMap { $0 as? String }.sorted()
        var hash = SHA256()
        for relative in names {
            let file = folder.appendingPathComponent(relative)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var fileHash = SHA256()
            while let data = try handle.read(upToCount: 65536), !data.isEmpty { fileHash.update(data: data) }
            hash.update(data: Data(fileHash.finalize()))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
