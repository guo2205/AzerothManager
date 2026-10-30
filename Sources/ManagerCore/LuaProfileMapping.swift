import Foundation

/// Copies exact SavedVariables table keys to selected local identities. It never evaluates Lua,
/// rewrites embedded WA source, or renames profile labels referenced by other tables.
public enum LuaProfileMapping {
    private struct Token { let start: Int; let end: Int; let symbol: UInt8?; let string: String? }
    private struct Entry { let parent: Int; let key: String; let start: Int; let value: Range<Int>; let table: Int? }
    public static func copyIdentityKeys(_ data: Data, source: ConfigurationRole, targets: [ConfigurationRole]) throws -> Data {
        guard data.count <= 128 * 1024 * 1024 else { throw ManagerError("SavedVariables 文件过大") }
        func variants(_ role: ConfigurationRole) -> [String] {
            [role.name + " - " + role.realm, role.realm + " - " + role.name, role.name + "-" + role.realm, role.realm + "-" + role.name, role.realm + "." + role.name, "Default." + role.realm + "." + role.name]
        }
        let sourceKeys = variants(source)
        let bytes = Array(data)
        var i = 0, tokenCount = 0
        let translations: [UInt8: UInt8] = [97: 7, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11]
        func isSpace(_ c: UInt8) -> Bool { switch c { case 9...13, 32: return true; default: return false } }
        func punctuation(_ c: UInt8) -> Bool { switch c { case 34, 39, 91, 93, 123, 125, 40, 41, 61, 44, 59: return true; default: return false } }
        func longDelimiter(_ at: Int) -> (Int, Int)? {
            guard at < bytes.count, bytes[at] == 91 else { return nil }
            var end = at + 1
            while end < bytes.count, bytes[end] == 61 { end += 1 }
            return end < bytes.count && bytes[end] == 91 ? (end - at - 1, end + 1) : nil
        }
        func longEnd(_ level: Int, _ start: Int) throws -> Int {
            var p = start
            while p < bytes.count {
                if p % 65536 == 0 { try Task.checkCancellation() }
                if bytes[p] == 93 {
                    var q = p + 1
                    while q < bytes.count, bytes[q] == 61 { q += 1 }
                    if q - p - 1 == level, q < bytes.count, bytes[q] == 93 { return q + 1 }
                }
                p += 1
            }
            throw ManagerError("SavedVariables 的长字符串或注释不完整")
        }
        func nextToken() throws -> Token? {
            while i < bytes.count {
                if isSpace(bytes[i]) { i += 1; continue }
                if bytes[i] == 45, i + 1 < bytes.count, bytes[i + 1] == 45 {
                    i += 2
                    if let (level, start) = longDelimiter(i) { i = try longEnd(level, start) }
                    else { while i < bytes.count, bytes[i] != 10 { i += 1 } }
                    continue
                }
                tokenCount += 1
                if tokenCount % 4096 == 0 { try Task.checkCancellation() }
                guard tokenCount <= 50_000_000 else { throw ManagerError("SavedVariables 结构超过处理限制") }
                let start = i
                if bytes[i] == 34 || bytes[i] == 39 {
                    let quote = bytes[i]; i += 1; var decoded: [UInt8] = [], decodable = true
                    func append(_ value: UInt8) { if decoded.count < 2048 { decoded.append(value) } else { decodable = false } }
                    while i < bytes.count, bytes[i] != quote {
                        if i % 65536 == 0 { try Task.checkCancellation() }
                        if bytes[i] == 92 {
                            i += 1; guard i < bytes.count else { throw ManagerError("SavedVariables 字符串不完整") }
                            let escaped = bytes[i]
                            if escaped >= 48 && escaped <= 57 {
                                var value = 0, count = 0
                                while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57, count < 3 { value = value * 10 + Int(bytes[i] - 48); i += 1; count += 1 }
                                guard value <= 255 else { throw ManagerError("SavedVariables 转义无效") }
                                append(UInt8(value)); continue
                            }
                            if escaped == 122 { i += 1; while i < bytes.count, isSpace(bytes[i]) { i += 1 }; continue }
                            if escaped == 120, i + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { append(value); i += 3; continue }
                            append(translations[escaped] ?? escaped); i += 1
                        } else { append(bytes[i]); i += 1 }
                    }
                    guard i < bytes.count else { throw ManagerError("SavedVariables 字符串不完整") }
                    i += 1; return Token(start: start, end: i, symbol: nil, string: decodable ? String(bytes: decoded, encoding: .utf8) : nil)
                }
                if let (level, body) = longDelimiter(i) { i = try longEnd(level, body); return Token(start: start, end: i, symbol: nil, string: nil) }
                if punctuation(bytes[i]) { let symbol = bytes[i]; i += 1; return Token(start: start, end: i, symbol: symbol, string: nil) }
                i += 1
                while i < bytes.count, !isSpace(bytes[i]), !punctuation(bytes[i]) {
                    if bytes[i] == 45, i + 1 < bytes.count, bytes[i + 1] == 45 { break }
                    i += 1
                }
                return Token(start: start, end: i, symbol: nil, string: nil)
            }
            return nil
        }
        var queue: [Token] = [], atEnd = false
        func peek(_ offset: Int = 0) throws -> Token? {
            while queue.count <= offset && !atEnd { if let token = try nextToken() { queue.append(token) } else { atEnd = true } }
            return queue.count > offset ? queue[offset] : nil
        }
        @discardableResult func take() throws -> Token {
            guard let token = try peek() else { throw ManagerError("SavedVariables 意外结束") }
            queue.removeFirst(); return token
        }
        var entries: [Entry] = [], keys: [Int: Set<String>] = [:], owners: [Int: String] = [:]
        let neededKeys = Set(sourceKeys + [source.name, source.realm] + targets.flatMap { [$0.realm, $0.name] + variants($0) })
        func value(owner: String?, depth: Int) throws -> (Range<Int>, Int?) {
            guard let token = try peek() else { throw ManagerError("SavedVariables 缺少表项目") }
            if token.symbol == 123 {
                let end = try table(owner: owner, depth: depth + 1)
                return (token.start..<end, token.start)
            }
            guard token.symbol == nil else { throw ManagerError("SavedVariables 含不支持的表项目") }
            _ = try take(); return (token.start..<token.end, nil)
        }
        func table(owner: String?, depth: Int) throws -> Int {
            guard depth <= 128 else { throw ManagerError("SavedVariables 表层级过深") }
            let opening = try take()
            if let owner, neededKeys.contains(owner) { owners[opening.start] = owner }
            while let first = try peek() {
                if first.symbol == 125 { return try take().end }
                var key: String?, start = first.start
                if first.symbol == 91 {
                    _ = try take(); let keyToken = try take(); key = keyToken.string
                    guard try take().symbol == 93, try take().symbol == 61 else { throw ManagerError("SavedVariables 索引格式不完整") }
                } else if first.symbol == nil, first.string == nil, try peek(1)?.symbol == 61,
                          let initial = bytes[first.start...].first, (initial == 95 || (65...90).contains(initial) || (97...122).contains(initial)) {
                    key = String(decoding: bytes[first.start..<first.end], as: UTF8.self)
                    _ = try take(); _ = try take()
                } else { start = first.start }
                if let key, neededKeys.contains(key) {
                    guard keys[opening.start, default: []].insert(key).inserted else { throw ManagerError("SavedVariables 含重复角色索引，无法确定配置") }
                }
                let parsed = try value(owner: key, depth: depth)
                if let key, neededKeys.contains(key) {
                    entries.append(Entry(parent: opening.start, key: key, start: start, value: parsed.0, table: parsed.1))
                    guard entries.count <= 10000 else { throw ManagerError("SavedVariables 的角色索引过于复杂") }
                }
                guard let separator = try peek() else { throw ManagerError("SavedVariables 表结构不完整") }
                if separator.symbol == 44 || separator.symbol == 59 { _ = try take() }
                else if separator.symbol != 125 { throw ManagerError("SavedVariables 含不支持的表达式，不能安全映射角色") }
            }
            throw ManagerError("SavedVariables 表结构不完整")
        }
        while let token = try peek() {
            if token.symbol == 123 { _ = try table(owner: nil, depth: 1) }
            else if token.symbol == 125 { throw ManagerError("SavedVariables 表结构不完整") }
            else { _ = try take() }
        }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var edits: [(Int, Data)] = []
        var expansion = data.count
        func reserve(_ count: Int) throws {
            guard count <= 128 * 1024 * 1024 - expansion else { throw ManagerError("角色映射后的 SavedVariables 文件过大") }; expansion += count
        }
        for entry in entries {
            guard let kind = sourceKeys.firstIndex(of: entry.key) else { continue }
            var insertion = Data()
            for target in targets {
                let key = variants(target)[kind]
                guard keys[entry.parent, default: []].insert(key).inserted else { continue }
                try reserve(entry.value.count + key.utf8.count * 2 + 32)
                insertion.append(Data(("[" + quote(key) + "] = ").utf8)); insertion.append(data.subdata(in: entry.value)); insertion.append(Data(",\n".utf8))
            }
            if !insertion.isEmpty { edits.append((entry.start, insertion)) }
        }
        // NDui and NDui_Plus also keep realm -> character tables, independently of AceDB keys.
        for character in entries where character.key == source.name && owners[character.parent] == source.realm {
            guard let realm = entries.first(where: { $0.table == character.parent && $0.key == source.realm }) else { continue }
            for (realmName, localRoles) in Dictionary(grouping: targets, by: \.realm) {
                let existingRealm = entries.first { $0.parent == realm.parent && $0.key == realmName && $0.table != nil }
                let destinationTable = existingRealm?.table
                var inserted = Data()
                for role in localRoles {
                    if let destinationTable, !keys[destinationTable, default: []].insert(role.name).inserted { continue }
                    try reserve(character.value.count + role.name.utf8.count * 2 + realmName.utf8.count * 2 + 64)
                    inserted.append(Data(("[" + quote(role.name) + "] = ").utf8)); inserted.append(data.subdata(in: character.value)); inserted.append(Data(",\n".utf8))
                }
                guard !inserted.isEmpty else { continue }
                if let destinationTable { edits.append((destinationTable + 1, inserted)) }
                else {
                    guard keys[realm.parent, default: []].insert(realmName).inserted else { continue }
                    var block = Data(("[" + quote(realmName) + "] = {\n").utf8); block.append(inserted); block.append(Data("},\n".utf8))
                    edits.append((realm.start, block))
                }
            }
        }
        var output = data
        for edit in edits.sorted(by: { $0.0 > $1.0 }) { output.insert(contentsOf: edit.1, at: edit.0) }
        return output
    }
}
