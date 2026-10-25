import XCTest
@testable import ManagerCore

final class PackageBatchTests: XCTestCase {
    func addon(_ name: String, title: String? = nil) -> Addon {
        Addon(folder: name, title: title ?? name, version: "子版本1", author: "作者", notes: "", interface: "", dependencies: "", tocNames: "")
    }
    func selection(_ id: String, folders: [String], file: String = "new") throws -> DDSelection {
        let data = try JSONSerialization.data(withJSONObject: ["sn": id, "name": "包" + id, "folders": folders, "detail_sn": "old", "local_version": "1", "latest_version": ["sn": file, "version": "2", "folders": folders]])
        return try DDSelection(package: JSONDecoder().decode(DDScanPackage.self, from: data), flavor: .time)
    }
    func state(_ selection: DDSelection, current: Bool = false) -> InstalledUpdate {
        InstalledUpdate(label: current ? "所属包已是最新" : "所属包可更新", packageInfo: DDPackageInfo(package: selection.package, latest: selection.version), ddSelection: current ? nil : selection, isCurrent: current)
    }
    func testBundleGroupedOnceAndChildSearchKeepsWholePackage() throws {
        let a = try selection("A", folders: ["Core", "Child"])
        let addons = [addon("Private"), addon("Core"), addon("Child", title: "中文子模块")]
        let updates = ["Core": state(a), "Child": state(a)]
        let rows = InstalledUpdates.packages(addons, updates: updates)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.members.map(\.folder), ["Core", "Child"])
        XCTAssertEqual(rows.filter(\.canUpdate).count, 1)
        let found = InstalledUpdates.packages(addons, updates: updates, search: "中文")
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found[0].members.count, 2)
        XCTAssertEqual(found[0].members[1].version, "子版本1")
    }
    func testUnknownFoldersStaySeparateAndCurrentPackagesLast() throws {
        let a = try selection("A", folders: ["Current"]), b = try selection("B", folders: ["Update"])
        let rows = InstalledUpdates.packages([addon("Current"), addon("Private1"), addon("Update"), addon("Private2")], updates: ["Current": state(a, current: true), "Update": state(b)])
        XCTAssertEqual(rows.map(\.id), ["dd:B", "folder:Private1", "folder:Private2", "dd:A"])
        XCTAssertTrue(rows.last!.isCurrent)
    }
    func testOverlappingPackagesAndInconsistentFileIDsCannotUpdate() throws {
        let a = try selection("A", folders: ["A", "Shared"]), b = try selection("B", folders: ["B", "shared"])
        let rows = InstalledUpdates.packages([addon("A"), addon("B")], updates: ["A": state(a), "B": state(b)])
        XCTAssertTrue(rows.allSatisfy { !$0.canUpdate })
        XCTAssertTrue(rows.allSatisfy { $0.label.contains("冲突") })
        let older = try selection("A", folders: ["A", "Shared"], file: "different")
        let mixed = InstalledUpdates.packages([addon("A"), addon("Shared")], updates: ["A": state(a), "Shared": state(older)])
        XCTAssertFalse(mixed[0].canUpdate)
    }
    func testSequentialJobsDeduplicateContinueAfterFailureAndReportProgress() async throws {
        let a = PackageUpdateJob(selection: try selection("A", folders: ["A"]), expected: [:])
        let b = PackageUpdateJob(selection: try selection("B", folders: ["B"]), expected: [:])
        let c = PackageUpdateJob(selection: try selection("C", folders: ["C"]), expected: [:])
        var called: [String] = [], steps: [Int] = []
        let result = await PackageBatch.run([a, a, b, c], progress: { step, total, _ in
            XCTAssertEqual(total, 3); steps.append(step)
        }, operation: { job in
            called.append(job.selection.package.sn)
            if job.selection.package.sn == "B" { throw ManagerError("测试下载失败") }
        })
        XCTAssertEqual(called, ["A", "B", "C"]); XCTAssertEqual(steps, [1, 2, 3])
        XCTAssertEqual(result.total, 3); XCTAssertEqual(result.succeeded, 2); XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.outcomes[1].error, "测试下载失败"); XCTAssertEqual(result.remaining, 0)
    }
    func testCancellationKeepsCompletedResultsAndSkipsRest() async throws {
        let a = PackageUpdateJob(selection: try selection("A", folders: ["A"]), expected: [:])
        let b = PackageUpdateJob(selection: try selection("B", folders: ["B"]), expected: [:])
        let c = PackageUpdateJob(selection: try selection("C", folders: ["C"]), expected: [:])
        var called: [String] = []
        let result = await PackageBatch.run([a, b, c], operation: { job in
            called.append(job.selection.package.sn)
            if job.selection.package.sn == "B" { throw CancellationError() }
        })
        XCTAssertEqual(called, ["A", "B"]); XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.succeeded, 1); XCTAssertEqual(result.failed, 0); XCTAssertEqual(result.remaining, 2)
    }
    func testPriorPackageChangesDoNotInvalidateNextButOwnChangesDo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: folder.appendingPathComponent("code.lua"))
        }
        let expected = try Dictionary(uniqueKeysWithValues: ["A", "B"].map { ($0, try AddonFingerprint.fingerprint(root.appendingPathComponent($0))) })
        let b = PackageUpdateJob(selection: try selection("B", folders: ["B"]), expected: expected)
        XCTAssertEqual(Set(b.expected.keys), ["B"])
        try Data("updated A".utf8).write(to: root.appendingPathComponent("A/code.lua"))
        XCTAssertNoThrow(try InstalledUpdates.verify(b.expected, target: root))
        try Data("edited B".utf8).write(to: root.appendingPathComponent("B/code.lua"))
        XCTAssertThrowsError(try InstalledUpdates.verify(b.expected, target: root))
    }
}
