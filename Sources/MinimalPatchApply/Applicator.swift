import Foundation

/// Abstracts file system interactions so the patch engine can run against disk or in-memory data.
public protocol PatchFileSystem {
    func fileExists(at path: String) -> Bool
    func readFile(at path: String) throws -> Data
    func writeFile(_ data: Data, to path: String) throws
    func removeItem(at path: String) throws
    func moveItem(from source: String, to destination: String) throws
    func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws
}

/// Default implementation backed by `FileManager`.
public struct LocalFileSystem: PatchFileSystem {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func readFile(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeFile(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    public func removeItem(at path: String) throws {
        if fileExists(at: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    public func moveItem(from source: String, to destination: String) throws {
        if fileExists(at: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.moveItem(atPath: source, toPath: destination)
    }

    public func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: permissions)]
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }
}

/// Applies a validated patch plan to the provided file system.
public struct PatchApplicator {
    private let fileSystem: PatchFileSystem
    private let configuration: Configuration

    public struct Configuration {
        public enum WhitespaceMode {
            case exact
            case ignoreAll
        }

        public let whitespace: WhitespaceMode

        public init(whitespace: WhitespaceMode = .exact) {
            self.whitespace = whitespace
        }
    }

    public init(fileSystem: PatchFileSystem, configuration: Configuration = .init()) {
        self.fileSystem = fileSystem
        self.configuration = configuration
    }

    public func apply(_ plan: PatchPlan) throws {
        for directive in plan.directives {
            switch directive.operation {
            case .add:
                try applyAddition(directive)
            case .delete:
                try applyDeletion(directive)
            case .modify:
                try applyModification(directive)
            case .rename:
                try applyRename(directive)
            case .copy:
                try applyCopy(directive)
            }
        }
    }

    private func applyAddition(_ directive: PatchDirective) throws {
        guard let target = directive.newPath else {
            throw PatchEngineError.validationFailed("add directive missing destination path")
        }
        guard !fileSystem.fileExists(at: target) else {
            throw PatchEngineError.validationFailed("destination already exists: \(target)")
        }
        let buffer = try buildBufferForAddition(hunks: directive.hunks)
        try write(buffer: buffer, to: target)
        try applyFileMode(for: directive, to: target)
    }

    private func applyDeletion(_ directive: PatchDirective) throws {
        guard let source = directive.oldPath else {
            throw PatchEngineError.validationFailed("delete directive missing source path")
        }
        guard fileSystem.fileExists(at: source) else {
            throw PatchEngineError.validationFailed("cannot delete missing file: \(source)")
        }

        var buffer = try loadBuffer(at: source)
        try apply(hunks: directive.hunks, to: &buffer, path: source)
        guard buffer.lines.isEmpty else {
            throw PatchEngineError.validationFailed("delete directive did not remove all content for \(source)")
        }
        try remove(path: source)
    }

    private func applyModification(_ directive: PatchDirective) throws {
        guard let path = directive.newPath, let oldPath = directive.oldPath, path == oldPath else {
            throw PatchEngineError.validationFailed("modify directive must reference the same path for old and new content")
        }
        guard fileSystem.fileExists(at: path) else {
            throw PatchEngineError.validationFailed("cannot modify missing file: \(path)")
        }

        var buffer = try loadBuffer(at: path)
        try apply(hunks: directive.hunks, to: &buffer, path: path)
        try write(buffer: buffer, to: path)
        try applyFileMode(for: directive, to: path)
    }

    private func applyRename(_ directive: PatchDirective) throws {
        guard let oldPath = directive.oldPath, let newPath = directive.newPath else {
            throw PatchEngineError.validationFailed("rename directive requires both old and new paths")
        }
        guard fileSystem.fileExists(at: oldPath) else {
            throw PatchEngineError.validationFailed("cannot rename missing file: \(oldPath)")
        }
        guard oldPath != newPath else {
            throw PatchEngineError.validationFailed("rename directive must target a different path")
        }

        if directive.hunks.isEmpty {
            try move(from: oldPath, to: newPath)
            try applyFileMode(for: directive, to: newPath)
            return
        }

        var buffer = try loadBuffer(at: oldPath)
        try apply(hunks: directive.hunks, to: &buffer, path: oldPath)
        try write(buffer: buffer, to: newPath)
        try remove(path: oldPath)
        try applyFileMode(for: directive, to: newPath)
    }

    private func applyCopy(_ directive: PatchDirective) throws {
        guard let source = directive.oldPath, let destination = directive.newPath else {
            throw PatchEngineError.validationFailed("copy directive requires both old and new paths")
        }
        guard fileSystem.fileExists(at: source) else {
            throw PatchEngineError.validationFailed("cannot copy missing file: \(source)")
        }
        guard source != destination else {
            throw PatchEngineError.validationFailed("copy directive must target a different path")
        }
        guard !fileSystem.fileExists(at: destination) else {
            throw PatchEngineError.validationFailed("destination already exists: \(destination)")
        }

        var buffer = try loadBuffer(at: source)
        if !directive.hunks.isEmpty {
            try apply(hunks: directive.hunks, to: &buffer, path: destination)
        }
        try write(buffer: buffer, to: destination)
        try applyFileMode(for: directive, to: destination)
    }

    private func buildBufferForAddition(hunks: [PatchHunk]) throws -> TextBuffer {
        var lines: [String] = []
        var hasTrailingNewline = true
        var sawAddition = false

        for hunk in hunks {
            for line in hunk.lines {
                switch line {
                case .addition(let value):
                    lines.append(value)
                    sawAddition = true
                case .noNewlineMarker:
                    hasTrailingNewline = false
                case .context, .deletion:
                    throw PatchEngineError.validationFailed("add directive hunks may only contain additions")
                }
            }
        }

        guard sawAddition else {
            throw PatchEngineError.validationFailed("add directive must introduce content")
        }

        return TextBuffer(lines: lines, hasTrailingNewline: hasTrailingNewline)
    }

    private func apply(hunks: [PatchHunk], to buffer: inout TextBuffer, path: String) throws {
        for hunk in hunks {
            let transform = try HunkTransform(hunk: hunk)
            let insertionIndex = try locateMatch(
                expected: transform.expected,
                in: buffer,
                header: hunk.header,
                path: path
            )

            let matchTouchesEnd = insertionIndex + transform.expected.count == buffer.lines.count
            if matchTouchesEnd, let expectedFlag = transform.expectedTrailingNewline {
                guard buffer.hasTrailingNewline == expectedFlag else {
                    throw PatchEngineError.validationFailed("newline expectation mismatch while applying hunk to \(path)")
                }
            }

            if transform.expected.count > 0 {
                buffer.lines.removeSubrange(insertionIndex..<(insertionIndex + transform.expected.count))
            }
            if !transform.replacement.isEmpty {
                buffer.lines.insert(contentsOf: transform.replacement, at: insertionIndex)
            }

            let replacementTouchesEnd = insertionIndex + transform.replacement.count == buffer.lines.count
            if replacementTouchesEnd {
                if let replacementFlag = transform.replacementTrailingNewline {
                    buffer.hasTrailingNewline = replacementFlag
                } else if transform.expectedTrailingNewline != nil {
                    buffer.hasTrailingNewline = true
                }
            }
        }
    }

    private func locateMatch(
        expected: [String],
        in buffer: TextBuffer,
        header: PatchHunkHeader,
        path: String
    ) throws -> Int {
        if expected.isEmpty {
            if let newRange = header.newRange {
                let index = max(0, min(buffer.lines.count, newRange.start - 1))
                return index
            }
            return buffer.lines.count
        }

        if let oldRange = header.oldRange {
            let candidate = max(0, min(buffer.lines.count, oldRange.start - 1))
            if matches(expected, in: buffer, at: candidate) {
                return candidate
            }
        }

        var matchesFound: [Int] = []
        if buffer.lines.count >= expected.count {
            for start in 0...(buffer.lines.count - expected.count) {
                if matches(expected, in: buffer, at: start) {
                    matchesFound.append(start)
                }
            }
        }

        if matchesFound.isEmpty {
            throw PatchEngineError.validationFailed("context mismatch while applying hunk to \(path)")
        }
        guard matchesFound.count == 1 else {
            throw PatchEngineError.validationFailed("ambiguous hunk match while applying patch to \(path)")
        }
        return matchesFound[0]
    }

    private func matches(_ expected: [String], in buffer: TextBuffer, at index: Int) -> Bool {
        guard index >= 0, index + expected.count <= buffer.lines.count else {
            return false
        }
        for offset in 0..<expected.count {
            if canonical(buffer.lines[index + offset]) != canonical(expected[offset]) {
                return false
            }
        }
        return true
    }

    private func canonical(_ line: String) -> String {
        switch configuration.whitespace {
        case .exact:
            return line
        case .ignoreAll:
            return line.filter { !$0.isWhitespace }
        }
    }

    private func loadBuffer(at path: String) throws -> TextBuffer {
        do {
            let data = try fileSystem.readFile(at: path)
            guard let string = String(data: data, encoding: .utf8) else {
                throw PatchEngineError.ioFailure("file at \(path) is not valid UTF-8")
            }
            return TextBuffer(string: string)
        } catch let error as PatchEngineError {
            throw error
        } catch {
            throw PatchEngineError.ioFailure("failed to read \(path): \(error)")
        }
    }

    private func write(buffer: TextBuffer, to path: String) throws {
        do {
            try fileSystem.writeFile(buffer.encode(), to: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to write \(path): \(error)")
        }
    }

    private func remove(path: String) throws {
        do {
            try fileSystem.removeItem(at: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to remove \(path): \(error)")
        }
    }

    private func move(from source: String, to destination: String) throws {
        do {
            try fileSystem.moveItem(from: source, to: destination)
        } catch {
            throw PatchEngineError.ioFailure("failed to move \(source) to \(destination): \(error)")
        }
    }

    private func applyFileMode(for directive: PatchDirective, to path: String) throws {
        guard let newMode = directive.metadata.fileModeChange?.newMode else { return }
        guard let permissions = parsePermissions(from: newMode) else { return }
        do {
            try fileSystem.setPOSIXPermissions(permissions, at: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to set permissions on \(path): \(error)")
        }
    }

    private func parsePermissions(from modeString: String) -> UInt16? {
        let cleaned = modeString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = UInt32(cleaned, radix: 8) else { return nil }
        return UInt16(value & 0o7777)
    }
}

private struct TextBuffer {
    var lines: [String]
    var hasTrailingNewline: Bool

    init(lines: [String], hasTrailingNewline: Bool) {
        self.lines = lines
        self.hasTrailingNewline = hasTrailingNewline
    }

    init(string: String) {
        var collected: [String] = []
        var current = ""
        for character in string {
            if character == "\n" {
                collected.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        let hasTrailing = string.last == "\n"
        if !hasTrailing {
            if !string.isEmpty {
                collected.append(current)
            }
        }
        self.lines = collected
        self.hasTrailingNewline = hasTrailing
    }

    func encode() throws -> Data {
        var text = lines.joined(separator: "\n")
        if hasTrailingNewline {
            text.append("\n")
        }
        guard let data = text.data(using: .utf8) else {
            throw PatchEngineError.ioFailure("failed to encode buffer as UTF-8")
        }
        return data
    }
}

private struct HunkTransform {
    let expected: [String]
    let replacement: [String]
    let expectedTrailingNewline: Bool?
    let replacementTrailingNewline: Bool?

    init(hunk: PatchHunk) throws {
        var expected: [String] = []
        var replacement: [String] = []
        var expectedTrailing: Bool?
        var replacementTrailing: Bool?
        var lastMeaningfulLine: PatchLine?

        for line in hunk.lines {
            switch line {
            case .context(let value):
                expected.append(value)
                replacement.append(value)
                lastMeaningfulLine = line
            case .addition(let value):
                replacement.append(value)
                lastMeaningfulLine = line
            case .deletion(let value):
                expected.append(value)
                lastMeaningfulLine = line
            case .noNewlineMarker:
                guard let last = lastMeaningfulLine else {
                    throw PatchEngineError.validationFailed("newline marker must follow an addition, deletion, or context line")
                }
                switch last {
                case .deletion:
                    expectedTrailing = false
                case .context, .addition:
                    replacementTrailing = false
                case .noNewlineMarker:
                    break
                }
            }
        }

        self.expected = expected
        self.replacement = replacement
        self.expectedTrailingNewline = expectedTrailing
        self.replacementTrailingNewline = replacementTrailing
    }
}
