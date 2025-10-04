import Foundation

/// Structured error type thrown during parsing or application.
public enum PatchEngineError: Error, CustomStringConvertible {
    case malformed(String)
    case validationFailed(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case let .malformed(message):
            return "Malformed patch – \(message)"
        case let .validationFailed(message):
            return "Patch validation failed – \(message)"
        case let .ioFailure(message):
            return "File system error – \(message)"
        }
    }
}
