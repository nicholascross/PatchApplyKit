import Foundation

/// Parses a token stream into an in-memory representation (`PatchPlan`) suitable for validation and application.
public struct PatchParser {
    private static let nullDevicePath = "/dev/null"
    private static let hunkHeaderRegex: NSRegularExpression = {
        let pattern = "^@@\\s*-(\\d+)(?:,(\\d+))?\\s+\\+(\\d+)(?:,(\\d+))?\\s*@@(.*)$"
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Failed to compile hunk header regex: \(error)")
        }
    }()

    public init() {}

    public func parse(tokens: [PatchToken]) throws -> PatchPlan {
        let bounds = try determinePatchBounds(in: tokens)
        var index = bounds.start + 1
        var headers: [String] = []
        var directives: [PatchDirective] = []
        var pendingHeader: String?
        var pendingMetadataLines: [String] = []

        while index < bounds.end {
            let token = tokens[index]
            switch token {
            case let .header(line):
                headers.append(line)
                pendingHeader = line
                index += 1
            case let .metadata(line):
                try appendMetadata(line, to: &pendingMetadataLines)
                index += 1
            case .fileOld:
                let result = try parseDirectiveBlock(
                    tokens: tokens,
                    startingAt: index,
                    boundary: bounds.end,
                    pendingHeader: pendingHeader,
                    pendingMetadataLines: pendingMetadataLines
                )
                directives.append(result.directive)
                index = result.nextIndex
                pendingHeader = nil
                pendingMetadataLines.removeAll()
            default:
                try skipNonDirectiveToken(token, advancing: &index)
            }
        }

        let metadata = PatchMetadata(title: headers.first)
        return PatchPlan(metadata: metadata, directives: directives)
    }
}

extension PatchParser {
    func determinePatchBounds(in tokens: [PatchToken]) throws -> (start: Int, end: Int) {
        guard let beginIndex = tokens.firstIndex(of: .beginMarker) else {
            throw PatchEngineError.malformed("missing begin marker")
        }
        guard let endIndex = tokens.lastIndex(of: .endMarker), endIndex > beginIndex else {
            throw PatchEngineError.malformed("missing end marker")
        }
        return (beginIndex, endIndex)
    }

    private func appendMetadata(_ line: String, to storage: inout [String]) throws {
        if line.lowercased().hasPrefix("binary files ") {
            throw PatchEngineError.validationFailed("binary patches are not supported")
        }
        storage.append(line)
    }

    private func skipNonDirectiveToken(_ token: PatchToken, advancing index: inout Int) throws {
        if case let .other(line) = token {
            try ensureNonBinaryOther(line)
        }
        index += 1
    }

    private func ensureNonBinaryOther(_ line: String) throws {
        if line == "GIT binary patch" {
            throw PatchEngineError.validationFailed("binary patches are not supported")
        }
    }

    private func parseDirectiveBlock(
        tokens: [PatchToken],
        startingAt index: Int,
        boundary: Int,
        pendingHeader: String?,
        pendingMetadataLines: [String]
    ) throws -> (directive: PatchDirective, nextIndex: Int) {
        guard index + 1 < boundary else {
            throw PatchEngineError.malformed("truncated file header block")
        }
        guard case let .fileOld(rawOldPath) = tokens[index] else {
            throw PatchEngineError.malformed("expected --- line")
        }
        guard case let .fileNew(rawNewPath) = tokens[index + 1] else {
            throw PatchEngineError.malformed("expected +++ line after --- line")
        }

        var cursor = index + 2
        let oldPath = interpretPath(rawOldPath)
        let newPath = interpretPath(rawNewPath)
        var directiveMetadataLines = pendingMetadataLines
        var hunks: [PatchHunk] = []

        while cursor < boundary {
            let token = tokens[cursor]
            switch token {
            case let .hunkHeader(headerLine):
                cursor += 1
                let body = collectHunkBody(tokens: tokens, startingAt: cursor, boundary: boundary)
                let hunk = try parseHunk(headerLine: headerLine, bodyLines: body.lines)
                hunks.append(hunk)
                cursor = body.nextIndex
            case let .metadata(line):
                try appendMetadata(line, to: &directiveMetadataLines)
                cursor += 1
            case .fileOld, .header, .fileNew:
                let directive = makeDirective(
                    header: pendingHeader,
                    oldPath: oldPath,
                    newPath: newPath,
                    hunks: hunks,
                    metadataLines: directiveMetadataLines
                )
                return (directive, cursor)
            case let .other(line):
                try ensureNonBinaryOther(line)
                cursor += 1
            default:
                cursor += 1
            }
        }

        let directive = makeDirective(
            header: pendingHeader,
            oldPath: oldPath,
            newPath: newPath,
            hunks: hunks,
            metadataLines: directiveMetadataLines
        )
        return (directive, cursor)
    }

    private func collectHunkBody(
        tokens: [PatchToken],
        startingAt index: Int,
        boundary: Int
    ) -> (lines: [String], nextIndex: Int) {
        var bodyLines: [String] = []
        var cursor = index

        while cursor < boundary {
            let token = tokens[cursor]
            switch token {
            case let .hunkLine(rawLine):
                bodyLines.append(rawLine)
                cursor += 1
            case .hunkHeader, .fileOld, .fileNew, .header:
                return (bodyLines, cursor)
            default:
                cursor += 1
            }
        }

        return (bodyLines, cursor)
    }

    private func makeDirective(
        header: String?,
        oldPath: String?,
        newPath: String?,
        hunks: [PatchHunk],
        metadataLines: [String]
    ) -> PatchDirective {
        let operation = determineOperation(oldPath: oldPath, newPath: newPath, header: header)
        let metadata = parseMetadata(lines: metadataLines)
        return PatchDirective(
            header: header,
            oldPath: oldPath,
            newPath: newPath,
            hunks: hunks,
            operation: operation,
            metadata: metadata
        )
    }

    private func parseHunk(headerLine: String, bodyLines: [String]) throws -> PatchHunk {
        let header = try parseHunkHeader(headerLine)
        var lines: [PatchLine] = []

        for rawLine in bodyLines {
            if rawLine == "\\ No newline at end of file" {
                lines.append(.noNewlineMarker)
                continue
            }
            guard let indicator = rawLine.first else {
                throw PatchEngineError.malformed("empty hunk line encountered")
            }
            let payload = String(rawLine.dropFirst())
            switch indicator {
            case " ":
                lines.append(.context(payload))
            case "+":
                lines.append(.addition(payload))
            case "-":
                lines.append(.deletion(payload))
            default:
                throw PatchEngineError.malformed("unexpected hunk line prefix \(indicator)")
            }
        }

        return PatchHunk(header: header, lines: lines)
    }

    private func parseHunkHeader(_ headerLine: String) throws -> PatchHunkHeader {
        let trimmed = headerLine.trimmingCharacters(in: .whitespaces)
        if trimmed == "@@" {
            return PatchHunkHeader(oldRange: nil, newRange: nil, sectionHeading: nil)
        }
        let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
        guard let match = Self.hunkHeaderRegex.firstMatch(in: trimmed, options: [], range: range) else {
            throw PatchEngineError.malformed("invalid hunk header: \(headerLine)")
        }

        func parseInt(_ index: Int, default defaultValue: Int) -> Int {
            let groupRange = match.range(at: index)
            guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: trimmed) else {
                return defaultValue
            }
            return Int(trimmed[swiftRange]) ?? defaultValue
        }

        let oldStart = parseInt(1, default: 0)
        let oldLength = parseInt(2, default: 1)
        let newStart = parseInt(3, default: 0)
        let newLength = parseInt(4, default: 1)

        let sectionRange = match.range(at: 5)
        let sectionHeading: String?
        if sectionRange.location != NSNotFound, let swiftRange = Range(sectionRange, in: trimmed) {
            let heading = trimmed[swiftRange].trimmingCharacters(in: .whitespaces)
            sectionHeading = heading.isEmpty ? nil : heading
        } else {
            sectionHeading = nil
        }

        let oldRange = oldStart > 0 ? PatchLineRange(start: oldStart, length: oldLength) : nil
        let newRange = newStart > 0 ? PatchLineRange(start: newStart, length: newLength) : nil

        return PatchHunkHeader(oldRange: oldRange, newRange: newRange, sectionHeading: sectionHeading)
    }

    private func interpretPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed != Self.nullDevicePath else {
            return nil
        }
        if let canonical = dropGitPrefix(from: trimmed) {
            return canonical
        }
        return trimmed
    }

    func parseIndexLine(_ line: String) -> PatchIndexLine? {
        let components = line.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let hashComponent = String(components[1])
        guard let range = hashComponent.range(of: "..") else { return nil }
        let oldHash = String(hashComponent[..<range.lowerBound])
        let newHash = String(hashComponent[range.upperBound...])
        let mode = components.count >= 3 ? String(components[2]) : nil
        return PatchIndexLine(oldHash: oldHash, newHash: newHash, mode: mode)
    }

    private func dropGitPrefix(from path: String) -> String? {
        guard path.count >= 3 else { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return nil
    }

    private func determineOperation(oldPath: String?, newPath: String?, header: String?) -> PatchOperation {
        if let header = header?.lowercased(), header.contains("copy") {
            return .copy
        }
        switch (oldPath, newPath) {
        case (nil, .some):
            return .add
        case (.some, nil):
            return .delete
        case let (.some(oldValue), .some(newValue)):
            return oldValue == newValue ? .modify : .rename
        default:
            return .modify
        }
    }
}
