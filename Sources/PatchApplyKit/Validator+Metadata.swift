import Foundation

extension PatchValidator {
    func validateMetadata(for directive: PatchDirective) throws {
        let metadata = directive.metadata
        try validateRenameCopyExpectations(metadata, for: directive)
        try validateRenameMetadataIfNeeded(directive)
        try validateCopyMetadataIfNeeded(directive)
        try validateSimilarityMetadata(metadata, for: directive.operation)
        try validateFileModeMetadata(metadata, for: directive.operation)
    }

    func validateRenameCopyExpectations(
        _ metadata: PatchDirectiveMetadata,
        for directive: PatchDirective
    ) throws {
        let pathSummary = directivePathSummary(directive)

        if metadata.renameFrom != nil, directive.operation != .rename {
            throw PatchEngineError.validationFailed(
                "unexpected rename metadata for non-rename directive touching \(pathSummary)"
            )
        }
        if metadata.renameTo != nil, directive.operation != .rename {
            throw PatchEngineError.validationFailed(
                "unexpected rename metadata for non-rename directive touching \(pathSummary)"
            )
        }
        if metadata.copyFrom != nil, directive.operation != .copy {
            throw PatchEngineError.validationFailed(
                "unexpected copy metadata for non-copy directive touching \(pathSummary)"
            )
        }
        if metadata.copyTo != nil, directive.operation != .copy {
            throw PatchEngineError.validationFailed(
                "unexpected copy metadata for non-copy directive touching \(pathSummary)"
            )
        }
    }

    func validateRenameMetadataIfNeeded(_ directive: PatchDirective) throws {
        guard directive.operation == .rename else { return }
        let metadata = directive.metadata

        if let renameFrom = metadata.renameFrom, let oldPath = directive.oldPath {
            let normalized = normalizeMetadataPath(renameFrom)
            guard normalized == oldPath else {
                throw PatchEngineError.validationFailed(
                    "rename metadata does not match source path for \(oldPath)"
                )
            }
        }
        if let renameTo = metadata.renameTo, let newPath = directive.newPath {
            let normalized = normalizeMetadataPath(renameTo)
            guard normalized == newPath else {
                throw PatchEngineError.validationFailed(
                    "rename metadata does not match destination path for \(newPath)"
                )
            }
        }
    }

    func validateCopyMetadataIfNeeded(_ directive: PatchDirective) throws {
        guard directive.operation == .copy else { return }
        let metadata = directive.metadata

        if let copyFrom = metadata.copyFrom, let oldPath = directive.oldPath {
            let normalized = normalizeMetadataPath(copyFrom)
            guard normalized == oldPath else {
                throw PatchEngineError.validationFailed(
                    "copy metadata does not match source path for \(oldPath)"
                )
            }
        }
        if let copyTo = metadata.copyTo, let newPath = directive.newPath {
            let normalized = normalizeMetadataPath(copyTo)
            guard normalized == newPath else {
                throw PatchEngineError.validationFailed(
                    "copy metadata does not match destination path for \(newPath)"
                )
            }
        }
    }

    func validateSimilarityMetadata(
        _ metadata: PatchDirectiveMetadata,
        for operation: PatchOperation
    ) throws {
        guard metadata.similarityIndex != nil || metadata.dissimilarityIndex != nil else { return }
        guard operation == .rename || operation == .copy else {
            throw PatchEngineError.validationFailed(
                "similarity metadata is only valid for rename or copy directives"
            )
        }
    }

    func validateFileModeMetadata(
        _ metadata: PatchDirectiveMetadata,
        for operation: PatchOperation
    ) throws {
        guard let fileMode = metadata.fileModeChange else { return }
        switch operation {
        case .add:
            if fileMode.oldMode != nil {
                throw PatchEngineError.validationFailed(
                    "add directive metadata must not declare old file mode"
                )
            }
        case .delete:
            if fileMode.newMode != nil {
                throw PatchEngineError.validationFailed(
                    "delete directive metadata must not declare new file mode"
                )
            }
        default:
            break
        }
    }

    func directivePathSummary(_ directive: PatchDirective) -> String {
        directive.oldPath ?? directive.newPath ?? "<unknown>"
    }

    func normalizeMetadataPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }
}
