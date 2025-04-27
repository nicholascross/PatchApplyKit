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
        let beginMarkerIndex = text.range(of: begin)?.upperBound,
        let endMarkerIndex = text.range(of: end)?.lowerBound
    else {
        throw PatchError.malformed("missing begin/end markers")
    }
    let lines = text[beginMarkerIndex ..< endMarkerIndex]
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

    var seenPaths = Set<String>()
    var directives: [Directive] = []
    var currentDirective: Directive?
    var hunkBuffer: [String] = []

    func flushHunk() {
        guard var directive = currentDirective, !hunkBuffer.isEmpty else {
            hunkBuffer.removeAll()
            return
        }
        directive.hunks.append(try! parseHunk(hunkBuffer)) // safe; syntax already checked
        directives[directives.count - 1] = directive
        hunkBuffer.removeAll()
    }

    for line in lines {
        if line.hasPrefix(dirPrefix) { // new directive
            flushHunk()
            let components = line.dropFirst(dirPrefix.count).split(separator: " ")
            guard components.count >= 2 else { throw PatchError.malformed(line) }
            let directiveVerb = components[0]
            let path = String(components[1])
            if !seenPaths.insert(path).inserted { throw PatchError.duplicate(path) }

            switch directiveVerb {
            case "add":
                currentDirective = Directive(operation: .add, path: path, movePath: nil)
            case "delete":
                currentDirective = Directive(operation: .delete, path: path, movePath: nil)
            case "update":
                currentDirective = Directive(operation: .update, path: path, movePath: nil)
            case "move":
                guard components.count == 4, components[2] == "to" else {
                    throw PatchError.malformed(line)
                }
                currentDirective = Directive(operation: .update, path: path, movePath: String(components[3]))
            default:
                throw PatchError.malformed("unknown verb \(directiveVerb)")
            }
            directives.append(currentDirective!)
        } else if line.hasPrefix(hunkPrefix) || currentDirective != nil {
            hunkBuffer.append(line)
        }
    }
    flushHunk()
    return directives
}

private func parseHunk(_ lines: [String]) throws -> [Line] {
    var parsedLines: [Line] = []
    for lineContent in lines.dropFirst() {
        if lineContent.hasPrefix("+") {
            parsedLines.append(.insert(String(lineContent.dropFirst())))
        } else if lineContent.hasPrefix("-") {
            parsedLines.append(.delete(String(lineContent.dropFirst())))
        } else if lineContent.hasPrefix(" ") {
            parsedLines.append(.context(String(lineContent.dropFirst())))
        }
    }
    return parsedLines
}

// ────────────────────── Minimal diff application engine ──────────────────────
private func apply(_ hunk: [Line], to old: String) throws -> String {
    let originalLines = old.split(whereSeparator: \.isNewline).map(String.init)
    var bufferLines = originalLines
    var currentIndex = 0
    func normalizeWhitespace(_ input: String) -> String {
        input.replacingOccurrences(of: "\\s+", with: " ",
                                     options: .regularExpression)
    }
    for patchLine in hunk {
        switch patchLine {
        case let .context(contextLine):
            guard currentIndex < bufferLines.count,
                  normalizeWhitespace(bufferLines[currentIndex]) == normalizeWhitespace(contextLine) else {
                throw PatchError.malformed("context mismatch while patching")
            }
            currentIndex += 1
        case .delete:
            guard currentIndex < bufferLines.count else {
                throw PatchError.malformed("delete OOB")
            }
            bufferLines.remove(at: currentIndex)
        case let .insert(insertionLine):
            bufferLines.insert(insertionLine, at: currentIndex)
            currentIndex += 1
        }
    }
    return bufferLines.joined(separator: "\n")
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
    let directives = try parse(patch)
    for directive in directives {
        switch directive.operation {
        case .add:
            guard (try? read(directive.path)) == nil else {
                throw PatchError.exists(directive.path)
            }
            // Extract context and insertion lines as content for new file
            let content = directive.hunks
                .flatMap { $0 }
                .compactMap { line in
                    switch line {
                    case let .context(contextLine): return contextLine
                    case let .insert(insertionLine): return insertionLine
                    default: return nil
                    }
                }
                .joined(separator: "\n")
            try write(directive.path, content)

        case .delete:
            guard (try? read(directive.path)) != nil else {
                throw PatchError.missing(directive.path)
            }
            try remove(directive.path)

        case .update:
            guard let existingContent = try? read(directive.path) else {
                throw PatchError.missing(directive.path)
            }
            let newContent = try directive.hunks.reduce(existingContent) {
                try apply($1, to: $0)
            }
            let destinationPath = directive.movePath ?? directive.path
            if destinationPath != directive.path {
                try remove(directive.path)
            }
            try write(destinationPath, newContent)
        }
    }
}
