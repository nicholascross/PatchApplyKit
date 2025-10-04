import Foundation

/// Aggregates the directives extracted from a unified diff patch.
public struct PatchPlan: Equatable {
    public let metadata: PatchMetadata
    public let directives: [PatchDirective]

    public init(metadata: PatchMetadata, directives: [PatchDirective]) {
        self.metadata = metadata
        self.directives = directives
    }
}

/// Metadata describing overall patch attributes such as title or timing.
public struct PatchMetadata: Equatable {
    public let title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}

/// Represents the effect of a diff on a single file path.
public struct PatchDirective: Equatable {
    public let header: String?
    public let oldPath: String?
    public let newPath: String?
    public let hunks: [PatchHunk]
    public let operation: PatchOperation
    public let metadata: PatchDirectiveMetadata

    public init(
        header: String? = nil,
        oldPath: String?,
        newPath: String?,
        hunks: [PatchHunk],
        operation: PatchOperation,
        metadata: PatchDirectiveMetadata = PatchDirectiveMetadata()
    ) {
        self.header = header
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.operation = operation
        self.metadata = metadata
    }
}

/// Describes the type of file-level change encoded by the patch.
public enum PatchOperation: Equatable {
    case add
    case delete
    case modify
    case rename
    case copy
}

/// A contiguous region of the patch describing line-level edits.
public struct PatchHunk: Equatable {
    public let header: PatchHunkHeader
    public let lines: [PatchLine]

    public init(header: PatchHunkHeader, lines: [PatchLine]) {
        self.header = header
        self.lines = lines
    }
}

/// Captures the hunk header offsets and context counts.
public struct PatchHunkHeader: Equatable {
    public let oldRange: PatchLineRange?
    public let newRange: PatchLineRange?
    public let sectionHeading: String?

    public init(oldRange: PatchLineRange?, newRange: PatchLineRange?, sectionHeading: String?) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.sectionHeading = sectionHeading
    }
}

/// A line range described in a hunk header.
public struct PatchLineRange: Equatable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

/// A single line entry inside a hunk body.
public enum PatchLine: Equatable {
    case context(String)
    case addition(String)
    case deletion(String)
    case noNewlineMarker
}

/// Structured error type thrown during parsing or application.
public enum PatchEngineError: Error, CustomStringConvertible {
    case malformed(String)
    case validationFailed(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .malformed(let message):
            return "Malformed patch – \(message)"
        case .validationFailed(let message):
            return "Patch validation failed – \(message)"
        case .ioFailure(let message):
            return "File system error – \(message)"
        }
    }
}

/// Additional metadata extracted from diff headers between directives and hunks.
public struct PatchDirectiveMetadata: Equatable {
    public let index: PatchIndexLine?
    public let fileModeChange: PatchFileModeChange?
    public let similarityIndex: Int?
    public let dissimilarityIndex: Int?
    public let renameFrom: String?
    public let renameTo: String?
    public let copyFrom: String?
    public let copyTo: String?
    public let isBinary: Bool
    public let rawLines: [String]

    public init(
        index: PatchIndexLine? = nil,
        fileModeChange: PatchFileModeChange? = nil,
        similarityIndex: Int? = nil,
        dissimilarityIndex: Int? = nil,
        renameFrom: String? = nil,
        renameTo: String? = nil,
        copyFrom: String? = nil,
        copyTo: String? = nil,
        isBinary: Bool = false,
        rawLines: [String] = []
    ) {
        self.index = index
        self.fileModeChange = fileModeChange
        self.similarityIndex = similarityIndex
        self.dissimilarityIndex = dissimilarityIndex
        self.renameFrom = renameFrom
        self.renameTo = renameTo
        self.copyFrom = copyFrom
        self.copyTo = copyTo
        self.isBinary = isBinary
        self.rawLines = rawLines
    }
}

/// Parsed representation of an `index` metadata line.
public struct PatchIndexLine: Equatable {
    public let oldHash: String
    public let newHash: String
    public let mode: String?

    public init(oldHash: String, newHash: String, mode: String?) {
        self.oldHash = oldHash
        self.newHash = newHash
        self.mode = mode
    }
}

/// Describes a file mode change communicated by the diff metadata.
public struct PatchFileModeChange: Equatable {
    public let oldMode: String?
    public let newMode: String?

    public init(oldMode: String?, newMode: String?) {
        self.oldMode = oldMode
        self.newMode = newMode
    }
}
