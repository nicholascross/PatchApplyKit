import Foundation

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
