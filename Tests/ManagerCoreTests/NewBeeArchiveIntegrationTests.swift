import XCTest
@testable import ManagerCore

final class NewBeeArchiveIntegrationTests: XCTestCase {
    /// Opt-in, local archives only. No private share metadata or downloaded author files are bundled.
    func testDownloadedShareInDisposableGameDirectory() throws {
        guard ProcessInfo.processInfo.environment["AZEROTH_NEWBEE_ARCHIVE_TEST"] == "1" else { throw XCTSkip("Explicit local archive integration test") }
        let fm = FileManager.default
        let metadata = URL(fileURLWithPath: "/private/tmp/newbeebox-share534-authenticated.json")
        let object = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])?["data"] as? [[String: Any]]).first!
        let share = try JSONDecoder().decode(NewBeeShare.self, from: JSONSerialization.data(withJSONObject: object))
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/newbee-plugin-download-plan.json"))) as? [[String: Any]])
        let archiveRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["AZEROTH_NEWBEE_PLUGIN_ARCHIVES"])
        var plugins: [NewBeeLocalPlugin] = []
        for item in plan {
            let id = try XCTUnwrap(item["id"])
            let file = try JSONDecoder().decode(NewBeePluginFile.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(item["file"])))
            plugins.append(NewBeeLocalPlugin(archive: URL(fileURLWithPath: archiveRoot).appendingPathComponent(String(describing: id) + ".zip"), folders: file.file_folders, label: item["name"] as? String ?? "插件", id: String(describing: id)))
        }
        let root = fm.temporaryDirectory.appendingPathComponent("AzerothRealArchiveTest-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let client = root.appendingPathComponent("Game")
        func put(_ value: String, _ relative: String) throws {
            let file = client.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }
        try put("old addon", "Interface/AddOns/WeakAuras/old.lua")
        try put("## Title: untouched", "Interface/AddOns/Untouched/Untouched.toc")
        try put("old role", "WTF/Account/One/测试一/本地角色一/config-cache.wtf")
        try put("old role", "WTF/Account/Two/测试二/本地角色二/config-cache.wtf")
        try put("personal WA", "WTF/Account/One/SavedVariables/WeakAuras.lua")
        try put("old font", "Fonts/old.ttf")
        let roles = try ConfigurationFiles.roles(in: client)
        let account = try XCTUnwrap(share.accounts.first), realm = try XCTUnwrap(account.server.first), sourceRole = try XCTUnwrap(realm.roleList.first)
        let source = try ConfigurationRole(account: account.account, realm: realm.serverName, name: sourceRole.name)
        let choices = NewBeeInstallChoices(pluginIDs: Set(share.plugins.map(\.id)), source: source, roles: roles, common: true, roleSettings: true, materials: true, fonts: true, folderOwners: ["gathermate2_data": "77"])
        let preview = try NewBeePayload.preview(share: share, choices: choices, plugins: plugins,
            common: URL(fileURLWithPath: "/private/tmp/newbee-NDui-commonConfig.zip"), role: URL(fileURLWithPath: "/private/tmp/newbee-NDui-role.zip"),
            materials: URL(fileURLWithPath: "/private/tmp/newbee-materials.zip"), fonts: URL(fileURLWithPath: archiveRoot).deletingLastPathComponent().appendingPathComponent("字体资源"), client: client, flavor: .time)
        let library = ConfigurationLibrary(backupRoot: root.appendingPathComponent("Backups"))
        defer { library.discard(preview) }
        XCTAssertGreaterThan(preview.fileCount, 500)
        let before = try AddonFingerprint.fingerprint(client)
        let snapshot = try library.install(preview)
        XCTAssertFalse(fm.fileExists(atPath: client.appendingPathComponent("Interface/AddOns/WeakAuras/old.lua").path))
        XCTAssertTrue(fm.fileExists(atPath: client.appendingPathComponent("Interface/AddOns/NDui/NDui.toc").path))
        XCTAssertTrue(fm.fileExists(atPath: client.appendingPathComponent("Interface/Icons").path))
        let saved = try String(contentsOf: client.appendingPathComponent("WTF/Account/One/SavedVariables/NDui.lua"), encoding: .utf8)
        XCTAssertTrue(saved.contains("本地角色一"))
        try library.restore(snapshot, client: client)
        XCTAssertEqual(try AddonFingerprint.fingerprint(client), before)
    }
}
