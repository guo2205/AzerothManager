import Foundation
import ZipInflate

/// A deliberately narrow ZIP reader: stored/deflate, UTF-8 names, single disk, no ZIP64.
/// No shell, archive commands, Lua or executable content is ever executed.
public enum SafeZIP {
    struct Entry {
        let path: String; let directory: Bool; let method: Int; let crc: UInt32
        let packed: Int; let size: Int; let offset: Int; let flags: Int; let name: Data
    }
    static func entries(_ data: Data) throws -> [Entry] {
        func fail() -> ManagerError { ManagerError("ZIP 格式无效或不受支持（仅支持普通 UTF-8 ZIP，不支持加密、分卷、ZIP64 或链接）") }
        func u16(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= data.count else { throw fail() }
            return Int(data[i]) | Int(data[i + 1]) << 8
        }
        func u32(_ i: Int) throws -> Int { try u16(i) | (u16(i + 2) << 16) }
        guard data.count >= 22, data.count <= 256 * 1024 * 1024 else { throw ManagerError("ZIP 最大支持 256 MB") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(i) == 0x06054b50, try i + 22 + u16(i + 20) == data.count { end = i; break }
        }
        guard let e = end, try u16(e + 4) == 0, try u16(e + 6) == 0 else { throw fail() }
        let count = try u16(e + 10), centralSize = try u32(e + 12), centralStart = try u32(e + 16)
        guard count > 0, count <= 20000, try u16(e + 8) == count, centralStart + centralSize == e else { throw fail() }
        var p = centralStart, total = 0, found: [Entry] = [], names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try u32(p) == 0x02014b50 else { throw fail() }
            let flags = try u16(p + 8), method = try u16(p + 10), crc = try u32(p + 16)
            let packed = try u32(p + 20), size = try u32(p + 24), nl = try u16(p + 28), el = try u16(p + 30), cl = try u16(p + 32)
            let attr = try u32(p + 38), offset = try u32(p + 42)
            guard p + 46 + nl + el + cl <= e, nl > 0, try u16(p + 34) == 0,
                  flags & ~0x080e == 0, flags & 1 == 0, method == 0 || method == 8,
                  packed != 0xffffffff, size <= 128 * 1024 * 1024, offset < centralStart else { throw fail() }
            let nameData = data.subdata(in: p + 46..<p + 46 + nl)
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\\"), !name.hasPrefix("/"), !name.contains(":"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw fail() }
            let isDir = name.hasSuffix("/"), path = isDir ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }), path.utf8.count <= 2048 else { throw fail() }
            let kind = (attr >> 16) & 0xf000
            guard kind == 0 || kind == (isDir ? 0x4000 : 0x8000), !isDir || size == 0 else { throw fail() }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else { throw ManagerError("ZIP 含重复或大小写冲突路径") }
            total += size
            guard total <= 1024 * 1024 * 1024 else { throw ManagerError("ZIP 解压后不能超过 1 GB") }
            guard try u32(offset) == 0x04034b50, try u16(offset + 6) == flags, try u16(offset + 8) == method else { throw fail() }
            let lnl = try u16(offset + 26), lel = try u16(offset + 28), start = offset + 30 + lnl + lel
            guard lnl == nl, start <= centralStart, start + packed <= centralStart, data.subdata(in: offset + 30..<offset + 30 + lnl) == nameData else { throw fail() }
            if flags & 8 == 0 {
                guard try u32(offset + 14) == crc, try u32(offset + 18) == packed, try u32(offset + 22) == size else { throw fail() }
            }
            ranges.append(offset..<start + packed)
            found.append(Entry(path: path, directory: isDir, method: method, crc: UInt32(crc), packed: packed, size: size, offset: start, flags: flags, name: nameData))
            p += 46 + nl + el + cl
        }
        guard p == e else { throw fail() }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for i in 1..<sorted.count { guard sorted[i - 1].upperBound <= sorted[i].lowerBound else { throw fail() } }
        let files = Set(found.filter { !$0.directory }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
        for item in found {
            var parent = (item.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !files.contains(parent.precomposedStringWithCanonicalMapping.lowercased()) else { throw fail() }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return found
    }
    public static func extract(_ archive: URL, into destination: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: archive.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 256 * 1024 * 1024 else { throw ManagerError("ZIP 最大支持 256 MB") }
        let data = try Data(contentsOf: archive)
        let list = try entries(data)
        guard !fm.fileExists(atPath: destination.path) else { throw ManagerError("解压目标必须是全新目录") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for item in list {
                let target = destination.appendingPathComponent(item.path)
                if item.directory { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
                var output = Data(count: max(1, item.size))
                let input = data.subdata(in: item.offset..<item.offset + item.packed)
                if item.method == 0 {
                    guard item.packed == item.size else { throw ManagerError("ZIP 长度不匹配") }; output = input
                } else {
                    let ok = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { src in
                        wow_inflate(src.bindMemory(to: UInt8.self).baseAddress, input.count, out.bindMemory(to: UInt8.self).baseAddress, item.size)
                    } }
                    guard ok == 1 else { throw ManagerError("ZIP 解压失败或声明大小不匹配") }
                    if item.size == 0 { output = Data() }
                }
                let crc = output.withUnsafeBytes { wow_crc($0.bindMemory(to: UInt8.self).baseAddress, output.count) }
                guard crc == item.crc else { throw ManagerError("ZIP 校验失败，文件可能损坏") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try output.write(to: target, options: .withoutOverwriting)
            }
        } catch { try? fm.removeItem(at: destination); throw error }
    }
}
