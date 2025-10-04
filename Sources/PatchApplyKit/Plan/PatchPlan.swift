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
