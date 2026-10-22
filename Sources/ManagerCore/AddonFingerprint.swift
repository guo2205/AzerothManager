import Foundation
import CryptoKit

/// 本地内容指纹，用于检测检查后的文件修改，不上传文件内容。
enum AddonFingerprint {
    static func fingerprint(_ folder: URL) throws -> String {
        try FileSafety.checkTree(folder)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder.path) else { throw ManagerError("无法读取插件文件") }
        let names = enumerator.compactMap { $0 as? String }.sorted()
        var hash = SHA256()
        for relative in names {
            let file = folder.appendingPathComponent(relative)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var fileHash = SHA256()
            while let data = try handle.read(upToCount: 65536), !data.isEmpty { fileHash.update(data: data) }
            hash.update(data: Data(fileHash.finalize()))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
