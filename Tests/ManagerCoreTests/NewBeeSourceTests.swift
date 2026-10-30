import XCTest
@testable import ManagerCore

private final class NewBeeProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handle(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class NewBeeSourceTests: XCTestCase {
    func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func shareObject() -> [String: Any] {
        ["t_id": 534, "t_title": "NDui test", "t_sharecode": "867253", "t_versionid": 4, "t_update_time": 123, "is_content_access": true,
         "t__known_plug": "[{\"name\":\"Demo\",\"id\":\"1\",\"updateType\":1}]", "wtflist": [], "t_material_list": "[]", "t_font_list": "[]", "t_un_known_list": "[]"]
    }
    func client() -> NewBeeClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NewBeeProtocol.self]
        return NewBeeClient(configuration: config)
    }
    func testShareSchemaAndAccessAreNotInferredFromFreePrice() throws {
        var object = shareObject(); object["is_content_access"] = false; object["price"] = 0
        let share = try JSONDecoder().decode(NewBeeShare.self, from: json(object))
        XCTAssertFalse(share.accessible); XCTAssertEqual(share.plugins.first?.name, "Demo")
        object["t_un_known_list"] = "[{\"name\":\"Unknown\"}]"
        XCTAssertThrowsError(try JSONDecoder().decode(NewBeeShare.self, from: json(object)))
    }
    func testResourcesRejectForeignOriginsAndTraversal() throws {
        for value in ["https://evil.test/x", "https://cdn8.newbeebox.com.evil.test/x", "https://user@cdn8.newbeebox.com/x", "https://cdn8.newbeebox.com:444/x", "file:///tmp/x", "../x", "%252e%252e/x", "a\\b", "x#fragment"] {
            XCTAssertThrowsError(try NewBeeClient.resourceURL(value), value)
        }
        XCTAssertEqual(try NewBeeClient.resourceURL("mod_file/1/中文 文件.zip").host, "cdn8.newbeebox.com")
        XCTAssertThrowsError(try JSONDecoder().decode(ConfigurationRole.self, from: json(["account": "../x", "realm": "R", "name": "N"])))
    }
    func testHashInDeclaredFilenameIsEncodedAsPath() throws {
        let name = "#Details.123"
        let file = try JSONDecoder().decode(NewBeePluginFile.self, from: json(["release_type": 1, "file_display_name": name, "file_name": name, "file_url": "https://cdn8.newbeebox.com/mod_file/1/" + name, "file_folders": ["Details"]]))
        let url = try file.downloadURL(pluginID: 1)
        XCTAssertNil(url.fragment); XCTAssertTrue(url.absoluteString.contains("%23Details"))
        XCTAssertThrowsError(try file.downloadURL(pluginID: 2))
    }
    func testTemporaryOAuthSessionAndCredentialIsolation() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
        NewBeeProtocol.handle = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            switch request.url!.path {
            case "/auth/oauth/wechat/getAuthUrl":
                return try self.json(["code": 1, "data": ["qrCode": "data:image/png;base64," + png, "resultId": "test-challenge", "expiresAt": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000]])
            case "/auth/oauth/getResult": return try self.json(["code": 1, "data": ["oAuthCode": "test-code"]])
            case "/auth/connect/token":
                let body = String(data: self.body(request), encoding: .utf8) ?? ""
                XCTAssertFalse(body.contains("offline_access")); XCTAssertTrue(body.contains("scope=openid"))
                XCTAssertTrue(body.contains("grant_type=oauth_code"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                return try self.json(["access_token": "temporary-test", "refresh_token": "discard-this"])
            case "/bannerserver/ShareCode/Get":
                XCTAssertEqual(request.url?.host, "api.next.newbeebox.com"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return try self.json(["code": 1, "data": ["gameId": 1, "moduleType": 4, "moduleId": 534]])
            case "/v3/share_config/details_aps":
                XCTAssertEqual(request.url?.host, "api.newbeebox.com"); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer temporary-test")
                return try self.json(["code": 1, "data": [self.shareObject()]])
            default:
                XCTAssertEqual(request.url?.host, "cdn8.newbeebox.com"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return Data("resource".utf8)
            }
        }
        let api = client(); _ = try await api.beginLogin(); try await api.waitForLogin()
        let share = try await api.share(code: "867253", flavor: .time)
        XCTAssertEqual(share.id, 534)
        _ = try await api.downloadResource("test.zip")
        await api.logout()
        do { _ = try await api.share(code: "867253", flavor: .time); XCTFail("Logged-out session cannot read protected details") } catch {}
    }
    func testOfficialMislabelledJPEGAndInvalidQRCode() async throws {
        for header in [[UInt8]([255, 216, 255, 224]), [UInt8]([1, 2, 3, 4])] {
            NewBeeProtocol.handle = { _ in
                try self.json(["code": 1, "data": ["qrCode": "data:image/png;base64," + Data(header).base64EncodedString(), "resultId": "test", "expiresAt": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000]])
            }
            do { let value = try await client().beginLogin(); XCTAssertEqual(value.image, Data(header)); XCTAssertEqual(header.first, 255) }
            catch { XCTAssertEqual(header.first, 1) }
        }
    }
    func testInvalidChunkSizesStopIndexDownload() async throws {
        NewBeeProtocol.handle = { request in
            if request.url!.path.hasSuffix("/meta") { return try self.json(["code": 1, "data": ["fileCount": 1, "totalSize": 1, "indexType": 1]]) }
            return try self.json(["code": 1, "data": ["files": [["relPath": "test.ttf", "totalSize": -1, "fullHash": "test", "chunks": []]], "hasMore": false]])
        }
        do { _ = try await client().indexFiles("test"); XCTFail("Negative file size must be rejected") } catch {}
    }
}
