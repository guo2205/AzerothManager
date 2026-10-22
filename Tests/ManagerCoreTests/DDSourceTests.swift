import XCTest
@testable import ManagerCore

private final class DDStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class DDSourceTests: XCTestCase {
    func client() -> DDClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DDStub.self]
        return DDClient(configuration: config)
    }
    func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func package(id: String = "known", file: String = "new", installed: String = "old", degree: String = "all", status: Int = 0, url: String = "https://uires.w.163.com/file/addon/example/addon.zip", size: Int = 10) -> [String: Any] {
        ["sn": id, "name": "Example", "folders": ["Example"], "detail_sn": installed, "local_version": "1.0", "match_degree": degree, "local_status": status,
         "latest_version": ["sn": file, "version": "2.0", "release_type": 1, "file_path": url, "size": size]]
    }
    func scanResponse(_ entries: [[String: Any]]) throws -> Data { try json(["code": 0, "result": ["installed": entries, "unknown": []]]) }
    func target() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Interface/AddOns")
        let folder = root.appendingPathComponent("Example")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("## Title: Example\n## Version: 1.0\nCode.lua".utf8).write(to: folder.appendingPathComponent("Example.toc"))
        try Data("local x=1".utf8).write(to: folder.appendingPathComponent("Code.lua"))
        return root
    }
    func testPublicSearchHasOfficialParametersAndNoCredentials() async throws {
        DDStub.handler = { r in
            XCTAssertEqual(r.url?.host, "uiapi.w.163.com"); XCTAssertEqual(r.httpMethod, "POST")
            let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(Set(query.map(\.name)), Set(["ef", "uf", "ts", "ab"]))
            XCTAssertTrue(query.allSatisfy { $0.value == "0" })
            XCTAssertNil(r.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
            return (200, try self.json(["code": 0, "count": 1, "result": [self.package()]]))
        }
        let page = try await client().search("中文 & +", gameType: 2)
        XCTAssertEqual(page.result?.first?.latest_version?.version, "2.0")
        XCTAssertEqual(DDClient.gameType(.retail), 10001)
    }
    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testPopularUsesEmptySearchAndSelectedRankingAndPagination() async throws {
        for sort in DDSort.allCases {
            DDStub.handler = { request in
                let body = try self.requestJSON(request)
                XCTAssertEqual(body["name"] as? String, "")
                XCTAssertEqual(body["origin"] as? String, "all")
                XCTAssertEqual(body["sort_type"] as? Int, sort.rawValue)
                XCTAssertEqual(body["game_type"] as? Int, 10001)
                XCTAssertEqual(body["page"] as? Int, 2)
                XCTAssertEqual(body["size"] as? Int, 20)
                return (200, try self.json(["code": 0, "count": 0, "result": []]))
            }
            _ = try await client().search("", gameType: 10001, page: 2, sort: sort)
        }
        XCTAssertEqual(DDSort.weekly.rawValue, 4)
        let addon = try JSONDecoder().decode(DDAddon.self, from: json(["sn": "a", "name": "示例", "week_download": 20, "month_download": 50, "total_download": 100]))
        XCTAssertEqual(addon.downloads(for: .weekly), 20)
        XCTAssertEqual(addon.downloads(for: .monthly), 50)
        XCTAssertEqual(addon.downloads(for: .total), 100)
    }
    func testFailedAPIIsNotAnEmptySuccess() async throws {
        DDStub.handler = { _ in (200, Data("{\"code\":403,\"msg\":\"需要登录\"}".utf8)) }
        do { _ = try await client().scan(tocs: [:], flavor: .time); XCTFail("Expected failure") } catch { XCTAssertTrue(error.localizedDescription.contains("需要登录")) }
    }
    func testScanUsesTOCMD5AndFindsUpdateWithoutCachedStrategy() async throws {
        let root = try target(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let hash = try DDClient.tocs(in: [root.appendingPathComponent("Example")])
        XCTAssertEqual(hash.keys.sorted(), ["Example/Example.toc"])
        XCTAssertEqual(hash.values.first?.count, 32)
        DDStub.handler = { r in
            XCTAssertEqual(r.url?.path, "/addon/scan")
            return (200, try self.scanResponse([self.package()]))
        }
        let result = try await client().check(target: root, addons: AddonScanner.scan(root, flavor: .time), flavor: .time)
        let item = try XCTUnwrap(result["Example"])
        XCTAssertEqual(item.label, "DD 版本可更新"); XCTAssertEqual(item.latest, "2.0"); XCTAssertNotNil(item.ddSelection)
        try Data("local changed=2".utf8).write(to: root.appendingPathComponent("Example/Code.lua"))
        do { _ = try await client().refresh(try XCTUnwrap(item.ddSelection), target: root, expected: item.expected); XCTFail("Expected changed-file refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
    }
    func testPartialOrAmbiguousMatchCannotUpdate() async throws {
        let root = try target(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let addons = try AddonScanner.scan(root, flavor: .time)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(degree: "part", status: 1)])) }
        let partial = try await client().check(target: root, addons: addons, flavor: .time)
        XCTAssertNil(partial["Example"]?.ddSelection)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(id: "one"), self.package(id: "two")])) }
        let ambiguous = try await client().check(target: root, addons: addons, flavor: .time)
        XCTAssertEqual(ambiguous["Example"]?.label, "DD 匹配冲突"); XCTAssertNil(ambiguous["Example"]?.ddSelection)
    }
    func testFileIdentityDeterminesLatestAndReleaseChangesAbort() async throws {
        let root = try target(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let addons = try AddonScanner.scan(root, flavor: .time)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(installed: "new")])) }
        let current = try await client().check(target: root, addons: addons, flavor: .time)
        XCTAssertEqual(current["Example"]?.label, "已是最新 · DD（TOC）"); XCTAssertEqual(current["Example"]?.isCurrent, true); XCTAssertNil(current["Example"]?.ddSelection)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package()])) }
        let old = try await client().check(target: root, addons: addons, flavor: .time)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(file: "newer")])) }
        do { _ = try await client().refresh(try XCTUnwrap(old["Example"]?.ddSelection), target: root, expected: old["Example"]!.expected); XCTFail("Expected changed-release refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("版本发生变化")) }
    }
    func testCDNAllowlist() {
        XCTAssertTrue(DDRedirectPolicy.allowsCDN(URL(string: "https://uires.w.163.com/file/addon/test/addon.zip")!))
        for text in ["http://uires.w.163.com/file/a.zip", "https://uires.w.163.com.evil.test/file/a.zip", "https://user@uires.w.163.com/file/a.zip", "https://uires.w.163.com:443/file/a.zip", "https://uires.w.163.com/other/a.zip", "https://uires.w.163.com/file/a.zip?token=x"] {
            XCTAssertFalse(DDRedirectPolicy.allowsCDN(URL(string: text)!), text)
        }
    }
    func testDownloadChecksSizeAndDisallowsMissingURL() async throws {
        var p = package(size: 3)
        let selected = try DDSelection(package: try JSONDecoder().decode(DDScanPackage.self, from: json(p)), flavor: .time)
        DDStub.handler = { r in
            XCTAssertEqual(r.url?.host, "uires.w.163.com")
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(r.value(forHTTPHeaderField: "x-w163-token"))
            return (200, Data("zip".utf8))
        }
        let file = try await client().download(selected); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("zip".utf8))
        DDStub.handler = { _ in (200, Data("zi".utf8)) }
        do { _ = try await client().download(selected); XCTFail("Expected truncated download refusal") } catch { }
        p = package(url: "")
        let missing = try DDSelection(package: try JSONDecoder().decode(DDScanPackage.self, from: json(p)), flavor: .time)
        do { _ = try await client().download(missing); XCTFail("Expected missing URL refusal") } catch { }
    }
    func testArchiveIdentityMustMatchSelectedReleaseAndFolders() async throws {
        let root = try target(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let selected = try DDSelection(package: try JSONDecoder().decode(DDScanPackage.self, from: json(package())), flavor: .time)
        let preview = InstallPreview(staging: root, folders: [root.appendingPathComponent("Example")], replacing: ["Example"])
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(installed: "new")])) }
        try await client().verify(preview, selection: selected)
        DDStub.handler = { _ in (200, try self.scanResponse([self.package(installed: "wrong")])) }
        do { try await client().verify(preview, selection: selected); XCTFail("Expected mismatched release refusal") } catch { }
    }
    func testDDReceiptFollowsInstallOverwriteAndBackupRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let library = Library(backupRoot: root.appendingPathComponent("Backups"))
        let archive = try XCTUnwrap(Bundle.module.url(forResource: "Deflate", withExtension: "zip", subdirectory: "Fixtures"))
        let preview = try library.prepare(archive, target: target, flavor: .time); defer { library.discard(preview) }
        let selected = try DDSelection(package: try JSONDecoder().decode(DDScanPackage.self, from: json(package())), flavor: .time)
        try library.install(preview, target: target, dd: selected)
        XCTAssertEqual(try DDTracking.receipts(in: target).first?.fileID, "new")
        let snapshot = try library.backup(target, reason: "test")
        try library.install(preview, target: target)
        XCTAssertTrue(try DDTracking.receipts(in: target).isEmpty)
        try library.restore(snapshot, target: target)
        XCTAssertEqual(try DDTracking.receipts(in: target).count, 1)
        try library.uninstall(["HelloAzeroth"], target: target)
        XCTAssertTrue(try DDTracking.receipts(in: target).isEmpty)
    }
    func testNewDestinationCreatedAfterPreviewIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let library = Library(backupRoot: root.appendingPathComponent("Backups"))
        let archive = try XCTUnwrap(Bundle.module.url(forResource: "Deflate", withExtension: "zip", subdirectory: "Fixtures"))
        let preview = try library.prepare(archive, target: target, flavor: .time); defer { library.discard(preview) }
        let selected = try DDSelection(package: JSONDecoder().decode(DDScanPackage.self, from: json(package())), flavor: .time)
        let newFolder = target.appendingPathComponent("HelloAzeroth")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data("new local data".utf8).write(to: newFolder.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try library.install(preview, target: target, expected: [:], dd: selected))
        XCTAssertEqual(try Data(contentsOf: newFolder.appendingPathComponent("keep.txt")), Data("new local data".utf8))
    }
    func testLiveDDDownloadAndInstallOnTemporaryCopy() async throws {
        guard ProcessInfo.processInfo.environment["AZEROTH_DD_LIVE_TEST"] == "1" else { throw XCTSkip("Explicit live test only") }
        // 固定公开旧版本作为测试种子，不读取或修改用户的游戏插件。
        let seeds: [(String, String, String, Int)] = [
            ("52a6a9589c9c46988d200373ae2f25d9", "v12.1.0", "https://uires.w.163.com/file/52a6a9589c9c46988d200373ae2f25d9/!BugGrabber-v12.1.0.zip", 11093),
            ("b5ba1d2daddf4a2988e1367889799bb9", "3.90", "https://uires.w.163.com/file/addon/o4hU8oN8waeQZyfrBkqecf4O7PU52uF2/addon.zip", 1074004)
        ]
        for (fileID, version, url, size) in seeds {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("Interface/AddOns")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let client = DDClient(), library = Library(backupRoot: root.appendingPathComponent("Backups"))
            var seed = package(file: fileID, url: url, size: size)
            var seedVersion = try XCTUnwrap(seed["latest_version"] as? [String: Any]); seedVersion["version"] = version
            seed["latest_version"] = seedVersion
            let seedSelection = try DDSelection(package: JSONDecoder().decode(DDScanPackage.self, from: json(seed)), flavor: .time)
            let oldArchive = try await client.download(seedSelection); defer { try? FileManager.default.removeItem(at: oldArchive) }
            let oldPreview = try library.prepare(oldArchive, target: target, flavor: .time); defer { library.discard(oldPreview) }
            let names = oldPreview.folders.map(\.lastPathComponent).sorted()
            for folder in oldPreview.folders { try FileManager.default.copyItem(at: folder, to: target.appendingPathComponent(folder.lastPathComponent)) }
            let addons = try AddonScanner.scan(target, flavor: .time)
            let items = try await client.check(target: target, addons: addons, flavor: .time)
            let update = try XCTUnwrap(items[names[0]]), selection = try XCTUnwrap(update.ddSelection)
            let refreshed = try await client.refresh(selection, target: target, expected: update.expected)
            let archive = try await client.download(refreshed); defer { try? FileManager.default.removeItem(at: archive) }
            let preview = try library.prepare(archive, target: target, flavor: .time); defer { library.discard(preview) }
            try await client.verify(preview, selection: refreshed)
            try library.install(preview, target: target, expected: update.expected, dd: refreshed)
            XCTAssertEqual(try DDTracking.receipts(in: target).first?.fileID, selection.version.sn)
            XCTAssertEqual(try DDTracking.receipts(in: target).first?.folders.count, names.count)
            XCTAssertEqual(try library.snapshots(for: target).count, 1)
            let result = try await client.check(target: target, addons: AddonScanner.scan(target, flavor: .time), flavor: .time)
            XCTAssertTrue(result.values.allSatisfy { $0.label == "已是最新 · DD（TOC）" && $0.ddSelection == nil })
            print("LIVE DD: \(selection.package.name) \(selection.package.local_version ?? "unknown") -> \(selection.version.version), \(names.count) folders; download, verify, backup, install, recheck passed")
        }
    }
}
