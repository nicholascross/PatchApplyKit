import Foundation

/// Parses a token stream into an in-memory representation (`PatchPlan`) suitable for validation and application.
public struct PatchParser {
    private static let nullDevicePath = "/dev/null"
    private static let hunkHeaderRegex: NSRegularExpression = {
        let pattern = "^@@\\s*-(\\d+)(?:,(\\d+))?\\s+\\+(\\d+)(?:,(\\d+))?\\s*@@(.*)$"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    public init() {}

    public func parse(tokens: [PatchToken]) throws -> PatchPlan {
        guard let beginIndex = tokens.firstIndex(of: .beginMarker) else {
            throw PatchEngineError.malformed("missing begin marker")
        }
        guard let endIndex = tokens.lastIndex(of: .endMarker), endIndex > beginIndex else {
            throw PatchEngineError.malformed("missing end marker")
        }

        var index = beginIndex + 1
        var headers: [String] = []
        var directives: [PatchDirective] = []
        var pendingHeader: String?
        var pendingMetadataLines: [String] = []

        while index < endIndex {
            let token = tokens[index]
            switch token {
            case .header(let line):
                headers.append(line)
                pendingHeader = line
                index += 1
            case .metadata(let line):
                pendingMetadataLines.append(line)
                index += 1
            case .fileOld(let rawOldPath):
                guard index + 1 < endIndex else {
                    throw PatchEngineError.malformed("truncated file header block")
                }
                guard case let .fileNew(rawNewPath) = tokens[index + 1] else {
                    throw PatchEngineError.malformed("expected +++ line after --- line")
                }
                index += 2
                let oldPath = interpretPath(rawOldPath)
                let newPath = interpretPath(rawNewPath)
                let directiveHeader = pendingHeader
                pendingHeader = nil
                var directiveMetadataLines = pendingMetadataLines
                pendingMetadataLines.removeAll()

                var hunks: [PatchHunk] = []
                directiveLoop: while index < endIndex {
                    let nextToken = tokens[index]
                    switch nextToken {
                    case .hunkHeader(let headerLine):
                        index += 1
                        var bodyLines: [String] = []
                        hunkBody: while index < endIndex {
                            let candidate = tokens[index]
                            switch candidate {
                            case .hunkLine(let rawLine):
                                bodyLines.append(rawLine)
                                index += 1
                            case .hunkHeader, .fileOld, .fileNew, .header:
                                break hunkBody
                            default:
                                index += 1
                            }
                        }
                        let hunk = try parseHunk(headerLine: headerLine, bodyLines: bodyLines)
                        hunks.append(hunk)
                    case .metadata(let line):
                        directiveMetadataLines.append(line)
                        index += 1
                    case .fileOld, .header, .fileNew:
                        break directiveLoop
                    default:
                        index += 1
                    }
                }

                let operation = determineOperation(oldPath: oldPath, newPath: newPath, header: directiveHeader)
                let metadata = parseMetadata(lines: directiveMetadataLines)
                let directive = PatchDirective(
                    header: directiveHeader,
                    oldPath: oldPath,
                    newPath: newPath,
                    hunks: hunks,
                    operation: operation,
                    metadata: metadata
                )
                directives.append(directive)
            case .other, .hunkLine, .hunkHeader, .fileNew:
                // Skip unexpected tokens that the parser is not ready to consume in this phase.
                index += 1
            case .beginMarker:
                // Nested begin markers are rejected by the tokenizer, so reaching here means stray token.
                index += 1
            case .endMarker:
                break
            }
        }

        let metadata = PatchMetadata(title: headers.first)
        return PatchPlan(metadata: metadata, directives: directives)
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
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
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

    private func parseMetadata(lines: [String]) -> PatchDirectiveMetadata {
        guard !lines.isEmpty else { return PatchDirectiveMetadata(rawLines: []) }

        var indexLine: PatchIndexLine?
        var oldMode: String?
        var newMode: String?
        var similarity: Int?
        var dissimilarity: Int?
        var renameFrom: String?
        var renameTo: String?
        var copyFrom: String?
        var copyTo: String?
        var isBinary = false

        for line in lines {
            if line.hasPrefix("index ") {
                indexLine = parseIndexLine(line)
            } else if line.hasPrefix("new file mode ") {
                newMode = line.components(separatedBy: "new file mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("new file executable mode ") {
                newMode = line.components(separatedBy: "new file executable mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("deleted file mode ") {
                oldMode = line.components(separatedBy: "deleted file mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("deleted file executable mode ") {
                oldMode = line.components(separatedBy: "deleted file executable mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("old mode ") {
                oldMode = line.components(separatedBy: "old mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("new mode ") {
                newMode = line.components(separatedBy: "new mode ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("mode change ") {
                let payload = line.dropFirst("mode change ".count)
                let parts = payload.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == ">" })
                if parts.count >= 2 {
                    oldMode = String(parts[0])
                    newMode = String(parts[1])
                }
            } else if line.hasPrefix("similarity index ") {
                similarity = parsePercentage(line, prefix: "similarity index ")
            } else if line.hasPrefix("dissimilarity index ") {
                dissimilarity = parsePercentage(line, prefix: "dissimilarity index ")
            } else if line.hasPrefix("rename from ") {
                renameFrom = line.components(separatedBy: "rename from ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("rename to ") {
                renameTo = line.components(separatedBy: "rename to ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("copy from ") {
                copyFrom = line.components(separatedBy: "copy from ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("copy to ") {
                copyTo = line.components(separatedBy: "copy to ").last?.trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("binary files ") {
                isBinary = true
            }
        }

        let modeChange: PatchFileModeChange?
        if oldMode != nil || newMode != nil {
            modeChange = PatchFileModeChange(oldMode: oldMode, newMode: newMode)
        } else {
            modeChange = nil
        }

        return PatchDirectiveMetadata(
            index: indexLine,
            fileModeChange: modeChange,
            similarityIndex: similarity,
            dissimilarityIndex: dissimilarity,
            renameFrom: renameFrom,
            renameTo: renameTo,
            copyFrom: copyFrom,
            copyTo: copyTo,
            isBinary: isBinary,
            rawLines: lines
        )
    }

    private func parseIndexLine(_ line: String) -> PatchIndexLine? {
        let components = line.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let hashComponent = String(components[1])
        guard let range = hashComponent.range(of: "..") else { return nil }
        let oldHash = String(hashComponent[..<range.lowerBound])
        let newHash = String(hashComponent[range.upperBound...])
        let mode = components.count >= 3 ? String(components[2]) : nil
        return PatchIndexLine(oldHash: oldHash, newHash: newHash, mode: mode)
    }

    private func parsePercentage(_ line: String, prefix: String) -> Int? {
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let trimmed = value.hasSuffix("%") ? String(value.dropLast()) : value
        return Int(trimmed)
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
