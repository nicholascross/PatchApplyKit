import Foundation

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
