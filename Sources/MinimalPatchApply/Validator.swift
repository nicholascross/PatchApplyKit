import Foundation

/// Performs semantic validation on a parsed patch prior to application.
public struct PatchValidator {
    public init() {}

    public func validate(_ plan: PatchPlan) throws {
        var seenOldPaths = Set<String>()
        var seenNewPaths = Set<String>()

        for directive in plan.directives {
            try validatePaths(for: directive, seenOldPaths: &seenOldPaths, seenNewPaths: &seenNewPaths)
            try validateHunks(directive.hunks, for: directive.operation)
            try validateMetadata(for: directive)
        }
    }

    private func validatePaths(
        for directive: PatchDirective,
        seenOldPaths: inout Set<String>,
        seenNewPaths: inout Set<String>
    ) throws {
        switch directive.operation {
        case .add:
            guard directive.oldPath == nil else {
                throw PatchEngineError.validationFailed("add directive cannot specify an old path")
            }
            guard let newPath = directive.newPath else {
                throw PatchEngineError.validationFailed("add directive missing destination path")
            }
            guard seenNewPaths.insert(newPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate new-path directive for \(newPath)")
            }
            guard !directive.hunks.isEmpty else {
                throw PatchEngineError.validationFailed("add directive for \(newPath) is missing hunks")
            }
        case .delete:
            guard directive.newPath == nil else {
                throw PatchEngineError.validationFailed("delete directive cannot specify a new path")
            }
            guard let oldPath = directive.oldPath else {
                throw PatchEngineError.validationFailed("delete directive missing source path")
            }
            guard seenOldPaths.insert(oldPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate delete directive for \(oldPath)")
            }
            guard !directive.hunks.isEmpty else {
                throw PatchEngineError.validationFailed("delete directive for \(oldPath) is missing hunks")
            }
        case .modify:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath == newPath else {
                throw PatchEngineError.validationFailed("modify directive must reference the same path for old and new content")
            }
            guard seenOldPaths.insert(oldPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate modify directive for \(oldPath)")
            }
            guard seenNewPaths.insert(newPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate modify directive for \(newPath)")
            }
            guard !directive.hunks.isEmpty else {
                throw PatchEngineError.validationFailed("modify directive for \(oldPath) is missing hunks")
            }
        case .rename:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
                throw PatchEngineError.validationFailed("rename directive requires distinct old and new paths")
            }
            guard seenOldPaths.insert(oldPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate directive touching old path \(oldPath)")
            }
            guard seenNewPaths.insert(newPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
            }
        case .copy:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
                throw PatchEngineError.validationFailed("copy directive requires distinct old and new paths")
            }
            guard seenNewPaths.insert(newPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
            }
        }
    }

    private func validateHunks(_ hunks: [PatchHunk], for operation: PatchOperation) throws {
        for hunk in hunks {
            guard !hunk.lines.isEmpty else {
                throw PatchEngineError.validationFailed("hunk cannot be empty")
            }

            var oldLineCount = 0
            var newLineCount = 0
            var additionCount = 0
            var deletionCount = 0
            var seenNoNewlineForOld = false
            var seenNoNewlineForNew = false
            var lastSignificantLine: PatchLine?

            for (index, line) in hunk.lines.enumerated() {
                switch line {
                case .context(let value):
                    oldLineCount += 1
                    newLineCount += 1
                    guard !value.contains("\r") else {
                        throw PatchEngineError.validationFailed("Carriage return characters are not supported in context lines")
                    }
                    lastSignificantLine = line
                case .addition(let value):
                    newLineCount += 1
                    additionCount += 1
                    guard !value.contains("\r") else {
                        throw PatchEngineError.validationFailed("Carriage return characters are not supported in addition lines")
                    }
                    lastSignificantLine = line
                case .deletion(let value):
                    oldLineCount += 1
                    deletionCount += 1
                    guard !value.contains("\r") else {
                        throw PatchEngineError.validationFailed("Carriage return characters are not supported in deletion lines")
                    }
                    lastSignificantLine = line
                case .noNewlineMarker:
                    guard index == hunk.lines.count - 1 else {
                        throw PatchEngineError.validationFailed("\\ No newline at end of file marker must terminate the hunk")
                    }
                    guard let last = lastSignificantLine else {
                        throw PatchEngineError.validationFailed("newline marker must follow an addition, deletion, or context line")
                    }
                    if case .deletion = last {
                        guard !seenNoNewlineForOld else {
                            throw PatchEngineError.validationFailed("duplicate old-file newline markers in single hunk")
                        }
                        seenNoNewlineForOld = true
                    } else {
                        guard !seenNoNewlineForNew else {
                            throw PatchEngineError.validationFailed("duplicate new-file newline markers in single hunk")
                        }
                        seenNoNewlineForNew = true
                    }
                }
            }

            if let oldRange = hunk.header.oldRange, oldRange.length != oldLineCount {
                throw PatchEngineError.validationFailed("old-range line count does not match hunk content")
            }
            if let newRange = hunk.header.newRange, newRange.length != newLineCount {
                throw PatchEngineError.validationFailed("new-range line count does not match hunk content")
            }

            switch operation {
            case .add:
                guard oldLineCount == 0, deletionCount == 0 else {
                    throw PatchEngineError.validationFailed("add directive hunks cannot delete or reference existing lines")
                }
                guard additionCount > 0 else {
                    throw PatchEngineError.validationFailed("add directive must contain added content")
                }
            case .delete:
                guard newLineCount == 0, additionCount == 0 else {
                    throw PatchEngineError.validationFailed("delete directive hunks cannot introduce new lines")
                }
                guard deletionCount > 0 else {
                    throw PatchEngineError.validationFailed("delete directive must remove at least one line")
                }
            case .modify, .rename, .copy:
                guard additionCount > 0 || deletionCount > 0 else {
                    throw PatchEngineError.validationFailed("modify/rename/copy hunks must change content")
                }
            }
        }
    }

    private func validateMetadata(for directive: PatchDirective) throws {
        let metadata = directive.metadata

        if metadata.renameFrom != nil, directive.operation != .rename {
            throw PatchEngineError.validationFailed("unexpected rename metadata for non-rename directive touching \(directive.oldPath ?? directive.newPath ?? "<unknown>")")
        }
        if metadata.renameTo != nil, directive.operation != .rename {
            throw PatchEngineError.validationFailed("unexpected rename metadata for non-rename directive touching \(directive.oldPath ?? directive.newPath ?? "<unknown>")")
        }
        if metadata.copyFrom != nil, directive.operation != .copy {
            throw PatchEngineError.validationFailed("unexpected copy metadata for non-copy directive touching \(directive.oldPath ?? directive.newPath ?? "<unknown>")")
        }
        if metadata.copyTo != nil, directive.operation != .copy {
            throw PatchEngineError.validationFailed("unexpected copy metadata for non-copy directive touching \(directive.oldPath ?? directive.newPath ?? "<unknown>")")
        }

        if directive.operation == .rename {
            if let renameFrom = metadata.renameFrom, let oldPath = directive.oldPath {
                guard normalizeMetadataPath(renameFrom) == oldPath else {
                    throw PatchEngineError.validationFailed("rename metadata does not match source path for \(oldPath)")
                }
            }
            if let renameTo = metadata.renameTo, let newPath = directive.newPath {
                guard normalizeMetadataPath(renameTo) == newPath else {
                    throw PatchEngineError.validationFailed("rename metadata does not match destination path for \(newPath)")
                }
            }
        }

        if directive.operation == .copy {
            if let copyFrom = metadata.copyFrom, let oldPath = directive.oldPath {
                guard normalizeMetadataPath(copyFrom) == oldPath else {
                    throw PatchEngineError.validationFailed("copy metadata does not match source path for \(oldPath)")
                }
            }
            if let copyTo = metadata.copyTo, let newPath = directive.newPath {
                guard normalizeMetadataPath(copyTo) == newPath else {
                    throw PatchEngineError.validationFailed("copy metadata does not match destination path for \(newPath)")
                }
            }
        }

        if metadata.similarityIndex != nil || metadata.dissimilarityIndex != nil {
            guard directive.operation == .rename || directive.operation == .copy else {
                throw PatchEngineError.validationFailed("similarity metadata is only valid for rename or copy directives")
            }
        }

        if metadata.isBinary {
            guard directive.hunks.isEmpty else {
                throw PatchEngineError.validationFailed("binary patches must not include textual hunks")
            }
        }

        if let fileMode = metadata.fileModeChange {
            switch directive.operation {
            case .add:
                if fileMode.oldMode != nil {
                    throw PatchEngineError.validationFailed("add directive metadata must not declare old file mode")
                }
            case .delete:
                if fileMode.newMode != nil {
                    throw PatchEngineError.validationFailed("delete directive metadata must not declare new file mode")
                }
            default:
                break
            }
        }
    }

    private func normalizeMetadataPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }
}
