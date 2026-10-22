import XCTest
import CryptoKit
@testable import ManagerCore

private final class CFStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class CurseForgeTests: XCTestCase {
    func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func client() throws -> CurseForgeClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CFStub.self]
        return try CurseForgeClient(apiKey: "test-key", configuration: configuration)
    }
    func mod(allowed: Bool = true) throws -> CFMod {
        try JSONDecoder().decode(CFMod.self, from: json(modJSON(allowed: allowed)))
    }
    func modJSON(allowed: Bool = true) -> [String: Any] {
        ["id": 10, "gameId": 1, "name": "Example", "summary": "Test", "allowModDistribution": allowed, "links": ["websiteUrl": "https://www.curseforge.com/wow/addons/example"]]
    }
    func fileJSON(id: Int = 20, type: Int = 517, date: String = "2026-01-01T00:00:00Z", data: Data = Data("zip".utf8), digest: String? = nil) -> [String: Any] {
        ["id": id, "gameId": 1, "modId": 10, "isAvailable": true, "displayName": "Example", "fileName": "Example.zip", "releaseType": 1, "fileDate": date, "fileLength": data.count, "gameVersions": ["1.15.0"], "sortableGameVersions": [["gameVersionTypeId": type]], "hashes": [["algo": 1, "value": digest ?? Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()]], "dependencies": [["modId": 99, "relationType": 3]]]
    }
    func file(_ value: [String: Any]) throws -> CFFile { try JSONDecoder().decode(CFFile.self, from: json(value)) }
    func testSearchEscapesQueryAndIncludesHeaderAndPagination() async throws {
        CFStub.handler = { request in
            XCTAssertEqual(request.url?.host, "api.curseforge.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "searchFilter" }?.value, "中文 & +=")
            XCTAssertEqual(query.first { $0.name == "index" }?.value, "20")
            return (200, try self.json(["data": [self.modJSON()], "pagination": ["index": 20, "pageSize": 20, "resultCount": 1, "totalCount": 21]]))
        }
        let page = try await client().search("中文 & +=", index: 20)
        XCTAssertEqual(page.data.first?.id, 10); XCTAssertFalse(page.hasNext)
    }
    func testLocalFilteringRejectsWrongBranchAndBeta() async throws {
        var beta = fileJSON(id: 23); beta["releaseType"] = 2
        let payload = try json(["data": [fileJSON(), fileJSON(id: 21, type: 999), beta]])
        CFStub.handler = { _ in (200, payload) }
        let found = try await client().files(modID: 10, typeID: 517, version: "1.15.0")
        XCTAssertEqual(found.map(\.id), [20])
        XCTAssertFalse(try file(fileJSON()).matches(typeID: 517, version: "2.0"))
    }
    func testErrorsAndMalformedResponses() async throws {
        for status in [401, 403, 404, 429, 500, 302] {
            CFStub.handler = { _ in (status, Data()) }
            do { _ = try await client().versionTypes(); XCTFail("Must fail") } catch { XCTAssertTrue(error is ManagerError) }
        }
        CFStub.handler = { _ in (200, Data("invalid".utf8)) }
        do { _ = try await client().versionTypes(); XCTFail("Must fail") } catch { XCTAssertTrue(error is ManagerError) }
    }
    func testDownloadOmitsCredentialsAndChecksDigestAndLength() async throws {
        let payload = Data("zip".utf8)
        CFStub.handler = { request in
            if request.url!.host == "api.curseforge.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
                return (200, try self.json(["data": request.url!.path.hasSuffix("download-url") ? "https://edge.forgecdn.net/files/1/2/Example.zip" as Any : self.modJSON() as Any]))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, payload)
        }
        let selected = CFSelection(mod: try mod(), file: try file(fileJSON()), typeID: 517, version: "", flavor: .time)
        let download = try await client().download(selected)
        defer { try? FileManager.default.removeItem(at: download) }
        XCTAssertEqual(try Data(contentsOf: download), payload)
        for invalid in [fileJSON(digest: "bad"), fileJSON(data: Data("longer".utf8))] {
            do { _ = try await client().download(CFSelection(mod: mod(), file: file(invalid), typeID: 517, version: "", flavor: .time)); XCTFail("Must fail") }
            catch { XCTAssertTrue(error is ManagerError) }
        }
    }
    func testAuthorRestrictionAndMissingLinkStopDownload() async throws {
        CFStub.handler = { request in
            XCTAssertEqual(request.url?.host, "api.curseforge.com")
            return (200, try self.json(["data": request.url!.path.hasSuffix("download-url") ? NSNull() as Any : self.modJSON() as Any]))
        }
        for allowed in [false, true] {
            do { _ = try await client().download(CFSelection(mod: mod(allowed: allowed), file: file(fileJSON()), typeID: 517, version: "", flavor: .time)); XCTFail("Must fail") }
            catch { XCTAssertTrue(error is ManagerError) }
        }
    }
    func testCDNAllowlistRejectsLookalikesAndCredentials() {
        XCTAssertTrue(CFRedirectPolicy.allowsCDN(URL(string: "https://edge.forgecdn.net/files/1/a.zip")!))
        for url in ["http://edge.forgecdn.net/files/a", "https://forgecdn.net.evil.com/files/a", "https://user@edge.forgecdn.net/files/a", "https://edge.forgecdn.net:443/files/a", "https://edge.forgecdn.net/other/a"] {
            XCTAssertFalse(CFRedirectPolicy.allowsCDN(URL(string: url)!))
        }
    }
    func testReceiptsManualReplacementUninstallRestoreAndUpdateBranch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let library = Library(backupRoot: root.appendingPathComponent("Backups"))
        let archive = try XCTUnwrap(Bundle.module.url(forResource: "Deflate", withExtension: "zip", subdirectory: "Fixtures"))
        let preview = try library.prepare(archive, target: target, flavor: .time)
        defer { library.discard(preview) }
        let selection = CFSelection(mod: try mod(), file: try file(fileJSON()), typeID: 517, version: "", flavor: .time)
        try library.install(preview, target: target, curseForge: selection)
        let record = try XCTUnwrap(CFTracking.receipts(in: target).first)
        XCTAssertTrue(try CFTracking.isUnchanged(record, in: target))
        XCTAssertNil(record.newerFile(in: [try file(fileJSON(id: 21, type: 999, date: "2026-02-01T00:00:00Z")), try file(fileJSON(id: 22, date: "2025-01-01T00:00:00Z"))]))
        XCTAssertEqual(record.newerFile(in: [try file(fileJSON(id: 23, date: "2026-02-01T00:00:00Z"))])?.id, 23)
        let snapshot = try library.backup(target, reason: "test")
        try library.install(preview, target: target)
        XCTAssertTrue(try CFTracking.receipts(in: target).isEmpty)
        try library.restore(snapshot, target: target)
        XCTAssertEqual(try CFTracking.receipts(in: target).first?.fileID, 20)
        try library.uninstall(record.folders, target: target)
        XCTAssertTrue(try CFTracking.receipts(in: target).isEmpty)
    }
}
