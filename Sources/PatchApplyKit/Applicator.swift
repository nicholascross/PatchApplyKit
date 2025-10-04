import Foundation

/// Abstracts file system interactions so the patch engine can run against disk or in-memory data.
public protocol PatchFileSystem {
    func fileExists(at path: String) -> Bool
    func readFile(at path: String) throws -> Data
    func writeFile(_ data: Data, to path: String) throws
    func removeItem(at path: String) throws
    func moveItem(from source: String, to destination: String) throws
    func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws
    func posixPermissions(at path: String) throws -> UInt16?
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

    public func posixPermissions(at path: String) throws -> UInt16? {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let value = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return UInt16(truncating: value)
    }
}

/// Wraps another file system and confines all operations to a specified root directory.
public struct SandboxedFileSystem: PatchFileSystem {
    private let base: PatchFileSystem
    private let root: URL
    private let rootPathPrefix: String

    public init(rootPath: String, base: PatchFileSystem = LocalFileSystem()) {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.root = rootURL
        let normalizedRootPath = rootURL.path
        if normalizedRootPath.hasSuffix("/") {
            self.rootPathPrefix = normalizedRootPath
        } else {
            self.rootPathPrefix = normalizedRootPath + "/"
        }
        self.base = base
    }

    public func fileExists(at path: String) -> Bool {
        guard let resolved = try? resolve(path) else {
            return false
        }
        return base.fileExists(at: resolved.path)
    }

    public func readFile(at path: String) throws -> Data {
        let resolved = try resolve(path)
        return try base.readFile(at: resolved.path)
    }

    public func writeFile(_ data: Data, to path: String) throws {
        let resolved = try resolve(path)
        try base.writeFile(data, to: resolved.path)
    }

    public func removeItem(at path: String) throws {
        let resolved = try resolve(path)
        try base.removeItem(at: resolved.path)
    }

    public func moveItem(from source: String, to destination: String) throws {
        let resolvedSource = try resolve(source)
        let resolvedDestination = try resolve(destination)
        try base.moveItem(from: resolvedSource.path, to: resolvedDestination.path)
    }

    public func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws {
        let resolved = try resolve(path)
        try base.setPOSIXPermissions(permissions, at: resolved.path)
    }

    public func posixPermissions(at path: String) throws -> UInt16? {
        let resolved = try resolve(path)
        return try base.posixPermissions(at: resolved.path)
    }

    private func resolve(_ path: String) throws -> URL {
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = root.appendingPathComponent(path)
        }
        let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(normalized) else {
            throw SandboxError.pathOutsideSandbox(requested: path, resolved: normalized.path)
        }
        return normalized
    }

    private func contains(_ url: URL) -> Bool {
        let path = url.path
        if path == root.path {
            return true
        }
        return path.hasPrefix(rootPathPrefix)
    }

    public enum SandboxError: Error, CustomStringConvertible {
        case pathOutsideSandbox(requested: String, resolved: String)

        public var description: String {
            switch self {
            case let .pathOutsideSandbox(requested, resolved):
                return "path \(requested) resolves to \(resolved) which is outside the sandbox"
            }
        }
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
        public let contextTolerance: Int

        public init(
            whitespace: WhitespaceMode = .exact,
            contextTolerance: Int = 0
        ) {
            self.whitespace = whitespace
            self.contextTolerance = max(0, contextTolerance)
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
        if let binaryPatch = directive.binaryPatch {
            guard let newData = binaryPatch.newData else {
                throw PatchEngineError.validationFailed("binary add directive missing payload for \(target)")
            }
            try write(data: newData, to: target)
            try applyFileMode(for: directive, to: target)
            return
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

        if let binaryPatch = directive.binaryPatch {
            if let expectedOld = binaryPatch.oldData {
                let currentData = try loadBinary(at: source)
                try verifyBinaryMatch(expected: expectedOld, actual: currentData, path: source)
            }
            try remove(path: source)
            return
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

        if let binaryPatch = directive.binaryPatch {
            let currentData = try loadBinary(at: path)
            if let expectedOld = binaryPatch.oldData {
                try verifyBinaryMatch(expected: expectedOld, actual: currentData, path: path)
            }
            guard let newData = binaryPatch.newData else {
                throw PatchEngineError.validationFailed("binary modify directive missing payload for \(path)")
            }
            try write(data: newData, to: path)
            try applyFileMode(for: directive, to: path)
            return
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

        let originalPermissions = capturePermissions(at: oldPath)

        if let binaryPatch = directive.binaryPatch {
            let originalData = try loadBinary(at: oldPath)
            if let expectedOld = binaryPatch.oldData {
                try verifyBinaryMatch(expected: expectedOld, actual: originalData, path: oldPath)
            }
            let replacement = binaryPatch.newData ?? originalData
            try write(data: replacement, to: newPath)
            try remove(path: oldPath)
            try applyFileMode(for: directive, to: newPath)
            try applyInheritedPermissions(originalPermissions, to: newPath, directive: directive)
            return
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
        try applyInheritedPermissions(originalPermissions, to: newPath, directive: directive)
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

        let sourcePermissions = capturePermissions(at: source)

        if let binaryPatch = directive.binaryPatch {
            let sourceData = try loadBinary(at: source)
            if let expectedOld = binaryPatch.oldData {
                try verifyBinaryMatch(expected: expectedOld, actual: sourceData, path: source)
            }
            let payload = binaryPatch.newData ?? sourceData
            try write(data: payload, to: destination)
            try applyFileMode(for: directive, to: destination)
            try applyInheritedPermissions(sourcePermissions, to: destination, directive: directive)
            return
        }

        if directive.metadata.isBinary {
            let sourceData = try loadBinary(at: source)
            try write(data: sourceData, to: destination)
            try applyFileMode(for: directive, to: destination)
            try applyInheritedPermissions(sourcePermissions, to: destination, directive: directive)
            return
        }

        var buffer = try loadBuffer(at: source)
        if !directive.hunks.isEmpty {
            try apply(hunks: directive.hunks, to: &buffer, path: destination)
        }
        try write(buffer: buffer, to: destination)
        try applyFileMode(for: directive, to: destination)
        try applyInheritedPermissions(sourcePermissions, to: destination, directive: directive)
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
            let match = try locateMatch(
                transform: transform,
                in: buffer,
                header: hunk.header,
                path: path
            )
            let variant = match.variant
            let insertionIndex = match.insertionIndex

            let matchTouchesEnd = insertionIndex + variant.expected.count == buffer.lines.count
            if matchTouchesEnd, let expectedFlag = variant.expectedTrailingNewline {
                guard buffer.hasTrailingNewline == expectedFlag else {
                    throw PatchEngineError.validationFailed("newline expectation mismatch while applying hunk to \(path)")
                }
            }

            if variant.expected.count > 0 {
                buffer.lines.removeSubrange(insertionIndex..<(insertionIndex + variant.expected.count))
            }
            if !variant.replacement.isEmpty {
                buffer.lines.insert(contentsOf: variant.replacement, at: insertionIndex)
            }

            let replacementTouchesEnd = insertionIndex + variant.replacement.count == buffer.lines.count
            if replacementTouchesEnd {
                if let replacementFlag = variant.replacementTrailingNewline {
                    buffer.hasTrailingNewline = replacementFlag
                } else if variant.expectedTrailingNewline != nil {
                    buffer.hasTrailingNewline = true
                }
            }
        }
    }

    private struct HunkMatch {
        let insertionIndex: Int
        let variant: HunkTransform.Variant
    }

    private func locateMatch(
        transform: HunkTransform,
        in buffer: TextBuffer,
        header: PatchHunkHeader,
        path: String
    ) throws -> HunkMatch {
        let variants = transform.variants(contextTolerance: configuration.contextTolerance)

        for variant in variants {
            if variant.expected.isEmpty {
                let insertion: Int
                if let newRange = header.newRange {
                    insertion = max(0, min(buffer.lines.count, newRange.start - 1))
                } else {
                    insertion = buffer.lines.count
                }
                return HunkMatch(insertionIndex: insertion, variant: variant)
            }

            if let oldRange = header.oldRange {
                let maxCandidate = buffer.lines.count - variant.expected.count
                if maxCandidate >= 0 {
                    let candidate = max(0, min(maxCandidate, oldRange.start - 1))
                    if matches(variant.expected, in: buffer, at: candidate) {
                        return HunkMatch(insertionIndex: candidate, variant: variant)
                    }
                }
            }

            var matchesFound: [Int] = []
            if buffer.lines.count >= variant.expected.count {
                for start in 0...(buffer.lines.count - variant.expected.count) {
                    if matches(variant.expected, in: buffer, at: start) {
                        matchesFound.append(start)
                    }
                }
            }

            if matchesFound.count > 1 {
                throw PatchEngineError.validationFailed("ambiguous hunk match while applying patch to \(path)")
            } else if let match = matchesFound.first {
                return HunkMatch(insertionIndex: match, variant: variant)
            }
        }

        throw PatchEngineError.validationFailed("context mismatch while applying hunk to \(path)")
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

    private func loadBinary(at path: String) throws -> Data {
        do {
            return try fileSystem.readFile(at: path)
        } catch let error as PatchEngineError {
            throw error
        } catch {
            throw PatchEngineError.ioFailure("failed to read \(path): \(error)")
        }
    }

    private func verifyBinaryMatch(expected: Data, actual: Data, path: String) throws {
        guard expected == actual else {
            throw PatchEngineError.validationFailed("binary content mismatch while applying patch to \(path)")
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

    private func write(data: Data, to path: String) throws {
        do {
            try fileSystem.writeFile(data, to: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to write \(path): \(error)")
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
        try setPermissions(permissions, at: path)
    }

    private func parsePermissions(from modeString: String) -> UInt16? {
        let cleaned = modeString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = UInt32(cleaned, radix: 8) else { return nil }
        return UInt16(value & 0o7777)
    }

    private func capturePermissions(at path: String) -> UInt16? {
        guard let permissions = try? fileSystem.posixPermissions(at: path) else {
            return nil
        }
        return permissions
    }

    private func applyInheritedPermissions(_ permissions: UInt16?, to path: String, directive: PatchDirective) throws {
        guard directive.metadata.fileModeChange?.newMode == nil else { return }
        guard let permissions else { return }
        try setPermissions(permissions, at: path)
    }

    private func setPermissions(_ permissions: UInt16, at path: String) throws {
        do {
            try fileSystem.setPOSIXPermissions(permissions, at: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to set permissions on \(path): \(error)")
        }
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
    enum ExpectedKind: Equatable {
        case context
        case deletion
    }

    enum ReplacementKind: Equatable {
        case context
        case addition
    }

    struct Variant {
        let expected: [String]
        let replacement: [String]
        let expectedTrailingNewline: Bool?
        let replacementTrailingNewline: Bool?
        let leadingContextTrim: Int
        let trailingContextTrim: Int
    }

    private let baseExpected: [String]
    private let baseExpectedKinds: [ExpectedKind]
    private let baseReplacement: [String]
    private let baseReplacementKinds: [ReplacementKind]
    private let baseExpectedTrailingNewline: Bool?
    private let baseReplacementTrailingNewline: Bool?

    init(hunk: PatchHunk) throws {
        var expected: [String] = []
        var expectedKinds: [ExpectedKind] = []
        var replacement: [String] = []
        var replacementKinds: [ReplacementKind] = []
        var expectedTrailing: Bool?
        var replacementTrailing: Bool?
        var lastMeaningfulLine: PatchLine?

        for line in hunk.lines {
            switch line {
            case .context(let value):
                expected.append(value)
                expectedKinds.append(.context)
                replacement.append(value)
                replacementKinds.append(.context)
                lastMeaningfulLine = line
            case .addition(let value):
                replacement.append(value)
                replacementKinds.append(.addition)
                lastMeaningfulLine = line
            case .deletion(let value):
                expected.append(value)
                expectedKinds.append(.deletion)
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

        self.baseExpected = expected
        self.baseExpectedKinds = expectedKinds
        self.baseReplacement = replacement
        self.baseReplacementKinds = replacementKinds
        self.baseExpectedTrailingNewline = expectedTrailing
        self.baseReplacementTrailingNewline = replacementTrailing
    }

    func variants(contextTolerance: Int) -> [Variant] {
        var variants: [Variant] = []
        let maxLeading = min(leadingContextCount, contextTolerance)

        for leadingTrim in 0...maxLeading {
            let remaining = contextTolerance - leadingTrim
            let maxTrailing = min(trailingContextCount, remaining)
            for trailingTrim in 0...maxTrailing {
                variants.append(buildVariant(leadingTrim: leadingTrim, trailingTrim: trailingTrim))
            }
        }

        return variants.sorted { lhs, rhs in
            let lhsTrim = lhs.leadingContextTrim + lhs.trailingContextTrim
            let rhsTrim = rhs.leadingContextTrim + rhs.trailingContextTrim
            if lhsTrim != rhsTrim {
                return lhsTrim < rhsTrim
            }
            return lhs.leadingContextTrim < rhs.leadingContextTrim
        }
    }

    private func buildVariant(leadingTrim: Int, trailingTrim: Int) -> Variant {
        var expected = baseExpected
        var expectedKinds = baseExpectedKinds

        if leadingTrim > 0 {
            let prefixKinds = expectedKinds.prefix(leadingTrim)
            guard prefixKinds.allSatisfy({ $0 == .context }) else {
                preconditionFailure("Attempted to trim non-context lines from hunk prefix")
            }
            expected.removeFirst(leadingTrim)
            expectedKinds.removeFirst(leadingTrim)
        }

        if trailingTrim > 0 {
            let suffixKinds = expectedKinds.suffix(trailingTrim)
            guard suffixKinds.allSatisfy({ $0 == .context }) else {
                preconditionFailure("Attempted to trim non-context lines from hunk suffix")
            }
            expected.removeLast(trailingTrim)
            expectedKinds.removeLast(trailingTrim)
        }

        var replacement = baseReplacement
        var replacementKinds = baseReplacementKinds

        var leadingToRemove = leadingTrim
        while leadingToRemove > 0 {
            guard let index = replacementKinds.firstIndex(of: .context) else {
                preconditionFailure("Missing context entries while trimming hunk prefix")
            }
            replacement.remove(at: index)
            replacementKinds.remove(at: index)
            leadingToRemove -= 1
        }

        var trailingToRemove = trailingTrim
        while trailingToRemove > 0 {
            guard let index = replacementKinds.lastIndex(of: .context) else {
                preconditionFailure("Missing context entries while trimming hunk suffix")
            }
            replacement.remove(at: index)
            replacementKinds.remove(at: index)
            trailingToRemove -= 1
        }

        return Variant(
            expected: expected,
            replacement: replacement,
            expectedTrailingNewline: baseExpectedTrailingNewline,
            replacementTrailingNewline: baseReplacementTrailingNewline,
            leadingContextTrim: leadingTrim,
            trailingContextTrim: trailingTrim
        )
    }

    private var leadingContextCount: Int {
        var count = 0
        for kind in baseExpectedKinds {
            guard kind == .context else { break }
            count += 1
        }
        return count
    }

    private var trailingContextCount: Int {
        var count = 0
        for kind in baseExpectedKinds.reversed() {
            guard kind == .context else { break }
            count += 1
        }
        return count
    }
}
