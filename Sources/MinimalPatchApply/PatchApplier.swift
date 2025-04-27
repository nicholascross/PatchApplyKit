import Foundation

public struct PatchApplier {
    private let begin = "*** Begin Patch"
    private let end = "*** End Patch"
    private let oldPrefix = "--- "
    private let newPrefix = "+++ "
    private let hunkPrefix = "@@ "

    public let read: (String) throws -> String
    public let write: (String, String) throws -> Void
    public let remove: (String) throws -> Void

    public init(
        read: @escaping (String) throws
            -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        write: @escaping (String, String) throws -> Void = { path, data in
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(toFile: path, atomically: true, encoding: .utf8)
        },
        remove: @escaping (String) throws -> Void = { path in
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    public func apply(_ patch: String) throws {
        let directives = try parse(patch)
        for directive in directives {
            switch directive.operation {
            case .add:
                try handleAdd(directive)
            case .delete:
                try handleDelete(directive)
            case .update:
                try handleUpdate(directive)
            }
        }
    }

    private func handleAdd(_ directive: Directive) throws {
        guard (try? read(directive.path)) == nil else {
            throw PatchError.exists(directive.path)
        }
        let content = directive.hunks
            .flatMap { $0.lines }
            .compactMap { line in
                switch line {
                case let .context(contextLine): return contextLine
                case let .insert(insertionLine): return insertionLine
                default: return nil
                }
            }
            .joined(separator: "\n")
        try write(directive.path, content)
    }

    private func handleDelete(_ directive: Directive) throws {
        guard (try? read(directive.path)) != nil else {
            throw PatchError.missing(directive.path)
        }
        try remove(directive.path)
    }

    private func handleUpdate(_ directive: Directive) throws {
        guard let existingContent = try? read(directive.path) else {
            throw PatchError.missing(directive.path)
        }
        let updated = try directive.hunks.reduce(existingContent) {
            try applyHunk($1, to: $0)
        }
        let destination = directive.movePath ?? directive.path
        if destination != directive.path {
            try remove(directive.path)
        }
        try write(destination, updated)
    }

    private func parse(_ text: String) throws -> [Directive] {
        let lines = try extractPatchLines(from: text)
        return try parseDirectives(from: lines)
    }

    private func extractPatchLines(from text: String) throws -> [String] {
        guard let start = text.range(of: begin)?.upperBound,
              let end = text.range(of: end)?.lowerBound
        else {
            throw PatchError.malformed("missing begin/end markers")
        }
        return text[start..<end]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func parseDirectives(from lines: [String]) throws -> [Directive] {
        var seenPaths = Set<String>()
        var directives = [Directive]()
        var currentDirectiveIndex: Int?
        var hunkBuffer = [String]()
        var oldPath: String?

        func flushHunk() throws {
            guard let idx = currentDirectiveIndex, !hunkBuffer.isEmpty else {
                hunkBuffer.removeAll()
                return
            }
            let hunk = try parseHunk(hunkBuffer)
            directives[idx].hunks.append(hunk)
            hunkBuffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix(oldPrefix) {
                try flushHunk()
                oldPath = String(line.dropFirst(oldPrefix.count))
                currentDirectiveIndex = nil
            } else if line.hasPrefix(newPrefix) {
                try flushHunk()
                guard let old = oldPath else {
                    throw PatchError.malformed("missing old file prefix before new file prefix")
                }
                let newP = String(line.dropFirst(newPrefix.count))
                let directive = makeDirective(old: old, new: newP)
                guard seenPaths.insert(directive.path).inserted else {
                    throw PatchError.duplicate(directive.path)
                }
                directives.append(directive)
                currentDirectiveIndex = directives.count - 1
            } else if line.hasPrefix(hunkPrefix) {
                try flushHunk()
                hunkBuffer = [line]
            } else if currentDirectiveIndex != nil {
                hunkBuffer.append(line)
            }
        }
        try flushHunk()
        return directives
    }

    private func makeDirective(old: String, new newP: String) -> Directive {
        let operation: Operation
        let path: String
        var movePath: String?
        if old == "/dev/null" {
            operation = .add
            path = newP
        } else if newP == "/dev/null" {
            operation = .delete
            path = old
        } else {
            operation = .update
            path = old
            if old != newP {
                movePath = newP
            }
        }
        return Directive(operation: operation, path: path, movePath: movePath)
    }

    /// Parses a raw hunk buffer (including header) into a Hunk with header metadata and lines
    private func parseHunk(_ lines: [String]) throws -> Hunk {
        // Extract header line (e.g., "@@ -l,k +l',k' @@")
        let rawHeader = lines.first ?? ""
        // Initialize optional header fields
        var oldStart: Int?, oldCount: Int?
        var newStart: Int?, newCount: Int?
        // Trim whitespace for parsing
        let trimmed = rawHeader.trimmingCharacters(in: .whitespaces)
        // Regex to match unified diff hunk header with line numbers
        let pattern = "^@@\\s*-(\\d+)(?:,(\\d+))?\\s+\\+(\\d+)(?:,(\\d+))?\\s*@@"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: trimmed.utf16.count)
           ) {
            // Helper to extract capture group
            func group(_ idx: Int) -> String? {
                let range = match.range(at: idx)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: trimmed) else {
                    return nil
                }
                return String(trimmed[swiftRange])
            }
            if let oldStartString = group(1) { oldStart = Int(oldStartString) }
            if let oldCountString = group(2) { oldCount = Int(oldCountString) } else { oldCount = 1 }
            if let newStartString = group(3) { newStart = Int(newStartString) }
            if let newCountString = group(4) { newCount = Int(newCountString) } else { newCount = 1 }
        }
        // Parse individual lines (skip header)
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
        return Hunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: parsedLines
        )
    }

    private func applyHunk(_ hunk: Hunk, to old: String) throws -> String {
        let originalLines = old.split(whereSeparator: \.isNewline).map(String.init)
        // 1. Try header-based apply
        if let oldStart = hunk.oldStart {
            let seed = max(0, oldStart - 1)
            if let applied = try? tryApply(hunk: hunk, originalLines: originalLines, seed: seed) {
                return applied.joined(separator: "\n")
            }
        }
        // 2. Fallback to beginning when no context
        let hasContext = hunk.lines.contains { if case .context = $0 { return true } else { return false } }
        if hunk.oldStart == nil && !hasContext {
            let applied = try tryApply(hunk: hunk, originalLines: originalLines, seed: 0)
            return applied.joined(separator: "\n")
        }
        // 3. Exhaustive search for unique match
        var successfulApplies = [[String]]()
        for seed in 0...originalLines.count {
            if let applied = try? tryApply(hunk: hunk, originalLines: originalLines, seed: seed) {
                successfulApplies.append(applied)
            }
        }
        if successfulApplies.count == 1 {
            return successfulApplies[0].joined(separator: "\n")
        }
        if successfulApplies.isEmpty {
            throw PatchError.malformed("context mismatch while patching")
        }
        throw PatchError.malformed("ambiguous hunk match")
    }

    private func normalizeWhitespace(_ input: String) -> String {
        input.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func tryApply(hunk: Hunk, originalLines: [String], seed: Int) throws -> [String] {
        var lines = originalLines
        var idx = seed
        for patchLine in hunk.lines {
            switch patchLine {
            case let .context(contextLine):
                guard idx < lines.count,
                      normalizeWhitespace(lines[idx]) == normalizeWhitespace(contextLine)
                else { throw PatchError.malformed("context mismatch while patching") }
                idx += 1
            case .delete:
                guard idx < lines.count else { throw PatchError.malformed("delete OOB") }
                lines.remove(at: idx)
            case let .insert(insertionLine):
                lines.insert(insertionLine, at: idx)
                idx += 1
            }
        }
        return lines
    }
}
