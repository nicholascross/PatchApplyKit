import Foundation

/// A line range described in a hunk header.
public struct PatchLineRange: Equatable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}
