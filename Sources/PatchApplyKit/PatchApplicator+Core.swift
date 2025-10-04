import Foundation

extension PatchApplicator {
    func applyAddition(_ directive: PatchDirective) throws {
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

    func applyDeletion(_ directive: PatchDirective) throws {
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

    func applyModification(_ directive: PatchDirective) throws {
        guard let path = directive.newPath, let oldPath = directive.oldPath, path == oldPath else {
            throw PatchEngineError.validationFailed(
                "modify directive must reference the same path for old and new content"
            )
        }
        guard fileSystem.fileExists(at: path) else {
            throw PatchEngineError.validationFailed("cannot modify missing file: \(path)")
        }

        var buffer = try loadBuffer(at: path)
        try apply(hunks: directive.hunks, to: &buffer, path: path)
        try write(buffer: buffer, to: path)
        try applyFileMode(for: directive, to: path)
    }

    func applyRename(_ directive: PatchDirective) throws {
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

    func applyCopy(_ directive: PatchDirective) throws {
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

        var buffer = try loadBuffer(at: source)
        if !directive.hunks.isEmpty {
            try apply(hunks: directive.hunks, to: &buffer, path: destination)
        }
        try write(buffer: buffer, to: destination)
        try applyFileMode(for: directive, to: destination)
        try applyInheritedPermissions(sourcePermissions, to: destination, directive: directive)
    }

    func buildBufferForAddition(hunks: [PatchHunk]) throws -> TextBuffer {
        var lines: [String] = []
        var hasTrailingNewline = true
        var sawAddition = false

        for hunk in hunks {
            for line in hunk.lines {
                switch line {
                case let .addition(value):
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

    func apply(hunks: [PatchHunk], to buffer: inout TextBuffer, path: String) throws {
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
                    throw PatchEngineError.validationFailed(
                        "newline expectation mismatch while applying hunk to \(path)"
                    )
                }
            }

            if variant.expected.count > 0 {
                buffer.lines.removeSubrange(insertionIndex ..< (insertionIndex + variant.expected.count))
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

    struct HunkMatch {
        let insertionIndex: Int
        let variant: HunkTransform.Variant
    }

    func locateMatch(
        transform: HunkTransform,
        in buffer: TextBuffer,
        header: PatchHunkHeader,
        path: String
    ) throws -> HunkMatch {
        let variants = transform.variants(contextTolerance: configuration.contextTolerance)

        for variant in variants {
            if variant.expected.isEmpty {
                let insertion = insertionIndexForEmptyExpected(header: header, buffer: buffer)
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

            let matchesFound = collectMatches(for: variant.expected, in: buffer)
            if matchesFound.count > 1 {
                throw PatchEngineError.validationFailed("ambiguous hunk match while applying patch to \(path)")
            } else if let match = matchesFound.first {
                return HunkMatch(insertionIndex: match, variant: variant)
            }
        }

        throw PatchEngineError.validationFailed("context mismatch while applying hunk to \(path)")
    }

    func insertionIndexForEmptyExpected(
        header: PatchHunkHeader,
        buffer: TextBuffer
    ) -> Int {
        if let newRange = header.newRange {
            let upperBound = max(0, min(buffer.lines.count, newRange.start - 1))
            return upperBound
        }
        return buffer.lines.count
    }

    func collectMatches(for expected: [String], in buffer: TextBuffer) -> [Int] {
        guard buffer.lines.count >= expected.count else { return [] }
        let upperBound = buffer.lines.count - expected.count
        return (0 ... upperBound).compactMap { index in
            matches(expected, in: buffer, at: index) ? index : nil
        }
    }

    func matches(_ expected: [String], in buffer: TextBuffer, at index: Int) -> Bool {
        guard index >= 0, index + expected.count <= buffer.lines.count else {
            return false
        }
        for offset in 0 ..< expected.count where
            canonical(buffer.lines[index + offset]) != canonical(expected[offset]) {
            return false
        }
        return true
    }

    func canonical(_ line: String) -> String {
        switch configuration.whitespace {
        case .exact:
            return line
        case .ignoreAll:
            return line.filter { !$0.isWhitespace }
        }
    }

    func loadBuffer(at path: String) throws -> TextBuffer {
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

    func write(buffer: TextBuffer, to path: String) throws {
        do {
            try fileSystem.writeFile(buffer.encode(), to: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to write \(path): \(error)")
        }
    }

    func remove(path: String) throws {
        do {
            try fileSystem.removeItem(at: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to remove \(path): \(error)")
        }
    }

    func move(from source: String, to destination: String) throws {
        do {
            try fileSystem.moveItem(from: source, to: destination)
        } catch {
            throw PatchEngineError.ioFailure("failed to move \(source) to \(destination): \(error)")
        }
    }

    func applyFileMode(for directive: PatchDirective, to path: String) throws {
        guard let newMode = directive.metadata.fileModeChange?.newMode else { return }
        guard let permissions = parsePermissions(from: newMode) else { return }
        try setPermissions(permissions, at: path)
    }

    func parsePermissions(from modeString: String) -> UInt16? {
        let cleaned = modeString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = UInt32(cleaned, radix: 8) else { return nil }
        return UInt16(value & 0o7777)
    }

    func capturePermissions(at path: String) -> UInt16? {
        guard let permissions = try? fileSystem.posixPermissions(at: path) else {
            return nil
        }
        return permissions
    }

    func applyInheritedPermissions(
        _ permissions: UInt16?,
        to path: String,
        directive: PatchDirective
    ) throws {
        guard directive.metadata.fileModeChange?.newMode == nil else { return }
        guard let permissions else { return }
        try setPermissions(permissions, at: path)
    }

    func setPermissions(_ permissions: UInt16, at path: String) throws {
        do {
            try fileSystem.setPOSIXPermissions(permissions, at: path)
        } catch {
            throw PatchEngineError.ioFailure("failed to set permissions on \(path): \(error)")
        }
    }
}
