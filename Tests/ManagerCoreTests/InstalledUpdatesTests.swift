import XCTest
@testable import ManagerCore

final class InstalledUpdatesTests: XCTestCase {
    private func addon(_ folder: String, title: String? = nil, author: String = "") -> Addon {
        Addon(folder: folder, title: title ?? folder, version: "1", author: author, notes: "", interface: "", dependencies: "", tocNames: "")
    }
    private func selection() throws -> DDSelection {
        let data = Data("{\"sn\":\"example\",\"name\":\"Example\",\"folders\":[\"Example\"],\"latest_version\":{\"sn\":\"new\",\"version\":\"2\"}}".utf8)
        return try DDSelection(package: JSONDecoder().decode(DDScanPackage.self, from: data), flavor: .time)
    }
    func testUpdatesFirstUnknownMiddleCurrentLastWithStableGroups() throws {
        let addons = [addon("CurrentA"), addon("Unknown"), addon("UpdateA"), addon("CurrentB"), addon("Conflict"), addon("UpdateB")]
        let updates: [String: InstalledUpdate] = [
            "CurrentA": InstalledUpdate(label: "已是最新 · DD（TOC）", isCurrent: true),
            "CurrentB": InstalledUpdate(label: "已是最新 · DD（TOC）", isCurrent: true),
            "Conflict": InstalledUpdate(label: "DD 匹配冲突"),
            "UpdateA": InstalledUpdate(label: "DD 版本可更新", ddSelection: try selection()),
            "UpdateB": InstalledUpdate(label: "本地有修改 · DD", ddSelection: try selection())
        ]
        XCTAssertEqual(InstalledUpdates.ordered(addons, updates: updates).map(\.folder), ["UpdateA", "UpdateB", "Unknown", "Conflict", "CurrentA", "CurrentB"])
        var refreshed = updates
        refreshed["UpdateA"] = InstalledUpdate(label: "已是最新 · DD（TOC）", isCurrent: true)
        XCTAssertEqual(InstalledUpdates.ordered(addons, updates: refreshed).map(\.folder), ["UpdateB", "Unknown", "Conflict", "CurrentA", "UpdateA", "CurrentB"])
    }
    func testSearchKeepsPriorityAndFindsChineseNameFolderOrAuthor() throws {
        let addons = [addon("Current", title: "背包整理"), addon("Unknown", author: "背包作者"), addon("Update", title: "背包助手"), addon("Other")]
        let updates = ["Current": InstalledUpdate(label: "最新", isCurrent: true), "Update": InstalledUpdate(label: "可更新", ddSelection: try selection())]
        XCTAssertEqual(InstalledUpdates.ordered(addons, updates: updates, search: "背包").map(\.folder), ["Update", "Unknown", "Current"])
        XCTAssertEqual(InstalledUpdates.ordered(addons, updates: updates, search: "uPdAtE").map(\.folder), ["Update"])
        XCTAssertTrue(InstalledUpdates.ordered(addons, updates: updates, search: "不存在的名称").isEmpty)
    }
}
