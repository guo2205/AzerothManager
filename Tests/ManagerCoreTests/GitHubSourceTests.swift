import XCTest
import CryptoKit
@testable import ManagerCore

private final class StubGitHubProtocol: URLProtocol {
    static var responseData = Data()
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Length": String(Self.responseData.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GitHubSourceTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubGitHubProtocol.responseData = Data(); StubGitHubProtocol.status = 200
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func client() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubGitHubProtocol.self]
        return GitHubClient(configuration: config)
    }
    func release(id: Int = 1, tag: String = "v1", published: String = "2026-01-01T00:00:00Z", prerelease: Bool = false, draft: Bool = false, size: Int = 10, digest: String? = nil, url: String = "https://github.com/Author/Addon/releases/download/v1/Addon.zip") throws -> GitHubRelease {
        var asset: [String: Any] = ["id": id * 10, "name": "Addon.zip", "size": size, "browser_download_url": url]
        if let digest { asset["digest"] = digest }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "tag_name": tag, "name": tag, "body": "Notes", "draft": draft, "prerelease": prerelease, "published_at": published, "assets": [asset]])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
    func selection(_ release: GitHubRelease) throws -> GitHubSelection {
        GitHubSelection(repository: try GitHubRepository("Author/Addon"), release: release, asset: release.assets[0], flavor: .time)
    }
    func archive() throws -> Data {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Deflate", withExtension: "zip", subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }
    func testRepositoryInputRejectsUntrustedURLsAndPaths() throws {
        XCTAssertEqual(try GitHubRepository(" https://github.com/Author/Addon.git/ ").fullName, "Author/Addon")
        XCTAssertEqual(try GitHubRepository("Author/Addon").fullName, "Author/Addon")
        for input in ["http://github.com/a/b", "https://evil.com/a/b", "https://github.com@evil.com/a/b", "https://user@github.com/a/b", "a/../b", "a/..", "a/b/releases", "https://github.com/a/b?token=secret", "https://github.com/a/b#readme", "https://github.com:443/a/b"] {
            XCTAssertThrowsError(try GitHubRepository(input), input)
        }
    }
    func testReleaseDiscoveryFiltersAndSorts() async throws {
        let releases = try [release(id: 1), release(id: 2, published: "2026-02-01T00:00:00Z"), release(id: 3, prerelease: true), release(id: 4, draft: true)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        StubGitHubProtocol.responseData = try encoder.encode(releases)
        let found = try await client().releases(in: GitHubRepository("Author/Addon"))
        XCTAssertEqual(found.map(\.id), [2, 1])
    }
    func testRateLimitAndNotFoundReported() async throws {
        for status in [403, 404, 429, 500] {
            StubGitHubProtocol.status = status
            do { _ = try await client().releases(in: GitHubRepository("Author/Addon")); XCTFail("Should fail") }
            catch { XCTAssertTrue(error is ManagerError) }
        }
    }
    func testMalformedReleaseDataReported() async throws {
        StubGitHubProtocol.responseData = Data("not json".utf8)
        do { _ = try await client().releases(in: GitHubRepository("Author/Addon")); XCTFail("Should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("格式")) }
    }
    func testDownloadChecksDigestAndExactLength() async throws {
        let data = try archive(), digest = SHA256.hash(data: try archive()).map { String(format: "%02x", $0) }.joined()
        StubGitHubProtocol.responseData = data
        let good = try release(size: data.count, digest: "sha256:" + digest)
        let file = try await client().download(selection(good))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)
        for invalid in try [release(size: data.count, digest: "sha256:bad"), release(size: data.count - 1), release(size: data.count + 1)] {
            do { _ = try await client().download(selection(invalid)); XCTFail("Should fail") }
            catch { XCTAssertTrue(error is ManagerError) }
        }
    }
    func testDownloadRejectsExternalAndOversizedAssets() async throws {
        for invalid in try [release(url: "https://evil.com/file.zip"), release(url: "https://github.com/Other/Addon/releases/download/v1/Addon.zip"), release(size: GitHubClient.maxArchiveBytes + 1)] {
            do { _ = try await client().download(selection(invalid)); XCTFail("Should fail") }
            catch { XCTAssertTrue(error is ManagerError) }
        }
    }
    func testCancelledRequestDoesNotReturnDownload() async throws {
        StubGitHubProtocol.responseData = try archive()
        let chosen = try selection(release(size: try archive().count))
        let client = client()
        let task = Task { try await client.download(chosen) }
        task.cancel()
        do { let file = try await task.value; try? FileManager.default.removeItem(at: file); XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    func testSourceReceiptsFollowInstallManualReplacementAndRestore() throws {
        let target = root.appendingPathComponent("Game/Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let library = Library(backupRoot: root.appendingPathComponent("Backups")), zip = root.appendingPathComponent("test.zip")
        try archive().write(to: zip)
        let preview = try library.prepare(zip, target: target, flavor: .time)
        defer { library.discard(preview) }
        try library.install(preview, target: target, source: selection(release()))
        let record = try XCTUnwrap(SourceTracking.receipts(in: target).first)
        XCTAssertTrue(try SourceTracking.isUnchanged(record, in: target))
        let snapshot = try library.backup(target, reason: "tracked")
        try Data("-- local edit".utf8).write(to: target.appendingPathComponent("HelloAzeroth/main.lua"))
        XCTAssertFalse(try SourceTracking.isUnchanged(record, in: target))
        try library.install(preview, target: target)
        XCTAssertTrue(try SourceTracking.receipts(in: target).isEmpty)
        try library.restore(snapshot, target: target)
        XCTAssertEqual(try SourceTracking.receipts(in: target).first?.id, record.id)
        XCTAssertTrue(try SourceTracking.isUnchanged(record, in: target))
        try library.uninstall(["HelloAzeroth"], target: target)
        XCTAssertTrue(try SourceTracking.receipts(in: target).isEmpty)
    }
    func testRepublishedAssetUnderSameTagDetected() throws {
        let dir = root.appendingPathComponent("Demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = try release()
        let record = try SourceReceipt(selection: selection(original), folders: [dir])
        let asset = GitHubAsset(id: 999, name: original.assets[0].name, size: 10, browserDownloadURL: original.assets[0].browserDownloadURL, digest: nil)
        let republished = GitHubRelease(id: original.id, tagName: original.tagName, name: original.name, body: nil, draft: false, prerelease: false, publishedAt: original.publishedAt, assets: [asset])
        XCTAssertEqual(record.newerRelease(in: [republished])?.id, original.id)
        XCTAssertNil(record.newerRelease(in: [original]))
    }
    func testLiveGitHubDownloadAndStagedInstall() async throws {
        guard ProcessInfo.processInfo.environment["AZEROTH_LIVE_GITHUB"] == "1" else { throw XCTSkip("Opt-in live network smoke test") }
        let github = GitHubClient(), repository = try GitHubRepository("BigWigsMods/BigWigs")
        let releases = try await github.releases(in: repository)
        let release = try XCTUnwrap(releases.first { !$0.zipAssets.isEmpty })
        let asset = try XCTUnwrap(release.zipAssets.first)
        let chosen = GitHubSelection(repository: repository, release: release, asset: asset, flavor: .retail)
        let file = try await github.download(chosen)
        defer { try? FileManager.default.removeItem(at: file) }
        let target = root.appendingPathComponent("LiveDemo/Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let library = Library(backupRoot: root.appendingPathComponent("LiveBackups"))
        let preview = try library.prepare(file, target: target, flavor: .retail)
        defer { library.discard(preview) }
        XCTAssertFalse(preview.folders.isEmpty)
        try library.install(preview, target: target, source: chosen)
        XCTAssertFalse(try AddonScanner.scan(target, flavor: .retail).isEmpty)
        let receipt = try XCTUnwrap(SourceTracking.receipts(in: target).first)
        XCTAssertTrue(try SourceTracking.isUnchanged(receipt, in: target))
        print("LIVE_GITHUB_OK", repository.fullName, release.tagName, asset.name, preview.folders.count)
    }
    func testNewerReleaseUsesPublicationAndIDInsteadOfVersionString() throws {
        let dir = root.appendingPathComponent("Demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = try SourceReceipt(selection: selection(release(id: 5, tag: "custom-version")), folders: [dir])
        let older = try release(id: 1, tag: "v999", published: "2025-01-01T00:00:00Z")
        XCTAssertNil(record.newerRelease(in: [older]))
        let next = try release(id: 6, tag: "release-special", published: "2026-02-01T00:00:00Z")
        XCTAssertEqual(record.newerRelease(in: [next])?.id, 6)
    }
}
