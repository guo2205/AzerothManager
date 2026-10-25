import XCTest
import JavaScriptCore
@testable import ManagerCore

private final class ShareProtocol: URLProtocol {
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
final class DDShareTests: XCTestCase {
    let sn = "da34464e69804c11bfd87fd52fc691d3"
    func client() -> DDShareClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ShareProtocol.self]
        return DDShareClient(configuration: config)
    }
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func detail(gameType: Int = 2) -> [String: Any] {
        ["sn": sn, "title": "露露 NDui", "game_type": gameType, "share_code": "297986", "scope": "public", "need_buy": false, "need_anchor_vip": false, "wtf": ["size": 100, "url": "", "accounts": []]]
    }
    func testPublicSearchUsesOfficialParametersWithoutCredentials() async throws {
        ShareProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "uiapi.w.163.com")
            XCTAssertEqual(request.url?.path, "/share/list")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "search_text" }?.value, "297986 & 中文")
            XCTAssertEqual(items.first { $0.name == "sort_type" }?.value, "week_download")
            XCTAssertEqual(items.first { $0.name == "game_type" }?.value, "2")
            return (200, try self.data(["code": 0, "result": ["count": 1, "shares": [self.detail()]]]))
        }
        let page = try await client().search("297986 & 中文", flavor: .time)
        XCTAssertEqual(page.shares.first?.sn, sn)
    }
    func testFreeDetailWithoutDownloadMustRemainUnavailable() async throws {
        ShareProtocol.handler = { _ in (200, try self.data(["code": 0, "result": self.detail()])) }
        let result = try await client().detail(sn, flavor: .time)
        XCTAssertFalse(result.requiresPurchase); XCTAssertFalse(result.hasConfigurationDownload)
        XCTAssertEqual(result.share_code, "297986")
        do { _ = try await client().detail(sn, flavor: .retail); XCTFail("Should reject other client") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不匹配")) }
    }
    func testLoginAndMalformedResponseAreNotAnEmptySuccess() throws {
        XCTAssertThrowsError(try DDShareClient.decodeDetail(data(["code": 412, "msg": "用户登陆失败"]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("登录"))
        }
        XCTAssertThrowsError(try DDShareClient.decodeDetail(Data("invalid".utf8)))
    }
    func testShareIDsCannotCreateExternalAPIRequests() throws {
        for value in ["", "297986", "https://evil.test/x", sn + "?token=x", "../share"] {
            XCTAssertThrowsError(try DDShareClient.detailURL(value))
        }
        let website = DDShareClient.website(sn: sn, gameType: 2)
        XCTAssertEqual(website.host, "dd.163.com")
        XCTAssertTrue(URLComponents(url: website, resolvingAgainstBaseURL: false)!.queryItems![0].value!.contains("#/config-share?sn=" + sn))
    }
    func testWebAuthenticationKeepsTokenInsideOfficialRequest() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var calls = [], output = null;
        var endpoint = 'https://uiapi.w.163.com/share/detail?sn=\(sn)';
        var fetch = async (url, options) => {
            calls.push({url, options});
            return {ok: true, text: async () => JSON.stringify(url.includes('/login/')
                ? {code: 0, result: {token: 'test-session-only'}}
                : {code: 0, result: {sn: 'sample'}})};
        };
        """)
        context.evaluateScript("(async () => {\(DDShareClient.authenticatedDetailScript)})().then(value => output = value)")
        XCTAssertEqual(context.evaluateScript("calls.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("calls[1].options.headers['x-w163-token']")?.toString(), "test-session-only")
        XCTAssertEqual(context.evaluateScript("calls.every(x => x.options.redirect === 'error')")?.toBool(), true)
        let output = try XCTUnwrap(context.objectForKeyedSubscript("output")?.toString())
        XCTAssertFalse(output.contains("test-session-only"))
        XCTAssertTrue(output.contains("sample"))
    }
    func testFailedWebLoginOrExternalEndpointNeverReceivesToken() throws {
        for endpoint in ["https://uiapi.w.163.com/share/detail?sn=\(sn)", "https://evil.test/share/detail"] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var calls = [], failure = null;
            var endpoint = '\(endpoint)';
            var fetch = async (url, options) => {
                calls.push(url);
                return {ok: true, text: async () => '{"code":409}'};
            };
            """)
            context.evaluateScript("(async () => {\(DDShareClient.authenticatedDetailScript)})().then(value => failure = value)")
            XCTAssertEqual(context.evaluateScript("calls.length")?.toInt32(), endpoint.contains("evil.test") ? 0 : 1)
            XCTAssertNotEqual(context.objectForKeyedSubscript("failure")?.toString(), "null")
            let response = try XCTUnwrap(context.objectForKeyedSubscript("failure")?.toString())
            XCTAssertThrowsError(try DDShareClient.decodeAuthenticatedDetail(Data(response.utf8)))
        }
    }
    func testSignatureRefusalIsNotReportedAsAccountPermission() throws {
        let data = try data(["stage": "login", "code": 409, "reason": "signature"])
        XCTAssertThrowsError(try DDShareClient.decodeAuthenticatedDetail(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("签名"))
            XCTAssertTrue(error.localizedDescription.contains("不是账号权限"))
        }
        for stage in ["endpoint", "login", "detail"] {
            XCTAssertThrowsError(try DDShareClient.decodeAuthenticatedDetail(self.data(["stage": stage, "code": -1, "reason": "request"])))
        }
    }
    func testLoginFailureReturnsSanitizedDiagnosticInsteadOfJavaScriptException() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var output = null, failure = null, count = 0;
        var endpoint = 'https://uiapi.w.163.com/share/detail?sn=\(sn)';
        var fetch = async () => { count++; return {ok: true, text: async () =>
            JSON.stringify({code: 409, msg: '签名无效', result: {token: 'must-not-escape'}})}; };
        """)
        context.evaluateScript("(async () => {\(DDShareClient.authenticatedDetailScript)})().then(value => output = value).catch(error => failure = String(error))")
        let result = try XCTUnwrap(context.objectForKeyedSubscript("output")?.toString())
        XCTAssertTrue(result.contains("signature")); XCTAssertFalse(result.contains("must-not-escape"))
        XCTAssertEqual(context.objectForKeyedSubscript("failure")?.toString(), "null")
        XCTAssertEqual(context.evaluateScript("count")?.toInt32(), 1)
    }
}
