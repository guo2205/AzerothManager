import XCTest
@testable import ManagerCore

final class ConfigurationInstallTests: XCTestCase {
    var root: URL!
    var client: URL { root.appendingPathComponent("Game") }
    var payload: URL { root.appendingPathComponent("Payload") }
    var library: ConfigurationLibrary { ConfigurationLibrary(backupRoot: root.appendingPathComponent("Backups")) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try put("old toc", client, "Interface/AddOns/Demo/Demo.toc")
        try put("obsolete", client, "Interface/AddOns/Demo/obsolete.lua")
        try put("keep", client, "Interface/AddOns/Other/Other.toc")
        try put("old role", client, "WTF/Account/A/Realm/Hero/config-cache.wtf")
        try put("personal WA", client, "WTF/Account/A/SavedVariables/WeakAuras.lua")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func put(_ text: String, _ base: URL, _ path: String) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: client.appendingPathComponent(path), encoding: .utf8) }
    func prepare() throws -> ConfigurationPreview {
        try put("new toc", payload, "Interface/AddOns/Demo/Demo.toc")
        try put("new role", payload, "WTF/Account/A/Realm/Hero/config-cache.wtf")
        try put("font", payload, "Fonts/test.ttf")
        let role = try XCTUnwrap(ConfigurationFiles.roles(in: client).first)
        return try library.preview(payload: payload, client: client, roles: [role], accountWide: false)
    }
    func testFullBackupInstallationAndRestore() throws {
        let preview = try prepare(); defer { library.discard(preview) }
        let snapshot = try library.install(preview)
        XCTAssertEqual(try read("Interface/AddOns/Demo/Demo.toc"), "new toc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: client.appendingPathComponent("Interface/AddOns/Demo/obsolete.lua").path))
        XCTAssertEqual(try read("Interface/AddOns/Other/Other.toc"), "keep")
        XCTAssertEqual(try read("WTF/Account/A/SavedVariables/WeakAuras.lua"), "personal WA")
        XCTAssertEqual(try read("Fonts/test.ttf"), "font")
        try library.restore(snapshot, client: client)
        XCTAssertEqual(try read("WTF/Account/A/Realm/Hero/config-cache.wtf"), "old role")
        XCTAssertEqual(try read("Interface/AddOns/Demo/obsolete.lua"), "obsolete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: client.appendingPathComponent("Fonts").path))
        XCTAssertEqual(try library.snapshots(for: client).count, 2)
    }
    func testFailureAfterAnyRootCommitRollsEverythingBack() throws {
        for index in 0..<3 {
            let preview = try prepare(); defer { library.discard(preview) }
            XCTAssertThrowsError(try library.install(preview, checkpoint: { if $0 == index { throw ManagerError("injected") } }))
            XCTAssertEqual(try read("Interface/AddOns/Demo/Demo.toc"), "old toc")
            XCTAssertEqual(try read("WTF/Account/A/Realm/Hero/config-cache.wtf"), "old role")
            XCTAssertFalse(FileManager.default.fileExists(atPath: client.appendingPathComponent("Fonts").path))
            try library.recoverInterrupted(in: client)
        }
    }
    func testPreviewRejectsOutsideAccountAndChangesAfterPreview() throws {
        let preview = try prepare(); defer { library.discard(preview) }
        try put("external", client, "WTF/Account/A/Realm/Hero/config-cache.wtf")
        XCTAssertThrowsError(try library.install(preview))
        try put("escape", payload, "WTF/Account/B/SavedVariables/Demo.lua")
        XCTAssertThrowsError(try library.preview(payload: payload, client: client, roles: ConfigurationFiles.roles(in: client), accountWide: true))
    }
    func testCorruptSnapshotCannotRestore() throws {
        let snapshot = try library.backup(client, reason: "test")
        try put("tampered", library.backupRoot.appendingPathComponent(snapshot.id), "WTF/Account/A/SavedVariables/WeakAuras.lua")
        XCTAssertThrowsError(try library.restore(snapshot, client: client))
        XCTAssertEqual(try read("WTF/Account/A/SavedVariables/WeakAuras.lua"), "personal WA")
    }
    func testPendingJournalBlocksFurtherWrites() throws {
        let preview = try prepare(); defer { library.discard(preview) }
        let transaction = client.appendingPathComponent(".azeroth-share-txn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        XCTAssertTrue(try library.hasPendingTransaction(in: client))
        XCTAssertThrowsError(try library.install(preview))
        XCTAssertThrowsError(try library.backup(client, reason: "blocked"))
        try library.recoverInterrupted(in: client)
        XCTAssertFalse(try library.hasPendingTransaction(in: client))
        _ = try library.install(preview)
    }
    func testRoleComponentsAndSymlinksAreRejected() throws {
        XCTAssertThrowsError(try ConfigurationRole(account: "../A", realm: "Realm", name: "Hero"))
        let link = client.appendingPathComponent("WTF/Account/A/Realm/Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ConfigurationFiles.roles(in: client))
    }
}
