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
        XCTAssertEqual(item.label, "DD 版本可更新"); XCTAssertEqual(item.packageInfo?.latestVersion, "2.0"); XCTAssertNotNil(item.ddSelection)
        try Data("local changed=2".utf8).write(to: root.appendingPathComponent("Example/Code.lua"))
        do { _ = try await client().refresh(try XCTUnwrap(item.ddSelection), target: root, expected: item.expected); XCTFail("Expected changed-file refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
    }
    private func targetWithModule() throws -> URL {
        let root = try target(), helper = root.appendingPathComponent("Example_Helper")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try Data("## Title: Helper\n## Version: 1.6\n## Dependencies: Example".utf8).write(to: helper.appendingPathComponent("Example_Helper.toc"))
        return root
    }
    private func modulePackage(installed: String, latest: String, currentFile: String, latestFile: String) -> [String: Any] {
        var p = package(file: latestFile, installed: currentFile)
        p["name"] = "Example 整合包"; p["folders"] = ["Example", "Example_Helper"]; p["local_version"] = installed
        var version = p["latest_version"] as! [String: Any]; version["version"] = latest; p["latest_version"] = version
        return p
    }
    func testModuleVersionDoesNotBecomePackageOrDependencyVersion() async throws {
        let root = try targetWithModule(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let addons = try AddonScanner.scan(root, flavor: .time)
        DDStub.handler = { _ in (200, try self.scanResponse([self.modulePackage(installed: "3.93", latest: "3.93", currentFile: "same", latestFile: "same")])) }
        let result = try await client().check(target: root, addons: addons, flavor: .time)
        let module = try XCTUnwrap(result["Example_Helper"]), info = try XCTUnwrap(module.packageInfo)
        XCTAssertEqual(addons.first(where: { $0.folder == "Example_Helper" })?.version, "1.6")
        XCTAssertEqual(addons.first(where: { $0.folder == "Example_Helper" })?.dependencies, "Example")
        XCTAssertEqual(info.installedVersion, "3.93"); XCTAssertEqual(info.latestVersion, "3.93")
        XCTAssertEqual(info.name, "Example 整合包"); XCTAssertTrue(info.containsMultipleFolders)
        XCTAssertTrue(module.isCurrent); XCTAssertNil(module.ddSelection)
        XCTAssertEqual(module.label, "所属包已是最新（TOC）")
    }
    func testModuleUpdateUsesPackageFileIdentityAndRetainsBothPackageVersions() async throws {
        let root = try targetWithModule(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let addons = try AddonScanner.scan(root, flavor: .time)
        DDStub.handler = { _ in (200, try self.scanResponse([self.modulePackage(installed: "3.93", latest: "3.94", currentFile: "old", latestFile: "new")])) }
        let result = try await client().check(target: root, addons: addons, flavor: .time)
        let parent = try XCTUnwrap(result["Example"]), module = try XCTUnwrap(result["Example_Helper"])
        XCTAssertEqual(module.packageInfo?.installedVersion, "3.93")
        XCTAssertEqual(module.packageInfo?.latestVersion, "3.94")
        XCTAssertEqual(module.packageInfo?.projectID, parent.packageInfo?.projectID)
        XCTAssertEqual(module.ddSelection?.version.sn, "new")
        XCTAssertEqual(module.ddSelection?.package.folders, ["Example", "Example_Helper"])
        XCTAssertEqual(module.label, "所属包可更新"); XCTAssertFalse(module.isCurrent)
        XCTAssertEqual(addons.first(where: { $0.folder == "Example_Helper" })?.version, "1.6")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let client = DDClient(), library = Library(backupRoot: root.appendingPathComponent("Backups"))
        for (fileID, version, url, size) in seeds {
            var seed = package(file: fileID, url: url, size: size)
            var seedVersion = try XCTUnwrap(seed["latest_version"] as? [String: Any]); seedVersion["version"] = version
            seed["latest_version"] = seedVersion
            let seedSelection = try DDSelection(package: JSONDecoder().decode(DDScanPackage.self, from: json(seed)), flavor: .time)
            let oldArchive = try await client.download(seedSelection); defer { try? FileManager.default.removeItem(at: oldArchive) }
            let oldPreview = try library.prepare(oldArchive, target: target, flavor: .time); defer { library.discard(oldPreview) }
            for folder in oldPreview.folders { try FileManager.default.copyItem(at: folder, to: target.appendingPathComponent(folder.lastPathComponent)) }
        }
        let addons = try AddonScanner.scan(target, flavor: .time)
        let items = try await client.check(target: target, addons: addons, flavor: .time)
        let groups = InstalledUpdates.packages(addons, updates: items)
        let jobs = groups.compactMap { row -> PackageUpdateJob? in
            guard let update = row.update, let selection = update.ddSelection else { return nil }
            return PackageUpdateJob(selection: selection, expected: update.expected)
        }
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(addons.count, 11)
        let result = await PackageBatch.run(jobs, operation: { job in
            let refreshed = try await client.refresh(job.selection, target: target, expected: job.expected)
            let archive = try await client.download(refreshed); defer { try? FileManager.default.removeItem(at: archive) }
            let preview = try library.prepare(archive, target: target, flavor: .time); defer { library.discard(preview) }
            try await client.verify(preview, selection: refreshed)
            try library.install(preview, target: target, expected: job.expected, dd: refreshed)
        })
        XCTAssertEqual(result.succeeded, 2, result.outcomes.compactMap(\.error).joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0); XCTAssertFalse(result.cancelled)
        let receipts = try DDTracking.receipts(in: target)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(try library.snapshots(for: target).count, 2)
        let checked = try await client.check(target: target, addons: AddonScanner.scan(target, flavor: .time), flavor: .time)
        let installedFolders = Set(receipts.flatMap(\.folders))
        XCTAssertFalse(installedFolders.isEmpty)
        for folder in installedFolders {
            XCTAssertEqual(checked[folder]?.isCurrent, true, folder + ": " + (checked[folder]?.label ?? "missing"))
            XCTAssertNil(checked[folder]?.ddSelection)
        }
        // 新版移除的旧目录保持原样，单独显示未识别；不为了让测试全绿而删除用户文件。
        let retainedOldFolders = Set(checked.keys).subtracting(installedFolders)
        XCTAssertTrue(retainedOldFolders.isSubset(of: Set(addons.map(\.folder))))
        print("LIVE DD BATCH: 11 old folders grouped into 2 jobs; 2 successful updates and snapshots, \(installedFolders.count) installed folders current, \(retainedOldFolders.count) obsolete folders preserved")
    }
}
