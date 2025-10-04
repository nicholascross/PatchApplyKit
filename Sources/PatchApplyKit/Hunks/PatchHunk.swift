import Foundation

/// A contiguous region of the patch describing line-level edits.
public struct PatchHunk: Equatable {
    public let header: PatchHunkHeader
    public let lines: [PatchLine]

    public init(header: PatchHunkHeader, lines: [PatchLine]) {
        self.header = header
        self.lines = lines
    }
}
