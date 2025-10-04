import Foundation

/// Performs semantic validation on a parsed patch prior to application.
public struct PatchValidator {
    public init() {}

    public func validate(_ plan: PatchPlan) throws {
        var seenOldPaths = Set<String>()
        var newPathOwners = [String: PatchOperation]()

        for directive in plan.directives {
            try validatePaths(for: directive, seenOldPaths: &seenOldPaths, newPathOwners: &newPathOwners)
            try validateHunks(directive.hunks, for: directive.operation)
            try validateMetadata(for: directive)
        }
    }

    private func validatePaths(
        for directive: PatchDirective,
        seenOldPaths: inout Set<String>,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
        switch directive.operation {
        case .add:
            guard directive.oldPath == nil else {
                throw PatchEngineError.validationFailed("add directive cannot specify an old path")
            }
            guard let newPath = directive.newPath else {
                throw PatchEngineError.validationFailed("add directive missing destination path")
            }
            guard newPathOwners[newPath] == nil else {
                throw PatchEngineError.validationFailed("duplicate new-path directive for \(newPath)")
            }
            newPathOwners[newPath] = .add
            guard !directive.hunks.isEmpty || directive.binaryPatch != nil else {
                throw PatchEngineError.validationFailed("add directive for \(newPath) is missing content")
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
            guard !directive.hunks.isEmpty || directive.binaryPatch != nil else {
                throw PatchEngineError.validationFailed("delete directive for \(oldPath) is missing content markers")
            }
        case .modify:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath == newPath else {
                throw PatchEngineError.validationFailed("modify directive must reference the same path for old and new content")
            }
            guard seenOldPaths.insert(oldPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate modify directive for \(oldPath)")
            }
            try trackNewPath(newPath, for: directive.operation, owners: &newPathOwners)
            guard !directive.hunks.isEmpty || directive.binaryPatch != nil else {
                throw PatchEngineError.validationFailed("modify directive for \(oldPath) is missing content changes")
            }
        case .rename:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
                throw PatchEngineError.validationFailed("rename directive requires distinct old and new paths")
            }
            guard seenOldPaths.insert(oldPath).inserted else {
                throw PatchEngineError.validationFailed("duplicate directive touching old path \(oldPath)")
            }
            guard newPathOwners[newPath] == nil else {
                throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
            }
            newPathOwners[newPath] = .rename
        case .copy:
            guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
                throw PatchEngineError.validationFailed("copy directive requires distinct old and new paths")
            }
            guard newPathOwners[newPath] == nil else {
                throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
            }
            newPathOwners[newPath] = .copy
        }
    }

    private func trackNewPath(
        _ path: String,
        for operation: PatchOperation,
        owners: inout [String: PatchOperation]
    ) throws {
        if let existing = owners[path] {
            switch (existing, operation) {
            case (.add, .modify), (.rename, .modify), (.copy, .modify):
                owners[path] = .modify
            case (.modify, .modify):
                throw PatchEngineError.validationFailed("duplicate modify directive for \(path)")
            default:
                throw PatchEngineError.validationFailed("duplicate directive touching new path \(path)")
            }
        } else {
            owners[path] = operation
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

        if let binaryPatch = directive.binaryPatch {
            try validateBinaryPayload(binaryPatch, for: directive)
        }

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

        if metadata.isBinary || directive.binaryPatch != nil {
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

    private func validateBinaryPayload(_ binaryPatch: PatchBinaryPatch, for directive: PatchDirective) throws {
        guard let targetPath = directive.newPath ?? directive.oldPath else {
            throw PatchEngineError.validationFailed("binary directive missing path context")
        }

        guard let newBlock = binaryPatch.newBlock else {
            throw PatchEngineError.validationFailed("binary directive for \(targetPath) is missing a new binary payload")
        }

        if directive.operation == .delete, !newBlock.data.isEmpty {
            throw PatchEngineError.validationFailed("delete directive for \(targetPath) must not supply new binary data")
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
