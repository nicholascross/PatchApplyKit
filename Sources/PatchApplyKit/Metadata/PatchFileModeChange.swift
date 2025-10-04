import Foundation

/// Describes a file mode change communicated by the diff metadata.
public struct PatchFileModeChange: Equatable {
    public let oldMode: String?
    public let newMode: String?

    public init(oldMode: String?, newMode: String?) {
        self.oldMode = oldMode
        self.newMode = newMode
    }
}
