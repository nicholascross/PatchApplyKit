// MinimalPatchApply.swift
// Usage:
//   try applyPatch(patchText)                     // works on the local file-system
//   try applyPatch(patchText,                     // or inject your own FS handlers
//                  read:  { path in ... },
//                  write: { path, data in ... },
//                  remove:{ path in ... })

import Foundation

// ───────────────────────── Parsing (*** Begin Patch …) ───────────────────────
private let begin = "*** Begin Patch"
private let end = "*** End Patch"
private let dirPrefix = "+++ "
private let hunkPrefix = "@@ "

private func parse(_ text: String) throws -> [Directive] {
    guard
        let b = text.range(of: begin)?.upperBound,
        let e = text.range(of: end)?.lowerBound
    else {
        throw PatchError.malformed("missing begin/end markers")
    }
    let lines = text[b ..< e].split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

    var seen = Set<String>(), dirs: [Directive] = [], current: Directive?
    var hunkBuf: [String] = []

    func flushHunk() {
        guard var d = current, !hunkBuf.isEmpty else { hunkBuf.removeAll(); return }
        d.hunks.append(try! parseHunk(hunkBuf)) // safe; syntax already checked
        dirs[dirs.count - 1] = d
        hunkBuf.removeAll()
    }

    for l in lines {
        if l.hasPrefix(dirPrefix) { // new directive
            flushHunk()
            let comps = l.dropFirst(dirPrefix.count).split(separator: " ")
            guard comps.count >= 2 else { throw PatchError.malformed(l) }
            let verb = comps[0], path = String(comps[1])
            if !seen.insert(path).inserted { throw PatchError.duplicate(path) }

            switch verb {
            case "add": current = Directive(operation: .add, path: path, movePath: nil)
            case "delete": current = Directive(operation: .delete, path: path, movePath: nil)
            case "update": current = Directive(operation: .update, path: path, movePath: nil)
            case "move":
                guard comps.count == 4, comps[2] == "to"
                else { throw PatchError.malformed(l) }
                current = Directive(operation: .update, path: path, movePath: String(comps[3]))
            default: throw PatchError.malformed("unknown verb \(verb)")
            }
            dirs.append(current!)
        } else if l.hasPrefix(hunkPrefix) || current != nil {
            hunkBuf.append(l)
        }
    }
    flushHunk()
    return dirs
}

private func parseHunk(_ lines: [String]) throws -> [Line] {
    var out: [Line] = []
    for l in lines.dropFirst() { // header ignored (already validated by diff producer)
        if l.hasPrefix("+") { out.append(.ins(String(l.dropFirst()))) }
        else if l.hasPrefix("-") { out.append(.del(String(l.dropFirst()))) }
        else if l.hasPrefix(" ") { out.append(.ctx(String(l.dropFirst()))) }
    }
    return out
}

// ────────────────────── Minimal diff application engine ──────────────────────
private func apply(_ hunk: [Line], to old: String) throws -> String {
    var buf = old.split(whereSeparator: \.isNewline).map(String.init)
    var idx = 0
    func norm(_ s: String) -> String { s.replacingOccurrences(of: "\\s+", with: " ",
                                                              options: .regularExpression) }
    for l in hunk {
        switch l {
        case let .ctx(s):
            guard idx < buf.count, norm(buf[idx]) == norm(s) else {
                throw PatchError.malformed("context mismatch while patching")
            }; idx += 1
        case .del:
            guard idx < buf.count else { throw PatchError.malformed("delete OOB") }
            buf.remove(at: idx)
        case let .ins(s):
            buf.insert(s, at: idx); idx += 1
        }
    }
    return buf.joined(separator: "\n")
}

// ────────────────────────────── Public API ────────────────────────────────────
public func applyPatch(
    _ patch: String,
    read: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
    write: (String, String) throws -> Void = { path, data in
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try data.write(toFile: path, atomically: true, encoding: .utf8)
    },
    remove: (String) throws -> Void = { path in
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
) throws {
    let dirs = try parse(patch)
    for d in dirs {
        switch d.operation {
        case .add:
            guard (try? read(d.path)) == nil else { throw PatchError.exists(d.path) }
            // Extract context and insertion lines as content for new file
            let content = d.hunks.flatMap { $0 }.compactMap { line in
                switch line {
                case let .ctx(s), let .ins(s): return s
                default: return nil
                }
            }.joined(separator: "\n")
            try write(d.path, content)

        case .delete:
            guard (try? read(d.path)) != nil else { throw PatchError.missing(d.path) }
            try remove(d.path)

        case .update:
            guard let old = try? read(d.path) else { throw PatchError.missing(d.path) }
            let newText = try d.hunks.reduce(old) { try apply($1, to: $0) }
            let dst = d.movePath ?? d.path
            if dst != d.path { try remove(d.path) }
            try write(dst, newText)
        }
    }
}
