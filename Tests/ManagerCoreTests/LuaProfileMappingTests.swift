import XCTest
@testable import ManagerCore
final class LuaProfileMappingTests: XCTestCase {
    func testProfileReferencesAndEmbeddedSourceArePreserved() throws {
        let source = try ConfigurationRole(account: "Author", realm: "源服", name: "作者")
        let a = try ConfigurationRole(account: "A", realm: "目标服", name: "甲")
        let b = try ConfigurationRole(account: "A", realm: "目标服", name: "乙")
        let input = #"DB = { ["profileKeys"] = { ["作者 - 源服"] = "作者配置", }, ["profiles"] = { ["作者配置"] = { ["x"] = 12 }, }, ["code"] = [=[ ["作者 - 源服"] = run() ]=], }"#
        let output = String(decoding: try LuaProfileMapping.copyIdentityKeys(Data(input.utf8), source: source, targets: [a, b]), as: UTF8.self)
        XCTAssertTrue(output.contains(#"["甲 - 目标服"] = "作者配置""#))
        XCTAssertTrue(output.contains(#"["乙 - 目标服"] = "作者配置""#))
        XCTAssertTrue(output.contains(#"["作者配置"] = { ["x"] = 12 }"#))
        XCTAssertTrue(output.contains(#"[=[ ["作者 - 源服"] = run() ]=]"#))
        let twice = try LuaProfileMapping.copyIdentityKeys(Data(output.utf8), source: source, targets: [a, b])
        XCTAssertEqual(twice, Data(output.utf8))
    }
    func testNDuiNestedRealmAndCharacterMapping() throws {
        let source = try ConfigurationRole(account: "Author", realm: "源服", name: "作者")
        let role = try ConfigurationRole(account: "A", realm: "目标服", name: "玩家")
        let input = #"NDuiDB = { ["cache"] = { ["源服"] = { ["作者"] = { ["setting"] = 3, ["text"] = "do not change", }, }, ["目标服"] = { ["Other"] = {1}, }, }, }"#
        let output = String(decoding: try LuaProfileMapping.copyIdentityKeys(Data(input.utf8), source: source, targets: [role]), as: UTF8.self)
        XCTAssertTrue(output.contains(#"["玩家"] = { ["setting"] = 3, ["text"] = "do not change", }"#))
        XCTAssertTrue(output.contains(#"["Other"] = {1}"#))
        XCTAssertEqual(try LuaProfileMapping.copyIdentityKeys(Data(output.utf8), source: source, targets: [role]), Data(output.utf8))
    }
    func testMalformedDataAndDuplicateIdentityAreRejected() throws {
        let role = try ConfigurationRole(account: "A", realm: "R", name: "N")
        for input in [#"DB = { ["N-R"] = "unterminated }"#, #"DB = { ["N-R"] = 1, ["N-R"] = 2 }"#, "DB = { --[=[ incomplete"] {
            XCTAssertThrowsError(try LuaProfileMapping.copyIdentityKeys(Data(input.utf8), source: role, targets: [role]))
        }
    }
}
