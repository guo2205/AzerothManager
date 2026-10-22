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
    func entry(_ id: String, folder: String = "Example", game: Int = 2) -> [String: Any] {
        ["sn": id, "name": "Example", "game_types": [game], "latest_version": ["sn": "file-new", "version": "2.0", "release_type": 1, "folders": [folder], "file_path": ""]]
    }
    func response(_ entries: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["code": 0, "count": entries.count, "result": entries]) }
    func testPublicSearchAndNoCredentials() async throws {
        DDStub.handler = { request in
            XCTAssertEqual(request.url?.host, "uiapi.w.163.com")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            return (200, try self.response([self.entry("one")]))
        }
        let page = try await client().search("中文 & +", gameType: 2)
        XCTAssertEqual(page.result?.first?.latest_version?.version, "2.0")
        XCTAssertEqual(DDClient.gameType(.retail), 10001)
        XCTAssertEqual(DDClient.gameType(.time), 2)
    }
    func testFailedAPIIsNotAnEmptySuccess() async throws {
        DDStub.handler = { _ in (200, Data("{\"code\":403,\"msg\":\"需要登录\"}".utf8)) }
        do { _ = try await client().search("Example", gameType: 2); XCTFail("Expected failure") } catch { XCTAssertTrue(error.localizedDescription.contains("需要登录")) }
    }
    func testExactMappingAmbiguityWrongBranchAndStaleCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[{\"sn\":\"known\",\"name\":\"Example\",\"folders\":[\"Example\"],\"local_version\":\"1.0\",\"latest_version\":{\"version\":\"1.0\"}}]".write(to: root.appendingPathComponent("addon_strategy.txt"), atomically: true, encoding: .utf8)
        let addon = Addon(folder: "Example", title: "Example", version: "1.0", author: "", notes: "", interface: "", dependencies: "", tocNames: "")
        DDStub.handler = { _ in (200, try self.response([self.entry("other"), self.entry("known")])) }
        let updates = try await client().check(target: root, addons: [addon], flavor: .time)
        XCTAssertEqual(updates["Example"]?.latest, "2.0")
        XCTAssertEqual(updates["Example"]?.label, "版本不同 · DD")
        XCTAssertNil(updates["Example"]?.selection)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(updates["Example"]?.externalURL), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "sn" })?.value, "known")
        DDStub.handler = { _ in (200, try self.response([self.entry("known", game: 10001)])) }
        let wrong = try await client().check(target: root, addons: [addon], flavor: .time)
        XCTAssertNil(wrong["Example"]?.externalURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("addon_strategy.txt"))
        DDStub.handler = { _ in (200, try self.response([self.entry("one"), self.entry("two")])) }
        let ambiguous = try await client().check(target: root, addons: [addon], flavor: .time)
        XCTAssertEqual(ambiguous["Example"]?.label, "DD 存在多个匹配")
    }
    func testVersionStringsDoNotInventChronology() {
        XCTAssertEqual(DDClient.status(local: "v2.0", latest: "2.0"), "版本号一致 · DD")
        XCTAssertEqual(DDClient.status(local: "3.0-local-fix", latest: "2.0"), "版本不同 · DD")
    }
}
