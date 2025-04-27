import Foundation

public struct PatchApplier {
    private let begin = "*** Begin Patch"
    private let end = "*** End Patch"
    private let dirPrefix = "+++ "
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

    private func makeDirective(from line: String, seenPaths: inout Set<String>) throws -> Directive {
        let components = line.dropFirst(dirPrefix.count).split(separator: " ")
        guard components.count >= 2 else { throw PatchError.malformed(line) }
        let verb = components[0]
        let path = String(components[1])
        if !seenPaths.insert(path).inserted { throw PatchError.duplicate(path) }
        switch verb {
        case "add":
            return Directive(operation: .add, path: path, movePath: nil)
        case "delete":
            return Directive(operation: .delete, path: path, movePath: nil)
        case "update":
            return Directive(operation: .update, path: path, movePath: nil)
        case "move":
            guard components.count == 4, components[2] == "to" else {
                throw PatchError.malformed(line)
            }
            return Directive(operation: .update, path: path, movePath: String(components[3]))
        default:
            throw PatchError.malformed("unknown verb \\(verb)")
        }
    }

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

        func flushHunk() throws {
            guard var directive = currentDirective, !hunkBuffer.isEmpty else {
                hunkBuffer.removeAll()
                return
            }
            let hunkLines = try parseHunk(hunkBuffer)
            directive.hunks.append(hunkLines)
            directives[directives.count - 1] = directive
            hunkBuffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix(dirPrefix) {
                try flushHunk()
                let directive = try makeDirective(from: line, seenPaths: &seenPaths)
                directives.append(directive)
                currentDirective = directive
            } else if line.hasPrefix(hunkPrefix) || currentDirective != nil {
                hunkBuffer.append(line)
            }
        }
        try flushHunk()
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

    private func applyHunk(_ hunk: [Line], to old: String) throws -> String {
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
                guard
                    currentIndex < bufferLines.count,
                    normalizeWhitespace(bufferLines[currentIndex]) ==
                    normalizeWhitespace(contextLine)
                else {
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
}
