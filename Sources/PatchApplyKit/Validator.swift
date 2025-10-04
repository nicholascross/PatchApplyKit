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
}

private extension PatchValidator {
    func validatePaths(
        for directive: PatchDirective,
        seenOldPaths: inout Set<String>,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
        switch directive.operation {
        case .add:
            try validateAddPaths(directive, newPathOwners: &newPathOwners)
        case .delete:
            try validateDeletePaths(directive, seenOldPaths: &seenOldPaths)
        case .modify:
            try validateModifyPaths(directive, seenOldPaths: &seenOldPaths, newPathOwners: &newPathOwners)
        case .rename:
            try validateRenamePaths(directive, seenOldPaths: &seenOldPaths, newPathOwners: &newPathOwners)
        case .copy:
            try validateCopyPaths(directive, newPathOwners: &newPathOwners)
        }
    }

    func validateAddPaths(
        _ directive: PatchDirective,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
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
        guard !directive.hunks.isEmpty else {
            throw PatchEngineError.validationFailed("add directive for \(newPath) is missing content")
        }
    }

    func validateDeletePaths(
        _ directive: PatchDirective,
        seenOldPaths: inout Set<String>
    ) throws {
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
            throw PatchEngineError.validationFailed("delete directive for \(oldPath) is missing content markers")
        }
    }

    func validateModifyPaths(
        _ directive: PatchDirective,
        seenOldPaths: inout Set<String>,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
        guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath == newPath else {
            throw PatchEngineError.validationFailed(
                "modify directive must reference the same path for old and new content"
            )
        }
        guard seenOldPaths.insert(oldPath).inserted else {
            throw PatchEngineError.validationFailed("duplicate modify directive for \(oldPath)")
        }
        try trackNewPath(newPath, for: directive.operation, owners: &newPathOwners)
        guard !directive.hunks.isEmpty else {
            throw PatchEngineError.validationFailed("modify directive for \(oldPath) is missing content changes")
        }
    }

    func validateRenamePaths(
        _ directive: PatchDirective,
        seenOldPaths: inout Set<String>,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
        guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
            throw PatchEngineError.validationFailed(
                "rename directive requires distinct old and new paths"
            )
        }
        guard seenOldPaths.insert(oldPath).inserted else {
            throw PatchEngineError.validationFailed("duplicate directive touching old path \(oldPath)")
        }
        guard newPathOwners[newPath] == nil else {
            throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
        }
        newPathOwners[newPath] = .rename
    }

    func validateCopyPaths(
        _ directive: PatchDirective,
        newPathOwners: inout [String: PatchOperation]
    ) throws {
        guard let oldPath = directive.oldPath, let newPath = directive.newPath, oldPath != newPath else {
            throw PatchEngineError.validationFailed("copy directive requires distinct old and new paths")
        }
        guard newPathOwners[newPath] == nil else {
            throw PatchEngineError.validationFailed("duplicate directive touching new path \(newPath)")
        }
        newPathOwners[newPath] = .copy
    }

    func trackNewPath(
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

    func validateHunks(_ hunks: [PatchHunk], for operation: PatchOperation) throws {
        for hunk in hunks {
            try validateSingleHunk(hunk, for: operation)
        }
    }

    func validateSingleHunk(_ hunk: PatchHunk, for operation: PatchOperation) throws {
        guard !hunk.lines.isEmpty else {
            throw PatchEngineError.validationFailed("hunk cannot be empty")
        }

        var state = HunkValidationState()
        for (index, line) in hunk.lines.enumerated() {
            try processHunkLine(line, at: index, total: hunk.lines.count, state: &state)
        }

        try validateRangeConsistency(for: hunk, with: state)
        try validateOperationRules(operation, with: state)
    }

    struct HunkValidationState {
        var oldLineCount = 0
        var newLineCount = 0
        var additionCount = 0
        var deletionCount = 0
        var seenNoNewlineForOld = false
        var seenNoNewlineForNew = false
        var lastSignificantLine: PatchLine?
    }

    func processHunkLine(
        _ line: PatchLine,
        at index: Int,
        total: Int,
        state: inout HunkValidationState
    ) throws {
        switch line {
        case let .context(value):
            state.oldLineCount += 1
            state.newLineCount += 1
            try ensureNoCarriageReturn(value, kind: "context")
            state.lastSignificantLine = line
        case let .addition(value):
            state.newLineCount += 1
            state.additionCount += 1
            try ensureNoCarriageReturn(value, kind: "addition")
            state.lastSignificantLine = line
        case let .deletion(value):
            state.oldLineCount += 1
            state.deletionCount += 1
            try ensureNoCarriageReturn(value, kind: "deletion")
            state.lastSignificantLine = line
        case .noNewlineMarker:
            try validateNoNewlineMarker(at: index, total: total, state: &state)
        }
    }

    func ensureNoCarriageReturn(_ value: String, kind: String) throws {
        guard !value.contains("\r") else {
            throw PatchEngineError.validationFailed(
                "Carriage return characters are not supported in \(kind) lines"
            )
        }
    }

    func validateNoNewlineMarker(
        at index: Int,
        total: Int,
        state: inout HunkValidationState
    ) throws {
        guard index == total - 1 else {
            throw PatchEngineError.validationFailed(
                "\\ No newline at end of file marker must terminate the hunk"
            )
        }
        guard let last = state.lastSignificantLine else {
            throw PatchEngineError.validationFailed(
                "newline marker must follow an addition, deletion, or context line"
            )
        }
        if case .deletion = last {
            guard !state.seenNoNewlineForOld else {
                throw PatchEngineError.validationFailed(
                    "duplicate old-file newline markers in single hunk"
                )
            }
            state.seenNoNewlineForOld = true
        } else {
            guard !state.seenNoNewlineForNew else {
                throw PatchEngineError.validationFailed(
                    "duplicate new-file newline markers in single hunk"
                )
            }
            state.seenNoNewlineForNew = true
        }
    }

    func validateRangeConsistency(
        for hunk: PatchHunk,
        with state: HunkValidationState
    ) throws {
        if let oldRange = hunk.header.oldRange, oldRange.length != state.oldLineCount {
            throw PatchEngineError.validationFailed(
                "old-range line count does not match hunk content"
            )
        }
        if let newRange = hunk.header.newRange, newRange.length != state.newLineCount {
            throw PatchEngineError.validationFailed(
                "new-range line count does not match hunk content"
            )
        }
    }

    func validateOperationRules(
        _ operation: PatchOperation,
        with state: HunkValidationState
    ) throws {
        switch operation {
        case .add:
            guard state.oldLineCount == 0, state.deletionCount == 0 else {
                throw PatchEngineError.validationFailed(
                    "add directive hunks cannot delete or reference existing lines"
                )
            }
            guard state.additionCount > 0 else {
                throw PatchEngineError.validationFailed("add directive must contain added content")
            }
        case .delete:
            guard state.newLineCount == 0, state.additionCount == 0 else {
                throw PatchEngineError.validationFailed(
                    "delete directive hunks cannot introduce new lines"
                )
            }
            guard state.deletionCount > 0 else {
                throw PatchEngineError.validationFailed(
                    "delete directive must remove at least one line"
                )
            }
        case .modify, .rename, .copy:
            guard state.additionCount > 0 || state.deletionCount > 0 else {
                throw PatchEngineError.validationFailed(
                    "modify/rename/copy hunks must change content"
                )
            }
        }
    }

}
