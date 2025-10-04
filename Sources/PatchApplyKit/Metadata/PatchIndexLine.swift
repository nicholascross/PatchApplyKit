import Foundation

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
