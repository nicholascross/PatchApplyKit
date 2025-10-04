import Foundation

/// Describes the type of file-level change encoded by the patch.
public enum PatchOperation: Equatable {
    case add
    case delete
    case modify
    case rename
    case copy
}
