import XCTest
@testable import ManagerCore

final class ManagerCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func target() throws -> URL {
        let target = root.appendingPathComponent("Game/Interface/AddOns")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
    func testLocalizedMetadataAndFlavor() throws {
        let target = try target(), folder = target.appendingPathComponent("Demo")
        try write("\u{feff}## Title: English\r\n## Title-zhCN: |cffff0000中文|r\r\n## Version: 1.0\n## Interface: 123, 456\n## RequiredDeps: Base", folder.appendingPathComponent("Demo.toc"))
        try write("## Title: Mainline", folder.appendingPathComponent("Demo_Mainline.toc"))
        let time = try XCTUnwrap(AddonScanner.scan(target, flavor: .time).first)
        XCTAssertEqual(time.title, "中文"); XCTAssertEqual(time.interface, "123, 456"); XCTAssertEqual(time.dependencies, "Base")
        XCTAssertEqual(try AddonScanner.scan(target, flavor: .retail).first?.title, "Mainline")
    }
    func testDirectoryDiscoveryAndSymlinkRejection() throws {
        let target = try target()
        XCTAssertEqual(FileSafety.candidates(root.appendingPathComponent("Game")).map(\.path), [target.path])
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("Escape"), withDestinationURL: root)
        XCTAssertThrowsError(try AddonScanner.scan(target, flavor: .time))
    }
    func testBackupUninstallRestoreAndPreRestoreSnapshot() throws {
        let target = try target(), library = Library(backupRoot: root.appendingPathComponent("Backups"))
        try write("## Title: 原始插件", target.appendingPathComponent("Demo/Demo.toc"))
        let snapshot = try library.backup(target, reason: "test")
        try library.uninstall(["Demo"], target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Demo").path))
        try write("## Title: 新插件", target.appendingPathComponent("New/New.toc"))
        try library.restore(snapshot, target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Demo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("New").path))
        XCTAssertEqual(try library.snapshots(for: target).count, 3)
    }
    func testFailedMutationPreservesLiveTree() throws {
        let target = try target(), library = Library(backupRoot: root.appendingPathComponent("Backups"))
        try write("original", target.appendingPathComponent("Demo/Demo.toc"))
        XCTAssertThrowsError(try library.uninstall(["Demo", "Missing"], target: target))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Demo/Demo.toc"), encoding: .utf8), "original")
        XCTAssertThrowsError(try library.uninstall(["../outside"], target: target))
    }
    // Minimal stored ZIP builder exercises the production parser without external tools.
    func zip(_ files: [(String, Data)], external: UInt32 = 0) -> Data {
        func le(_ n: UInt32, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        func crc(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xffffffff
            for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            return ~crc
        }
        var local = Data(), central = Data()
        for (name, body) in files {
            let name = Data(name.utf8), offset = UInt32(local.count), sum = crc(body)
            func append(_ fields: [(UInt32, Int)], to data: inout Data) {
                for (value, size) in fields { data.append(le(value, size)) }
            }
            append([(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,4),(sum,4),(UInt32(body.count),4),(UInt32(body.count),4),(UInt32(name.count),2),(0,2)], to: &local)
            local.append(name); local.append(body)
            append([(0x02014b50,4),(0x314,2),(20,2),(0x800,2),(0,2),(0,4),(sum,4),(UInt32(body.count),4),(UInt32(body.count),4),(UInt32(name.count),2),(0,2),(0,2),(0,2),(0,2),(external,4),(offset,4)], to: &central)
            central.append(name)
        }
        var result = local
        result.append(central)
        for (value, size) in [(UInt32(0x06054b50),4),(0,4),(UInt32(files.count),2),(UInt32(files.count),2),(UInt32(central.count),4),(UInt32(local.count),4),(0,2)] {
            result.append(le(value, size))
        }
        return result
    }
    func extract(_ data: Data) throws -> URL {
        let archive = root.appendingPathComponent(UUID().uuidString + ".zip"), destination = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: archive); try SafeZIP.extract(archive, into: destination); return destination
    }
    func testValidZIPInstallAndWholeFolderReplacement() throws {
        let target = try target(), library = Library(backupRoot: root.appendingPathComponent("Backups"))
        try write("stale", target.appendingPathComponent("Demo/stale.lua"))
        let archive = root.appendingPathComponent("addon.zip")
        try zip([("Release/Interface/AddOns/Demo/Demo.toc", Data("## Title-zhCN: 测试\n## Version: 2".utf8)), ("Release/Interface/AddOns/Demo/main.lua", Data("-- test".utf8))]).write(to: archive)
        let preview = try library.prepare(archive, target: target, flavor: .time)
        defer { library.discard(preview) }
        XCTAssertEqual(preview.replacing, ["Demo"])
        try library.install(preview, target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Demo/stale.lua").path))
        XCTAssertEqual(try AddonScanner.scan(target, flavor: .time).first?.version, "2")
        XCTAssertEqual(try library.snapshots(for: target).count, 1)
    }
    func testTraversalAbsoluteDuplicatesAndLinksRejected() throws {
        for path in ["../escape", "/absolute", "Demo/../../escape", "C:/evil", "Demo\\evil", "Demo//evil", "Demo/./evil"] {
            XCTAssertThrowsError(try extract(zip([(path, Data("x".utf8))])), path)
        }
        XCTAssertThrowsError(try extract(zip([("Demo/a", Data()), ("demo/A", Data())])))
        XCTAssertThrowsError(try extract(zip([("Demo/link", Data("../outside".utf8))], external: 0xa1ff0000)))
        XCTAssertThrowsError(try extract(zip([("Demo", Data()), ("Demo/a", Data())])))
    }
    func testCRCAndTruncationRejected() throws {
        var bytes = zip([("Demo/file", Data("payload".utf8))])
        bytes[30 + "Demo/file".utf8.count] ^= 1
        XCTAssertThrowsError(try extract(bytes))
        XCTAssertThrowsError(try extract(Data(bytes.dropLast(10))))
    }
    func testDeflateFixtureAndEmptyDeflate() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Deflate", withExtension: "zip", subdirectory: "Fixtures"))
        let destination = root.appendingPathComponent("Deflated")
        try SafeZIP.extract(fixture, into: destination)
        let meta = try TOC.parse(Data(contentsOf: destination.appendingPathComponent("HelloAzeroth/HelloAzeroth.toc")))
        XCTAssertEqual(meta["version"], "2.0.0")
        let empty = try XCTUnwrap(Bundle.module.url(forResource: "Empty", withExtension: "zip", subdirectory: "Fixtures"))
        let emptyDestination = root.appendingPathComponent("EmptyDeflated")
        try SafeZIP.extract(empty, into: emptyDestination)
        XCTAssertEqual(try Data(contentsOf: emptyDestination.appendingPathComponent("empty.lua")).count, 0)
    }
    func testLimitsAndLocalNameMismatchRejected() throws {
        var oversized = zip([("Demo/file", Data("x".utf8))])
        let central = 30 + "Demo/file".utf8.count + 1
        // Advertise 128 MiB + 1 before any allocation or decompression.
        let declared: UInt32 = 128 * 1024 * 1024 + 1
        for i in 0..<4 { oversized[central + 24 + i] = UInt8(truncatingIfNeeded: declared >> (i * 8)) }
        XCTAssertThrowsError(try extract(oversized))
        var mismatch = zip([("Demo/file", Data("x".utf8))])
        mismatch[30] = UInt8(ascii: "X")
        XCTAssertThrowsError(try extract(mismatch))
    }
    func testOnlineUpdatesExplicitlyUnavailable() async throws {
        do { _ = try await UnavailableUpdateProvider().checkUpdates(); XCTFail("Should not claim update support") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未实现")) }
    }
}
