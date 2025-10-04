import Foundation

/// Metadata describing overall patch attributes such as title or timing.
public struct PatchMetadata: Equatable {
    public let title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}
